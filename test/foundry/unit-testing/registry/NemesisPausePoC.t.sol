// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeployerBase} from "test/utils/DeployerBase.sol";
import {Errors} from "contracts/Errors.sol";

/// @notice Suspending the admin, or nominating a replacement, takes the pause lever from the admin
///         key but not from the owner
/// @dev `pause()` used to be gated on `eSIMWalletAdmin()` alone, which answers zero in both
///      states, so nobody could pause at all while either held. The owner now has the lever too,
///      which is the route `ProtocolAdmin.pauseInstantly` gives a guardian.
contract NemesisPausePoC is DeployerBase {

    function test_NM005_suspendingTheAdminLeavesTheOwnersPauseLever() public {
        // The admin can pause while it holds its powers.
        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused(), "admin can pause normally");

        vm.prank(upgradeManager);
        registry.unpause();
        assertFalse(registry.paused(), "owner released it");

        // The incident: the admin key is compromised, so the owner suspends it.
        vm.prank(upgradeManager);
        registry.disableAdmin();

        assertEq(registry.eSIMWalletAdmin(), address(0), "nobody holds the admin role now");
        assertEq(registry.adminOfRecord(), eSIMWalletAdmin, "the address is still on the books");

        // The attacker lost the lever, which is the point of the suspension.
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        // The owner keeps it, so the protocol can still be stopped during the incident
        vm.prank(upgradeManager);
        registry.pause();

        assertTrue(registry.paused(), "the owner must still be able to pause");
    }

    function test_NM005_anOutstandingNominationAlsoRemovesIt() public {
        address incomingAdmin = makeAddr("incomingAdmin");

        // An ordinary rotation, not an incident. The owner nominates a replacement.
        vm.prank(upgradeManager);
        registry.requestAdminUpdate(incomingAdmin);

        assertEq(registry.eSIMWalletAdmin(), address(0), "the role is dormant mid-rotation");

        // Neither the outgoing nor the incoming admin can pause until acceptance lands.
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        vm.prank(incomingAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        // Acceptance closes the window, and it is the nominee's call to make, not the owner's.
        vm.prank(incomingAdmin);
        registry.acceptAdminUpdate();

        vm.prank(incomingAdmin);
        registry.pause();
        assertTrue(registry.paused(), "the lever is back only once the nominee accepts");
    }

    function test_NM005_theOwnerCanPauseMidRotation() public {
        vm.prank(upgradeManager);
        registry.requestAdminUpdate(makeAddr("incomingAdmin"));

        vm.prank(upgradeManager);
        registry.pause();

        vm.expectRevert(Errors.ProtocolPaused.selector);
        registry.requireNotPaused();
    }

    /// @notice Nobody but the live admin and the owner can pause
    function test_NM005_aStrangerStillCannotPause() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();
    }
}
