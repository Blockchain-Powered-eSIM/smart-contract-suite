// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

/// @notice What has to stay true about the protocol's own configuration.
/// @dev None of this is user state. It is the set of addresses and roles the contracts read out of
///      each other, and every one of them is written in more than one place with nothing checking
///      that the copies agree. A beacon swap and an admin rotation both run during the campaign,
///      which are the two things that would pull them apart.
contract ConfigInvariantsTest is CampaignBase {

    /// @notice Every wallet points at the same entry point the singletons do
    /// @dev The address is held three times over: once in the registry, once in the factory, and
    ///      once in the wallet implementation's own immutable, where a beacon swap is the thing
    ///      that could replace it. Nothing in the protocol reconciles the three, so a swap onto an
    ///      implementation built against a different entry point would leave every wallet
    ///      validating against one address while the singletons name another.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_entryPointIsTheSameEverywhere() public view {
        address expected = address(registry.entryPoint());

        assertEq(
            address(deviceWalletFactory.entryPoint()),
            expected,
            "The factory and the registry name different entry points"
        );

        uint256 count = state.deviceWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            assertEq(
                address(DeviceWallet(payable(state.deviceWallets(i))).entryPoint()),
                expected,
                "A device wallet validates against a different entry point than the registry names"
            );
        }
    }

    /// @notice The admin role always sits with exactly one address, and never with nobody
    /// @dev An outstanding nomination naming the sitting admin is the state the rotation is
    ///      supposed to collapse into a withdrawal. Leaving one there would mean the admin could
    ///      hand the role to itself, which reads as a rotation in the logs and moves nothing.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_adminRoleHasOneHolder() public view {
        address current = registry.eSIMWalletAdmin();

        assertTrue(current != address(0), "The admin role has no holder");
        assertTrue(
            registry.newRequestedAdmin() != current,
            "The sitting admin is also the nominee for its own role"
        );
    }

    /// @notice The campaign never moves the clock
    /// @dev There is no `vm.warp` anywhere in the suite, on purpose. Any sequence that appeared to
    ///      depend on elapsed time would be reporting on the harness rather than the protocol, and
    ///      this is what stops one being added without the consequence being noticed.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_timeIsStatic() public view {
        assertEq(block.timestamp, campaignStartTime, "The campaign moved the clock");
    }
}
