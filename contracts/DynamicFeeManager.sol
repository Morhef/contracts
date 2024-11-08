// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BaseDynamicFeeManager.sol";
import "./interfaces/IFeeReceiver.sol";
import "./interfaces/IWeSenditToken.sol";

import "hardhat/console.sol";

/**
 * @title Dynamic Fee Manager for ERC20 token
 *
 * The dynamic fee manager allows to dynamically add fee rules to ERC20 token transactions.
 * Fees will be applied if the given conditions are met.
 * Additonally, fees can be used to create liquidity on DEX or can be swapped to BUSD.
 */
contract DynamicFeeManager is BaseDynamicFeeManager {
    constructor(address wesenditToken) BaseDynamicFeeManager(wesenditToken) {}

    receive() external payable {}

    function addFee(
        address from,
        address to,
        uint256 percentage,
        address destination,
        bool excludeContracts,
        bool doLiquify,
        bool doSwapForBusd,
        uint256 swapOrLiquifyAmount,
        uint256 expiresAt
    ) external override onlyRole(ADMIN) returns (uint256 index) {
        require(
            feeEntries.length < MAX_FEE_AMOUNT,
            "DynamicFeeManager: Amount of max. fees reached"
        );
        require(
            percentage <= feePercentageLimit(),
            "DynamicFeeManager: Fee percentage exceeds limit"
        );
        require(
            !(doLiquify && doSwapForBusd),
            "DynamicFeeManager: Cannot enable liquify and swap at the same time"
        );

        bytes32 id = _generateIdentifier(
            destination,
            doLiquify,
            doSwapForBusd,
            swapOrLiquifyAmount
        );

        FeeEntry memory feeEntry = FeeEntry(
            id,
            from,
            to,
            percentage,
            destination,
            excludeContracts,
            doLiquify,
            doSwapForBusd,
            swapOrLiquifyAmount,
            expiresAt
        );

        feeEntries.push(feeEntry);

        emit FeeAdded(
            id,
            from,
            to,
            percentage,
            destination,
            excludeContracts,
            doLiquify,
            doSwapForBusd,
            swapOrLiquifyAmount,
            expiresAt
        );

        // Return entry index
        return feeEntries.length - 1;
    }

    function removeFee(uint256 index) external override onlyRole(ADMIN) {
        require(
            index < feeEntries.length,
            "DynamicFeeManager: array out of bounds"
        );

        // Reset current amount for liquify or swap
        bytes32 id = feeEntries[index].id;
        feeEntryAmounts[id] = 0;

        // Remove fee entry from array
        feeEntries[index] = feeEntries[feeEntries.length - 1];
        feeEntries.pop();

        emit FeeRemoved(id, index);
    }

    function reflectFees(
        address from,
        address to,
        uint256 amount
    ) external override returns (uint256 tTotal, uint256 tFees) {
        require(
            hasRole(CALL_REFLECT_FEES, _msgSender()),
            "DynamicFeeManager: Caller is missing required role"
        );

        bool bypassFees = !feesEnabled() ||
            from == owner() ||
            hasRole(ADMIN, from) ||
            hasRole(FEE_WHITELIST, from) ||
            hasRole(RECEIVER_FEE_WHITELIST, to);

        if (bypassFees) {
            return (amount, 0);
        }

        bool bypassSwapAndLiquify = hasRole(ADMIN, to) ||
            hasRole(ADMIN, from) ||
            hasRole(BYPASS_SWAP_AND_LIQUIFY, to) ||
            hasRole(BYPASS_SWAP_AND_LIQUIFY, from);

        // Loop over all fee entries and calculate plus reflect fee
        uint256 feeAmount = feeEntries.length;

        // Keep track of fees applied, to prevent applying more fees than transaction limit
        uint256 totalFeePercentage = 0;
        uint256 txFeeLimit = transactionFeeLimit();

        for (uint256 i = 0; i < feeAmount; i++) {
            FeeEntry memory fee = feeEntries[i];

            if (
                _isFeeEntryValid(fee) &&
                (_isFeeEntryMatching(fee, from, to, amount))
            ) {
                uint256 tFee = _calculateFee(amount, fee.percentage);
                uint256 tempPercentage = totalFeePercentage + fee.percentage;

                if (tFee > 0 && tempPercentage <= txFeeLimit) {
                    tFees = tFees + tFee;
                    totalFeePercentage = tempPercentage;
                    _reflectFee(from, to, tFee, fee, bypassSwapAndLiquify);
                }
            }
        }

        tTotal = amount - tFees;
        require(tTotal > 0, "DynamicFeeManager: invalid total amount");

        return (tTotal, tFees);
    }

    function _isFeeMatchingStakingUnclaim(
        FeeEntry memory fee,
        address to,
        uint256 amount
    ) private view returns (bool matching) {
        // Get users staking nfts balance
        uint256 balance = weStakeitToken().balanceOf(to);

        for (uint256 i = 0; i < balance; i++) {
            // Get staking token id
            uint256 tokenId = weStakeitToken().tokenOfOwnerByIndex(to, i);

            // Get staking entry from pool
            PoolEntry memory entry = stakingPool().poolEntry(tokenId);

            /**
             * Check if entry is:
             * - unstaked (happens right before transfer)
             * - claimed with this block (happens likely directly before transfer)
             * - fee amount is matching 3% of initial stake amount
             */
            if (
                entry.isUnstaked &&
                entry.lastClaimedAt == block.timestamp &&
                (amount * fee.percentage) / FEE_DIVIDER ==
                (entry.amount * fee.percentage) / FEE_DIVIDER
            ) {
                return true;
            }
        }

        return false;
    }

    /**
     * Reflects a single fee
     *
     * @param from address - Sender address
     * @param to address - Receiver address
     * @param tFee uint256 - Fee amount
     * @param fee FeeEntry - Fee Entry
     * @param bypassSwapAndLiquify bool - Indicator, if swap and liquify should be bypassed
     */
    function _reflectFee(
        address from,
        address to,
        uint256 tFee,
        FeeEntry memory fee,
        bool bypassSwapAndLiquify
    ) private {
        if (fee.doLiquify || fee.doSwapForBusd) {
            // add to liquify / swap amount or transfer to fee destination
            require(
                IWeSenditToken(address(token())).transferFromNoFees(
                    from,
                    address(this),
                    tFee
                ),
                "DynamicFeeManager: Fee transfer to manager failed"
            );
            feeEntryAmounts[fee.id] = feeEntryAmounts[fee.id] + tFee;
        } else {
            require(
                IWeSenditToken(address(token())).transferFromNoFees(
                    from,
                    fee.destination,
                    tFee
                ),
                "DynamicFeeManager: Fee transfer to destination failed"
            );
        }

        // Check if swap / liquify amount was reached
        if (
            !bypassSwapAndLiquify &&
            feeEntryAmounts[fee.id] >= MIN_SWAP_OR_LIQUIFY_AMOUNT &&
            feeEntryAmounts[fee.id] >= fee.swapOrLiquifyAmount
        ) {
            // Disable fees, to prevent PancakeSwap pair recursive calls
            feesEnabled_ = false;

            // Check if swap / liquify amount was reached
            uint256 tokenSwapped = 0;

            if (fee.doSwapForBusd && from != pancakePairBusdAddress()) {
                // Calculate amount of token we're going to swap
                tokenSwapped = _getSwapOrLiquifyAmount(
                    fee.id,
                    fee.swapOrLiquifyAmount,
                    percentageVolumeSwap(),
                    pancakePairBusdAddress()
                );

                // Swap token for BUSD
                _swapTokensForBusd(tokenSwapped, fee.destination);
            }

            if (fee.doLiquify && from != pancakePairBnbAddress()) {
                // Swap (BNB) and liquify token
                tokenSwapped = _swapAndLiquify(
                    _getSwapOrLiquifyAmount(
                        fee.id,
                        fee.swapOrLiquifyAmount,
                        percentageVolumeLiquify(),
                        pancakePairBnbAddress()
                    ),
                    fee.destination
                );
            }

            // Subtract amount of swapped token from fee entry amount
            feeEntryAmounts[fee.id] = feeEntryAmounts[fee.id] - tokenSwapped;

            // Enable fees again
            feesEnabled_ = true;
        }

        emit FeeReflected(
            fee.id,
            address(token()),
            from,
            to,
            tFee,
            fee.destination,
            fee.excludeContracts,
            fee.doLiquify,
            fee.doSwapForBusd,
            fee.swapOrLiquifyAmount,
            fee.expiresAt
        );
    }

    /**
     * Checks if the fee entry is still valid
     *
     * @param fee FeeEntry - Fee Entry
     *
     * @return isValid bool - Indicates, if the fee entry is still valid
     */
    function _isFeeEntryValid(
        FeeEntry memory fee
    ) private view returns (bool isValid) {
        return fee.expiresAt == 0 || block.timestamp <= fee.expiresAt;
    }

    /**
     * Checks if the fee entry matches
     *
     * @param fee FeeEntry - Fee Entry
     * @param from address - Sender address
     * @param to address - Receiver address
     *
     * @return matching bool - Indicates, if the fee entry and from / to are matching
     */
    function _isFeeEntryMatching(
        FeeEntry memory fee,
        address from,
        address to,
        uint256 amount
    ) private view returns (bool matching) {
        // Staking pool customization
        if (fee.from == address(stakingPool())) {
            return _isFeeMatchingStakingUnclaim(fee, to, amount);
        }

        return
            ((fee.from == WHITELIST_ADDRESS &&
                fee.to == WHITELIST_ADDRESS &&
                !hasRole(EXCLUDE_WILDCARD_FEE, from) &&
                !hasRole(EXCLUDE_WILDCARD_FEE, to)) &&
                !(fee.excludeContracts && _isContract(from))) ||
            (fee.from == from &&
                fee.to == WHITELIST_ADDRESS &&
                !hasRole(EXCLUDE_WILDCARD_FEE, to)) ||
            (fee.to == to &&
                fee.from == WHITELIST_ADDRESS &&
                !hasRole(EXCLUDE_WILDCARD_FEE, from)) ||
            (fee.to == to && fee.from == from);
    }

    /**
     * Calculates a single fee
     *
     * @param amount uint256 - Transaction amount
     * @param percentage uint256 - Fee percentage
     *
     * @return tFee - Total Fee Amount
     */
    function _calculateFee(
        uint256 amount,
        uint256 percentage
    ) private pure returns (uint256 tFee) {
        return (amount * percentage) / FEE_DIVIDER;
    }

    /**
     * Generates an unique identifier for a fee entry
     *
     * @param destination address - Destination address for the fee
     * @param doLiquify bool - Indicates, if the fee amount should be used to add liquidy on DEX
     * @param doSwapForBusd bool - Indicates, if the fee amount should be swapped to BUSD
     * @param swapOrLiquifyAmount uint256 - Amount for liquidify or swap
     *
     * @return id bytes32 - Unique id
     */
    function _generateIdentifier(
        address destination,
        bool doLiquify,
        bool doSwapForBusd,
        uint256 swapOrLiquifyAmount
    ) private pure returns (bytes32 id) {
        return
            keccak256(
                abi.encodePacked(
                    destination,
                    doLiquify,
                    doSwapForBusd,
                    swapOrLiquifyAmount
                )
            );
    }
}
