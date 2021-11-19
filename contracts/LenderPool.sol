//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./interfaces/ILenderPool.sol";
import "./interfaces/IUniswapV2Router.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @author Polytrade
/// @title LenderPool V1
contract LenderPool is ILenderPool, Ownable, Pausable {
    using SafeERC20 for IERC20;

    /// IERC20 Instance of the Stable coin
    IERC20 public immutable stableInstance;

    /// IUniswapV2Router instance of the router
    IUniswapV2Router public immutable router;

    /// Address of the Trade token
    address public immutable trade;

    /// uint16 StableAPY of the pool
    uint16 private immutable _stableAPY;

    /// PRECISION constant for calculation purpose
    uint private constant PRECISION = 1E6;

    /// uint minimum Deposit amount
    uint public minimumDeposit;

    /// _amountLent mapping of the total amountLent for each  lender
    mapping(address => uint) private _amountLent;

    /// _roundCount mapping that counts the amount of round for each lender
    mapping(address => uint) private _roundCount;

    /// _lenderRounds mapping that contains all roundIds and Round info for each lender
    mapping(address => mapping(uint => Round)) private _lenderRounds;

    constructor(address stableAddress_, uint16 stableAPY_) {
        stableInstance = IERC20(stableAddress_);
        _stableAPY = stableAPY_;
        // initialize IUniswapV2Router router
        router = IUniswapV2Router(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
        // initialize trade token address
        trade = 0x692AC1e363ae34b6B489148152b12e2785a3d8d6;
    }

    /**
     * @notice changes the minimum amount required for deposit (newRound)
     * @dev update `minimumDeposit` with `_minimumDeposit`
     * @param _minimumDeposit, new minimum deposit
     */
    function setMinimumDeposit(uint _minimumDeposit) external onlyOwner {
        minimumDeposit = _minimumDeposit;
    }

    /**
     * @notice create new Round on behalf of the lender, each deposit has its own round
     * @dev `lender` must approve the amount to be deposited first
     * @dev only `Owner` can launch a new round
     * @dev only function that can be `Paused`
     * @dev add new round to `_lenderRounds`
     * @dev `amount` will be transferred from `lender` to `address(this)`
     * @dev emits Deposit event
     * @param lender, address of the lender
     * @param amount, amount to be deposited by the lender, must be greater than minimumDeposit
     * @param bonusAPY, bonus ratio to be applied
     * @param tenure, duration of the round (expressed in number in days)
     * @param paidTrade, specifies whether if stable rewards will be paid in Trade(true) or in stable(false)
     */
    function newRound(
        address lender,
        uint amount,
        uint16 bonusAPY,
        uint8 tenure,
        bool paidTrade
    ) external onlyOwner whenNotPaused {
        require(amount >= minimumDeposit, "Amount lower than minimumDeposit");
        Round memory round = Round({
            bonusAPY: bonusAPY,
            startPeriod: block.timestamp,
            endPeriod: block.timestamp + (tenure * 1 days),
            amountLent: amount,
            paidTrade: paidTrade
        });
        _lenderRounds[lender][_roundCount[lender]] = round;
        _roundCount[lender]++;
        _amountLent[lender] += amount;
        stableInstance.safeTransferFrom(lender, address(this), amount);
        emit Deposit(lender, _roundCount[lender] - 1, amount);
    }

    /**
     * @notice Withdraw all amounts lent and claim rewards for all finished rounds
     * @dev `withdraw` function is called for each finished round
     * @dev only `Owner` can withdrawAllFinishedRounds
     * @param lender, address of the lender
     */
    function withdrawAllFinishedRounds(address lender) external onlyOwner {
        uint[] memory rounds = _getFinishedRounds(lender);

        for (uint i = 0; i < rounds.length; i++) {
            withdraw(lender, rounds[i]);
        }
    }

    /**
     * @notice Returns all the information of a specific round for a specific lender
     * @dev returns Round struct of the specific round for a specific lender
     * @param lender, address of the lender to be checked
     * @param roundId, Id of the round to be checked
     * @return Round ({ bool paidTrade, uint16 bonusAPY, uint amountLent, uint startPeriod, uint endPeriod })
     */
    function getRound(address lender, uint roundId)
        external
        view
        returns (Round memory)
    {
        return _lenderRounds[lender][roundId];
    }

    /**
     * @notice Returns the number of rounds for the a specific lender
     * @param lender, address of the lender to be checked
     * @return returns _roundCount[lender] (last known round)
     */
    function getNumberOfRounds(address lender) external view returns (uint) {
        return _roundCount[lender];
    }

    /**
     * @notice Returns the total amount lent for the lender on every round
     * @param lender, address of the lender to be checked
     * @return returns _amountLent[lender]
     */
    function getAmountLent(address lender) external view returns (uint) {
        return _amountLent[lender];
    }

    /**
     * @notice Returns roundIds of every finished round
     * @param lender, address of the lender to be checked
     * @return returns array with all finished round Ids
     */
    function getFinishedRounds(address lender)
        external
        view
        returns (uint[] memory)
    {
        return _getFinishedRounds(lender);
    }

    /**
     * @notice Returns the amount of stable rewards for a specific lender on a specific roundId
     * @dev run `_calculateRewards` with `_stableAPY` based on the amountLent
     * @param lender, address of the lender to be checked
     * @param roundId, Id of the round to be checked
     * @return returns the amount of stable rewards (based on stableInstance)
     */
    function stableRewardOf(address lender, uint roundId)
        external
        view
        returns (uint)
    {
        return _calculateRewards(lender, roundId, _stableAPY);
    }

    /**
     * @notice Returns the amount of bonus rewards for a specific lender on a specific roundId
     * @dev run `_calculateRewards` with `_lenderRounds[lender][roundId].bonusAPY` based on the amountLent
     * @param lender, address of the lender to be checked
     * @param roundId, Id of the round to be checked
     * @return returns the amount of bonus rewards in stable (based on stableInstance)
     */
    function bonusRewardOf(address lender, uint roundId)
        external
        view
        returns (uint)
    {
        return
            _calculateRewards(
                lender,
                roundId,
                _lenderRounds[lender][roundId].bonusAPY
            );
    }

    /**
     * @notice Returns the total amount of rewards for a specific lender on a specific roundId
     * @dev calculate rewards for stable (stableAPY) and bonus (bonusAPY)
     * @param lender, address of the lender to be checked
     * @param roundId, Id of the round to be checked
     * @return returns the total amount of rewards (stable + bonus) in stable (based on stableInstance)
     */
    function totalRewardOf(address lender, uint roundId)
        external
        view
        returns (uint)
    {
        uint stableReward = _calculateRewards(lender, roundId, _stableAPY);

        uint bonusReward = _calculateRewards(
            lender,
            roundId,
            _lenderRounds[lender][roundId].bonusAPY
        );

        return stableReward + bonusReward;
    }

    /**
     * @notice Withdraw the initial deposit of the specified lender for the specified roundId
     * @notice claim rewards of the specified roundId for the specific lender
     * @dev only `Owner` can withdraw
     * @dev round must be finish (`block.timestamp` must be higher than `round.endPeriod`)
     * @dev run `_claimRewards` and `_withdraw`
     * @param lender, address of the lender
     * @param roundId, Id of the round
     */
    function withdraw(address lender, uint roundId) public onlyOwner {
        Round memory round = _lenderRounds[lender][roundId];
        require(
            block.timestamp >= round.endPeriod,
            "Round is not finished yet"
        );
        _claimRewards(lender, roundId);
        _withdraw(lender, roundId, round.amountLent);
    }

    /**
 * @notice Claim rewards for the specified lender and the specified roundId
     * @dev only `Owner` can withdraw
     * @dev if round `paidTrade` is `true`, swap all rewards into Trade tokens
     * @dev if round `paidTrade` is `false` and swap only bonusRewards and transfer stableRewards to the lender

          * @dev emits ClaimTrade whenever Stable are swapped into Trade
          * @dev emits ClaimStable whenever Stable are sent to the lender
* @param lender, address of the lender
     * @param roundId, Id of the round

     */
    function _claimRewards(address lender, uint roundId) private {
        Round memory round = _lenderRounds[lender][roundId];
        stableInstance.approve(address(router), ~uint(0));
        if (round.paidTrade) {
            uint amountTrade = _swapExactTokens(
                lender,
                roundId,
                (_stableAPY + round.bonusAPY)
            );
            emit ClaimTrade(lender, roundId, amountTrade);
        } else {
            uint amountStable = _calculateRewards(lender, roundId, _stableAPY);
            stableInstance.transfer(lender, amountStable);
            emit ClaimStable(lender, roundId, amountStable);
            uint amountTrade = _swapExactTokens(
                lender,
                roundId,
                round.bonusAPY
            );
            emit ClaimTrade(lender, roundId, amountTrade);
        }
    }

    /**
     * @notice Withdraw the initial deposit of the specified lender for the specified roundId
     * @dev transfer the initial amount deposited to the lender
     * @dev emits Withdraw event
     * @param lender, address of the lender
     * @param roundId, Id of the round
     * @param amount, amount to withdraw
     */
    function _withdraw(
        address lender,
        uint roundId,
        uint amount
    ) private {
        _amountLent[lender] -= amount;
        _lenderRounds[lender][roundId].amountLent -= amount;
        stableInstance.safeTransfer(lender, amount);
        emit Withdraw(lender, roundId, amount);
    }

    /**
     * @notice Swap Stable for Trade using IUniswap router interface
     * @dev emits Swapped event (amountStable sent, amountTrade received)
     * @param lender, address of the lender
     * @param roundId, Id of the round
     * @param rewardAPY, rewardAPY
     * @return amount TRADE swapped
     */
    function _swapExactTokens(
        address lender,
        uint roundId,
        uint16 rewardAPY
    ) private returns (uint) {
        uint amountStable = _calculateRewards(lender, roundId, rewardAPY);
        uint amountTrade = router.swapExactTokensForTokens(
            amountStable,
            0,
            _getPath(),
            lender,
            block.timestamp
        )[2];
        emit Swapped(amountStable, amountTrade);
        return amountTrade;
    }

    /**
     * @notice Calculate the amount of rewards
     * @dev ((rewardAPY * amountLent * timePassed) / 365)
     * @param lender, address of the lender
     * @param roundId, Id of the round
     * @param rewardAPY, rewardAPY
     * @return amount rewards
     */
    function _calculateRewards(
        address lender,
        uint roundId,
        uint16 rewardAPY
    ) private view returns (uint) {
        Round memory round = _lenderRounds[lender][roundId];

        uint timePassed = (block.timestamp >= round.endPeriod)
            ? round.endPeriod - round.startPeriod
            : block.timestamp - round.startPeriod;

        uint result = ((rewardAPY * round.amountLent * timePassed) / 365 days) *
            PRECISION;
        return (result / 1E10);
    }

    /**
     * @notice Returns roundIds of every finished round
     * @param lender, address of the lender to be checked
     * @return returns array with all finished round Ids for the specified lender
     */
    function _getFinishedRounds(address lender)
        private
        view
        returns (uint[] memory)
    {
        uint length = _roundCount[lender];
        uint j = 0;
        for (uint i = 0; i < length; i++) {
            if (
                block.timestamp >= _lenderRounds[lender][i].endPeriod &&
                _lenderRounds[lender][i].amountLent > 0
            ) {
                j++;
            }
        }
        uint[] memory result = new uint[](j);
        j = 0;
        for (uint i = 0; i < length; i++) {
            if (
                block.timestamp >= _lenderRounds[lender][i].endPeriod &&
                _lenderRounds[lender][i].amountLent > 0
            ) {
                result[j] = i;
                j++;
            }
        }
        return result;
    }

    /**
     * @notice Returns Path (used by IUniswap router)
     * @return returns array of path (Stable, WETH, Trade)
     */
    function _getPath() private view returns (address[] memory) {
        address[] memory path = new address[](3);
        path[0] = address(stableInstance);
        path[1] = router.WETH();
        path[2] = trade;

        return path;
    }
}