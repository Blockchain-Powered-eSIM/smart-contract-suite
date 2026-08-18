// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Gas for the registry writes the deploy paths and the admin key make.
/// @dev `updateDeviceWalletInfo` is the expensive one and it runs once per device, so its cold and
///      warm figures set the floor under every deployment number in the factory file. The pause pair
///      is here because the two halves are gated on different keys, and a release that has to wait
///      on anything is an outage rather than a delay.
contract RegistryOperationsGasTest is GasBase {

    string internal NAMESPACE = "Registry.Operations";

    /// @notice Writing a device's bindings, on cold storage and then on warm
    /// @dev Four mappings are written per device and none of them are shared between devices, so the
    ///      second call is warm only on the access control reads and the pause flag. The gap between
    ///      the two is what those shared reads cost.
    function test_updateDeviceWalletInfo() public {
        vm.prank(address(deviceWalletFactory));
        registry.updateDeviceWalletInfo(user1, customDeviceUniqueIdentifiers[0], pubKey1);
        vm.snapshotGasLastCall(NAMESPACE, "updateDeviceWalletInfo: first device, cold storage");

        vm.prank(address(deviceWalletFactory));
        registry.updateDeviceWalletInfo(user2, customDeviceUniqueIdentifiers[1], pubKey2);
        vm.snapshotGasLastCall(NAMESPACE, "updateDeviceWalletInfo: second device, warm storage");
    }

    /// @notice Naming an eSIM, the admin's most frequent write
    /// @dev One call per eSIM sold. It records the claim and writes the wallet's own slot, so the
    ///      figure covers both and there is no second transaction behind it.
    function test_assignESIMIdentifier() public {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = 8701;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            new uint256[](1)
        );

        vm.prank(eSIMWalletAdmin);
        registry.assignESIMIdentifier(wallets[0].eSIMWallet, "eSIM_gas_assign");
        vm.snapshotGasLastCall(NAMESPACE, "assignESIMIdentifier: first time");
    }

    /// @notice Tripping the pause and releasing it
    /// @dev Separate labels because they are separate keys. The admin trips it from a backend that
    ///      is already signing batches; the release is the owner's, and after the admin contract
    ///      lands that is a contract rather than an EOA.
    function test_pauseAndUnpause() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();
        vm.snapshotGasLastCall(NAMESPACE, "pause");

        vm.prank(upgradeManager);
        registry.unpause();
        vm.snapshotGasLastCall(NAMESPACE, "unpause");
    }

    /// @notice The two halves of an admin key rotation
    function test_adminRotation() public {
        vm.prank(registry.owner());
        registry.requestAdminUpdate(user3);
        vm.snapshotGasLastCall(NAMESPACE, "requestAdminUpdate");

        vm.prank(user3);
        registry.acceptAdminUpdate();
        vm.snapshotGasLastCall(NAMESPACE, "acceptAdminUpdate");
    }

    /// @notice Moving the default price cap new eSIM wallets inherit
    function test_setDefaultDataBundlePriceCap() public {
        vm.prank(upgradeManager);
        registry.setDefaultDataBundlePriceCap(2 ether);
        vm.snapshotGasLastCall(NAMESPACE, "setDefaultDataBundlePriceCap");
    }

    /// @notice Pointing every data bundle payment at a different vault
    function test_updateVaultAddress() public {
        vm.prank(upgradeManager);
        registry.updateVaultAddress(user5);
        vm.snapshotGasLastCall(NAMESPACE, "updateVaultAddress");
    }

    /// @notice Putting a deployed eSIM wallet on standby and taking it off again
    function test_toggleESIMWalletStandbyStatus() public {
        (MockDeviceWallet deviceWallet, MockESIMWallet eSIMWallet) = _deployDeviceWallet(
            customDeviceUniqueIdentifiers[0],
            0,
            8400
        );

        vm.prank(address(deviceWallet));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet), true);
        vm.snapshotGasLastCall(NAMESPACE, "toggleESIMWalletStandbyStatus: onto standby");

        vm.prank(address(deviceWallet));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet), false);
        vm.snapshotGasLastCall(NAMESPACE, "toggleESIMWalletStandbyStatus: off standby");
    }
}
