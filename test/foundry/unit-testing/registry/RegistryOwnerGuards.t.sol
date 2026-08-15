// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice `bindESIMWallet` and `toggleESIMWalletStandbyStatus` must authorize on the eSIM wallet's
///         real owner, not on the registry's own stale association.
/// @dev `ESIMWallet.acceptOwnershipTransfer` moves `owner()` and `deviceWallet` without touching the
///      registry, and nothing forces the new owner to call `addESIMWallet` back. Until it does, the
///      old device wallet is a former owner that the two functions below must refuse.
contract RegistryOwnerGuardsTest is DeployerBase {

    /// @notice Deploys two device wallets and transfers one's eSIM wallet to the other, accepted but
    ///         never bound back through `addESIMWallet`
    /// @dev This is the state a caller reaches after a handover nobody finished: the real owner is
    ///      the new device wallet, but the registry association still names the old one, since only
    ///      `bindESIMWallet` moves it.
    function _deployAndTransferWithoutRebinding() internal returns (
        MockDeviceWallet formerDeviceWallet,
        MockDeviceWallet newDeviceWallet,
        MockESIMWallet eSIMWallet
    ) {
        string[] memory identifiers = new string[](2);
        identifiers[0] = customDeviceUniqueIdentifiers[0];
        identifiers[1] = customDeviceUniqueIdentifiers[1];

        bytes32[2][] memory keys = new bytes32[2][](2);
        keys[0] = pubKey1;
        keys[1] = pubKey2;

        uint256[] memory salts = new uint256[](2);
        salts[0] = 8501;
        salts[1] = 8502;

        uint256[] memory deposits = new uint256[](2);

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        );

        formerDeviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        newDeviceWallet = MockDeviceWallet(payable(wallets[1].deviceWallet));
        eSIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        vm.prank(address(formerDeviceWallet));
        eSIMWallet.requestTransferOwnership(address(newDeviceWallet));

        vm.prank(address(newDeviceWallet));
        eSIMWallet.acceptOwnershipTransfer();

        assertEq(eSIMWallet.owner(), address(newDeviceWallet), "Ownership must have moved");
        assertEq(
            registry.isESIMWalletValid(address(eSIMWallet)),
            address(formerDeviceWallet),
            "The association must still name the former device wallet"
        );
    }

    /// @notice A device wallet that no longer owns an eSIM wallet cannot flip its standby marker
    function test_toggleESIMWalletStandbyStatus_rejectsAFormerDeviceWallet() public {
        (MockDeviceWallet formerDeviceWallet, , MockESIMWallet eSIMWallet) = _deployAndTransferWithoutRebinding();

        vm.prank(address(formerDeviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.NotTheESIMWalletOwnerOrItsDeviceWallet.selector, address(eSIMWallet)
        ));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet), false);
    }

    /// @notice A device wallet that no longer owns an eSIM wallet cannot bind it back to itself
    function test_bindESIMWallet_rejectsAFormerDeviceWallet() public {
        (MockDeviceWallet formerDeviceWallet, , MockESIMWallet eSIMWallet) = _deployAndTransferWithoutRebinding();

        vm.prank(address(formerDeviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.NotTheESIMWalletOwnerOrItsDeviceWallet.selector, address(eSIMWallet)
        ));
        registry.bindESIMWallet(address(eSIMWallet), address(formerDeviceWallet));
    }

    /// @notice The one production caller, `DeviceWallet.removeESIMWallet`, still raises the standby
    ///         marker once the guard reads the real owner
    /// @dev Ownership has not moved at this point: `removeESIMWallet` runs before
    ///      `acceptOwnershipTransfer`, so `ESIMWallet.owner()` still names the calling device wallet.
    function test_removeESIMWallet_stillRaisesTheStandbyMarker() public {
        string[] memory identifiers = new string[](1);
        identifiers[0] = customDeviceUniqueIdentifiers[0];

        bytes32[2][] memory keys = new bytes32[2][](1);
        keys[0] = pubKey1;

        uint256[] memory salts = new uint256[](1);
        salts[0] = 8503;

        uint256[] memory deposits = new uint256[](1);

        vm.prank(eSIMWalletAdmin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        )[0];

        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(wallet.deviceWallet));
        MockESIMWallet eSIMWallet = MockESIMWallet(payable(wallet.eSIMWallet));

        assertEq(eSIMWallet.owner(), address(deviceWallet), "Owner must still be the device wallet");

        vm.prank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet), false);

        assertTrue(
            registry.isESIMWalletOnStandby(address(eSIMWallet)),
            "removeESIMWallet must still raise the standby marker"
        );
    }
}
