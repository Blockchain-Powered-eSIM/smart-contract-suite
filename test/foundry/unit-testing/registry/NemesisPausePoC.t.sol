// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeployerBase} from "test/utils/DeployerBase.sol";
import {Errors} from "contracts/Errors.sol";

/// @notice Shows that suspending the admin, or nominating a replacement, removes the pause lever
/// @dev `pause()` is the only writer of `paused` and it is gated on `eSIMWalletAdmin()`, which
///      answers zero in both states. No transaction can arrive from the zero address, so the
///      emergency lever is uncallable by every account while either state holds.
contract NemesisPausePoC is DeployerBase {

    function test_NM005_suspendingTheAdminRemovesThePauseLever() public {
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

        // So did everybody else. The owner has no route to it either.
        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        assertFalse(registry.paused(), "the protocol cannot be paused by anyone");
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

    function test_NM005_theProtocolStaysUnpausedWhileThePauseIsUnreachable() public {
        // A regression pin on the accessor, not a demonstration of exposure. Both ETH paths carry
        // their own `requireNotPaused` check, at ESIMWallet.sol:284 and DeviceWallet.sol:222, so
        // there is nothing reachable here that a pause would not have stopped. What this holds in
        // place is that suspending the admin leaves `paused` false with no account able to set it.
        vm.prank(upgradeManager);
        registry.disableAdmin();

        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        registry.requireNotPaused();
    }
}
