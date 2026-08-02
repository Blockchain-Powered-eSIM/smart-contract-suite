// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

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

    /// @notice Every entry point can reach the protocol and change its state
    function test_handlersReachEveryEntryPoint() public {
        // A batch consumes up to three consecutive seeds and each seed becomes an identifier, so
        // the two deploy paths are given disjoint blocks. Overlapping them would have the second
        // path re-present an identifier the first already claimed, which is a real case the
        // campaign covers but not what this test is asking about
        for (uint256 round = 0; round < DRIVE_ROUNDS; ++round) {
            uint256 seed = round * SEEDS_PER_ROUND;

            adminHandler.deployDeviceWalletBatch(round, seed, 1 ether);
            attackerHandler.createAccountPermissionless(seed + SEEDS_PER_ROUND - 1, round, false);
            adminHandler.postCreateAccount(round);
            walletHandler.rotateOwnerKey(round, seed + ROTATION_SEEDS);

            // The lazy path is index-sensitive in a way the others are not, because a device
            // identifier can only be deployed once and can only be switched away from while it has
            // no wallet. Reading the positions back rather than computing them keeps this working
            // if the number of identifiers a round adds ever changes
            adminHandler.populateLazyHistory(seed, 2, false);
            uint256 lazyDevice = state.lazyDeviceIdentifierCount() - 1;
            uint256 lazyESIM = state.lazyESIMIdentifierCount() - 2;
            adminHandler.switchESIMIdentifier(lazyESIM, seed + SWITCH_SEEDS, false);
            adminHandler.deployLazyWallet(lazyDevice, seed, 1 ether);

            attackerHandler.donateETH(round, 1 ether);
            attackerHandler.donateToSingleton(round, 1 ether);
            adminHandler.deployESIMWalletForDevice(round, true, seed + 2000);
            walletHandler.toggleAccessToETH(round, true);
            adminHandler.buyDataBundle(round, 1 gwei);
            walletHandler.pullETH(round, 1 gwei);
            // Removal comes before the transfer pair on purpose. Requesting a transfer detaches
            // the wallet on its way through, so a removal after it has nothing left to remove
            walletHandler.removeESIMWallet(round, true, false);
            walletHandler.addESIMWallet(round, round);
            walletHandler.requestTransferOwnership(round, round + 1);
            walletHandler.acceptOwnershipTransfer(round);

            // The role has to travel and come back inside one round. Leaving it with the successor
            // would put every admin call in the next round through an address holding a different
            // budget, which is a case the campaign covers but would make this drive's deposits
            // depend on which round they landed in
            adminHandler.requestAdminUpdate(false);
            adminHandler.acceptAdminUpdate();
            adminHandler.requestAdminUpdate(false);
            adminHandler.acceptAdminUpdate();
        }

        _assertExercised("deployDeviceWalletBatch");
        _assertExercised("createAccountPermissionless");
        _assertExercised("postCreateAccount");
        _assertExercised("rotateOwnerKey");
        _assertExercised("populateLazyHistory");
        _assertExercised("switchESIMIdentifier");
        _assertExercised("deployLazyWallet");
        _assertExercised("donateETH");
        _assertExercised("donateToSingleton");
        _assertExercised("deployESIMWalletForDevice");
        _assertExercised("toggleAccessToETH");
        _assertExercised("buyDataBundle");
        _assertExercised("pullETH");
        _assertExercised("removeESIMWallet");
        _assertExercised("addESIMWallet");
        _assertExercised("requestTransferOwnership");
        _assertExercised("acceptOwnershipTransfer");
        _assertExercised("requestAdminUpdate");
        _assertExercised("acceptAdminUpdate");
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
