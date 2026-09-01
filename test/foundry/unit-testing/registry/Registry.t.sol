// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "test/utils/DeployerBase.sol";

/// @notice The pause, the vault and the price ceiling, and which key holds each of them.
/// @dev The admin role itself lives in `AdminRotation.t.sol`. What is here is the rest of the
///      registry's switchboard, and mainly the split that keeps one key from holding both ends of
///      the pause.
contract RegistryTest is DeployerBase {

    // Redeclared so expectEmit can name it. An inherited event is not reachable through a contract
    // instance, and this test contract does not inherit RegistryHelper.
    event VaultAddressUpdated(address indexed _updatedVaultAddress);

    /// @notice The admin trips the pause, so an operator watching the backend can act without
    /// waiting on the upgrade key. Nobody else can, including the owner.
    function test_pause_onlyTheAdminCanTripIt() public {
        vm.prank(registry.owner());
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        assertEq(registry.paused(), false, "The rejected calls must leave the protocol running");

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();
        assertEq(registry.paused(), true, "The admin's call must have tripped the pause");
    }

    /// @notice Release is the owner's, not the admin's. The admin key signs backend batches all
    /// day, and holding both ends would let one hot key freeze user funds indefinitely.
    function test_unpause_onlyTheOwnerCanReleaseIt() public {
        // Read outside the prank. A view call here would consume it before unpause is reached.
        address admin = registry.eSIMWalletAdmin();

        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", admin));
        registry.unpause();

        assertEq(registry.paused(), true, "The admin must not be able to release its own pause");

        vm.prank(registry.owner());
        registry.unpause();
        assertEq(registry.paused(), false, "The owner's call must have released the pause");
    }

    /// @notice The flag has to survive an admin rotation, and the incoming admin has to inherit the
    /// ability to trip it.
    function test_pause_survivesAnAdminRotation() public {
        address retiredAdmin = registry.eSIMWalletAdmin();

        vm.prank(retiredAdmin);
        registry.pause();

        vm.prank(registry.owner());
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        assertEq(registry.paused(), true, "The rotation must not have cleared the pause");

        vm.prank(registry.owner());
        registry.unpause();

        vm.prank(retiredAdmin);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.pause();

        vm.prank(user3);
        registry.pause();
        assertEq(registry.paused(), true, "The incoming admin must be able to trip it");
    }

    /// @notice requireNotPaused is what the wallets call, so it has to carry the same named revert
    /// wherever it is reached from.
    function test_requireNotPaused_revertsOnlyWhilePaused() public {
        registry.requireNotPaused();

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();

        vm.expectRevert(Errors.ProtocolPaused.selector);
        registry.requireNotPaused();
    }

    /// @notice The fallback price ceiling is the owner's to set, not the admin's.
    /// @dev The admin names the price on every purchase, so an admin that could also raise the
    /// ceiling would be constrained by nothing.
    function test_setDefaultPriceCapUSDCents_rejectsTheAdmin() public {
        address admin = registry.eSIMWalletAdmin();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", admin));
        registry.setDefaultPriceCapUSDCents(100_000);

        assertEq(
            registry.defaultPriceCapUSDCents(),
            defaultPriceCapUSDCents,
            "The admin must not be able to change the ceiling"
        );

        vm.prank(registry.owner());
        registry.setDefaultPriceCapUSDCents(2 ether);
        assertEq(registry.defaultPriceCapUSDCents(), 2 ether, "The owner must be able to set it");
    }

    /// @notice The fallback price ceiling can never be lowered to zero.
    /// @dev A zero cap here reads as "no ceiling" in `ESIMWallet._requirePriceWithinCap` for every
    /// wallet that has not set its own, so the setter refuses it the same way `initialize` does.
    function test_setDefaultPriceCapUSDCents_rejectsZero() public {
        vm.prank(registry.owner());
        vm.expectRevert(Errors.ZeroDataBundlePriceCap.selector);
        registry.setDefaultPriceCapUSDCents(0);
    }

    /// @notice Moving the vault is the owner's, not the admin's. It is the destination of every
    /// payment the protocol collects, so it belongs behind the same delay as an upgrade.
    function test_updateVaultAddress_rejectsTheAdmin() public {
        address admin = registry.eSIMWalletAdmin();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", admin));
        registry.updateVaultAddress(user2);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        registry.updateVaultAddress(user2);

        assertEq(registry.vault(), vault, "Neither the admin nor a stranger may move the vault");
    }

    /// @notice A zero vault would send every data bundle payment to an address nobody holds.
    function test_updateVaultAddress_rejectsTheZeroAddress() public {
        vm.prank(registry.owner());
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_newVaultAddress"));
        registry.updateVaultAddress(address(0));

        assertEq(registry.vault(), vault, "The vault must be unchanged after a rejected write");
    }

    /// @notice Rewriting the same address is rejected, so an emitted event always means a real move.
    function test_updateVaultAddress_rejectsTheCurrentAddress() public {
        vm.prank(registry.owner());
        vm.expectRevert(abi.encodeWithSelector(Errors.VaultUnchanged.selector, vault));
        registry.updateVaultAddress(vault);
    }

    /// @notice The owner can move the vault, and the write announces itself.
    function test_updateVaultAddress() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit VaultAddressUpdated(user2);

        vm.prank(registry.owner());
        address inForce = registry.updateVaultAddress(user2);

        assertEq(inForce, user2, "The call must report the address now in force");
        assertEq(registry.vault(), user2, "The registry must hold the new vault");
    }
}
