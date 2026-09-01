// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

/// @notice Proves the campaign's entry points can actually reach the protocol.
/// @dev `fail_on_revert` is false across every invariant file, which is the only workable setting
///      with this many access control modifiers. It also hides the failure mode that makes a whole
///      campaign worthless: handlers whose calls all revert, which stays green while testing
///      nothing. This drives each entry point directly and asserts it got through.
///
///      Deliberately an ordinary test and not an assertion inside a campaign. Anything checked per
///      sequence is subject to the shrinker, which searches for the shortest failing sequence and
///      so will always find one that starves an entry point. Measured: an `afterInvariant` version
///      of this failed at `1 < 20` with the shrinker cutting a 500-call sequence down to exactly
///      the guard boundary.
contract HandlerDistributionTest is CampaignBase {

    /// @notice How many times the drive exercises each entry point
    uint256 internal constant DRIVE_ROUNDS = 40;

    /// @notice Successful executions each entry point has to reach in that drive
    uint256 internal constant MIN_SUCCESSES = 20;

    /// @notice Seeds reserved per round, wide enough for the largest batch plus one spare
    uint256 internal constant SEEDS_PER_ROUND = 8;

    /// @notice Offset placing rotation keys outside every seed the deploy paths consume
    /// @dev A rotation onto a key some wallet is already registered under is refused, which is
    ///      correct and is covered by the campaign. This drive wants the rotation to go through.
    uint256 internal constant ROTATION_SEEDS = 500_000;

    /// @notice Offset placing switch destinations outside the identifiers the lazy path populates
    uint256 internal constant SWITCH_SEEDS = 100_000;

    /// @notice Width of the reference block each payment path draws from
    /// @dev Three paths, one block each, laid out end to end. The handler wraps its seeds into a
    ///      pool of 128, so the three blocks together have to stay inside that or one path
    ///      re-presents a reference another already spent.
    uint256 internal constant PAYMENT_REFERENCE_SEEDS = DRIVE_ROUNDS;

    /// @notice Every entry point can reach the protocol and change its state
    function test_handlersReachEveryEntryPoint() public {
        // A batch consumes up to three consecutive seeds and each seed becomes an identifier, so
        // the two deploy paths are given disjoint blocks. Overlapping them would have the second
        // path re-present an identifier the first already claimed, which is a real case the
        // campaign covers but not what this test is asking about
        for (uint256 round = 0; round < DRIVE_ROUNDS; ++round) {
            uint256 seed = round * SEEDS_PER_ROUND;

            adminHandler.deployDeviceWalletBatch(round, seed, 1 ether, false);
            attackerHandler.createAccountPermissionless(seed + SEEDS_PER_ROUND - 1, round, false);
            adminHandler.postCreateAccount(round);
            walletHandler.rotateOwnerKey(round, seed + ROTATION_SEEDS);

            // The lazy path is index-sensitive in a way the others are not, because a device
            // identifier can only be deployed once and can only be switched away from while it has
            // no wallet. Reading the positions back rather than computing them keeps this working
            // if the number of identifiers a round adds ever changes
            // Three eSIMs rather than two because one is switched away below and the deploy is
            // deliberately given a batch of one, so two have to be left for the continuation to have
            // anything outstanding to reach
            adminHandler.populateLazyHistory(seed, 3, false, false);
            uint256 lazyDevice = state.lazyDeviceIdentifierCount() - 1;
            uint256 lazyESIM = state.lazyESIMIdentifierCount() - 3;
            adminHandler.switchESIMIdentifier(lazyESIM, seed + SWITCH_SEEDS, false);
            adminHandler.deployLazyWallet(lazyDevice, seed, 1 ether, 1);
            adminHandler.deployMoreLazyESIMWallets(lazyDevice, 1);
            // Follows both deploy calls in the same round. History only reaches a wallet that
            // exists, so running this before them would count as a revert and never reach a success
            adminHandler.copyLazyHistory(lazyESIM + 1, 50);

            attackerHandler.donateETH(round, 1 ether);
            attackerHandler.donateToSingleton(round, 1 ether);
            adminHandler.deployESIMWalletForDevice(round, seed + 2000);
            // Follows the deploy so there is always a wallet still waiting for an identifier
            adminHandler.setESIMIdentifier(round, seed + 3000, false);
            walletHandler.toggleAccessToFunds(round, true);
            walletHandler.setESIMWalletPriceCap(round, round);
            // Each payment path is given its own block of reference seeds. Two calls presenting
            // the same reference is a case the campaign covers, and the second one is refused,
            // which is a revert rather than the count this drive is checking
            paymentHandler.recordSettledPurchase(round, 100, round + PAYMENT_REFERENCE_SEEDS, 0, false);
            paymentHandler.buyDataBundleWithToken(round, 100, 10e6, round + 2 * PAYMENT_REFERENCE_SEEDS);
            paymentHandler.quote(0, 100);
            // Withdrawn and put back inside the round, so the next round starts from the same
            // currency table this one did
            paymentHandler.updateAsset(1, false, true);
            paymentHandler.updateAsset(1, true, true);
            walletHandler.pullToken(round, 1_000e6, 5_000e6);
            // Removal comes before the transfer pair on purpose. Requesting a transfer detaches
            // the wallet on its way through, so a removal after it has nothing left to remove.
            //
            // The pair is read out of the recorded state rather than driven off the round number.
            // Adding a wallet back needs the device that owns it, and two indexes that happen to
            // line up only do so while every round records the same number of each
            (uint256 eSIMIndex, uint256 deviceIndex) = _boundESIMWalletToItsDevice();
            walletHandler.removeESIMWallet(eSIMIndex, true, false);
            walletHandler.addESIMWallet(deviceIndex, eSIMIndex);
            walletHandler.requestTransferOwnership(round, round + 1);
            walletHandler.acceptOwnershipTransfer(round);

            // The role has to travel and come back inside one round. Leaving it with the successor
            // would put every admin call in the next round through an address holding a different
            // budget, which is a case the campaign covers but would make this drive's deposits
            // depend on which round they landed in
            upgradeManagerHandler.requestAdminUpdate(false);
            adminHandler.acceptAdminUpdate();
            upgradeManagerHandler.requestAdminUpdate(false);
            adminHandler.acceptAdminUpdate();

            // The suspension is lifted inside the round for the same reason. A run that left the
            // admin suspended would have every admin call after it refused, and each would reach a
            // revert count rather than the call count this drive is checking
            upgradeManagerHandler.disableAdmin();
            upgradeManagerHandler.enableAdmin();

            // Both beacons go to the second implementation and back inside the round. Leaving
            // either on the alternative would have the next round's deploys run against a
            // different implementation than the one this drive started from
            upgradeManagerHandler.upgradeDeviceWalletBeacon(true);
            upgradeManagerHandler.upgradeDeviceWalletBeacon(false);
            upgradeManagerHandler.upgradeESIMWalletBeacon(true);
            upgradeManagerHandler.upgradeESIMWalletBeacon(false);
            upgradeManagerHandler.setDefaultPriceCap(round);

            // The release has to follow the pause in the same round, or every ETH path in the
            // rounds after this one would be refused and would never reach its own count
            adminHandler.pauseProtocol(0);
            upgradeManagerHandler.unpauseProtocol();
        }

        _assertExercised("deployDeviceWalletBatch");
        _assertExercised("createAccountPermissionless");
        _assertExercised("postCreateAccount");
        _assertExercised("rotateOwnerKey");
        _assertExercised("populateLazyHistory");
        _assertExercised("switchESIMIdentifier");
        _assertExercised("deployLazyWallet");
        _assertExercised("deployMoreLazyESIMWallets");
        _assertExercised("copyLazyHistory");
        _assertExercised("donateETH");
        _assertExercised("donateToSingleton");
        _assertExercised("deployESIMWalletForDevice");
        _assertExercised("setESIMIdentifier");
        _assertExercised("toggleAccessToFunds");
        _assertExercised("buyDataBundleWithToken");
        _assertExercised("recordSettledPurchase");
        _assertExercised("quote");
        _assertExercised("updateAsset");
        _assertExercised("pullToken");
        _assertExercised("removeESIMWallet");
        _assertExercised("addESIMWallet");
        _assertExercised("requestTransferOwnership");
        _assertExercised("acceptOwnershipTransfer");
        _assertExercised("requestAdminUpdate");
        _assertExercised("acceptAdminUpdate");
        _assertExercised("disableAdmin");
        _assertExercised("enableAdmin");
        _assertExercised("pauseProtocol");
        _assertExercised("unpauseProtocol");
        _assertExercised("setDefaultPriceCap");
        _assertExercised("setESIMWalletPriceCap");
        _assertExercised("upgradeDeviceWalletBeacon");
        _assertExercised("upgradeESIMWalletBeacon");
    }

    /// @notice Fails if an entry point never got through
    /// @param name Entry point to check
    function _assertExercised(bytes32 name) internal view {
        assertGe(
            state.calls(name),
            MIN_SUCCESSES,
            string.concat("Entry point never reached the protocol: ", _name(name))
        );
    }

    /// @notice Finds an attached eSIM wallet and the position of the device wallet holding it
    /// @dev Both handlers take positions into the recorded arrays, and a removal followed by an add
    ///      only works when the two name the same pair. Scanning for one is what keeps this drive
    ///      working when a round starts recording a different number of eSIM wallets than devices.
    ///
    ///      The device wallet's own claim is what says "currently attached". The registry's
    ///      association answers a different question, which device wallet last held it, and it
    ///      stays non-zero for the rest of the wallet's life. Reading it here instead would return
    ///      the same released wallet every round and the removal would only ever land once.
    /// @return eSIMIndex Position of an eSIM wallet that currently has a device wallet
    /// @return deviceIndex Position of that device wallet
    function _boundESIMWalletToItsDevice() internal view returns (uint256 eSIMIndex, uint256 deviceIndex) {
        uint256 eSIMCount = state.eSIMWalletCount();
        uint256 deviceCount = state.deviceWalletCount();

        for (uint256 i = 0; i < eSIMCount; ++i) {
            address wallet = state.eSIMWallets(i);
            address device = registry.isESIMWalletValid(wallet);
            if (device == address(0)) continue;
            if (!MockDeviceWallet(payable(device)).isValidESIMWallet(wallet)) continue;

            for (uint256 j = 0; j < deviceCount; ++j) {
                if (state.deviceWallets(j) == device) return (i, j);
            }
        }

        return (0, 0);
    }

    /// @notice Renders a padded entry point name for a failure message
    /// @param name Entry point name, right-padded with zero bytes
    /// @return The name without its padding
    function _name(bytes32 name) internal pure returns (string memory) {
        uint256 length;
        while (length < 32 && name[length] != 0) ++length;
        bytes memory trimmed = new bytes(length);
        for (uint256 i = 0; i < length; ++i) trimmed[i] = name[i];
        return string(trimmed);
    }
}
