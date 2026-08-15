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

    /// @notice The role is always on somebody's books, and at most that one address may act
    /// @dev The address and the power are separate facts now: a suspension and an outstanding
    ///      handover both leave the role dormant, with nobody able to act, while the address stays
    ///      recorded. What must never happen is the address itself going missing, because both
    ///      routes back go through it. A withdrawal names the incumbent and a suspension is lifted
    ///      on the incumbent, so a zero there would leave the role unreachable for good.
    ///
    ///      An outstanding nomination naming the incumbent is the state the rotation is supposed to
    ///      collapse into a withdrawal. Leaving one there would mean the admin could hand the role
    ///      to itself, which reads as a rotation in the logs and moves nothing. Compared against
    ///      the recorded address rather than the accessor, which answers zero in exactly the state
    ///      this is checking and would make the assertion vacuous there.
    function invariant_adminRoleHasOneHolder() public view {
        address onRecord = registry.adminOfRecord();

        assertTrue(onRecord != address(0), "The admin role has no holder");
        assertTrue(
            registry.newRequestedAdmin() != onRecord,
            "The sitting admin is also the nominee for its own role"
        );

        // Nobody but the recorded address ever holds the power, so a dormant role cannot be picked
        // up by a third address while it is down.
        address acting = registry.eSIMWalletAdmin();
        assertTrue(
            acting == address(0) || acting == onRecord,
            "An address that is not on the books can act as admin"
        );

        // And dormant means dormant either way round, so neither state can be read as live.
        if(registry.adminDisabled() || registry.newRequestedAdmin() != address(0)) {
            assertEq(acting, address(0), "A suspended or handed-over admin can still act");
        }
    }

    /// @notice The campaign never moves the clock
    /// @dev There is no `vm.warp` anywhere in the suite, on purpose. Any sequence that appeared to
    ///      depend on elapsed time would be reporting on the harness rather than the protocol, and
    ///      this is what stops one being added without the consequence being noticed.
    function invariant_timeIsStatic() public view {
        assertEq(block.timestamp, campaignStartTime, "The campaign moved the clock");
    }
}
