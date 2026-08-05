// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";

/// @notice Gas for the device wallet deploy paths.
/// @dev The two entry points cost very different things. `createAccount` is permissionless and
///      deploys the wallet alone; `deployDeviceWalletForUsers` is the admin batch that also writes
///      the registry bindings and deploys the device's first eSIM wallet. The batch numbers are what
///      the backend sizes its transactions against, so the per-entry cost between a batch of one and
///      a batch of five is the figure that matters rather than either total on its own.
contract DeviceWalletFactoryOperationsGasTest is GasBase {

    string internal NAMESPACE = "DeviceWalletFactory.Operations";

    /// @notice The permissionless deploy, on a cold factory and then on a warm one
    function test_createAccount() public {
        vm.prank(user1);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 8001);
        vm.snapshotGasLastCall(NAMESPACE, "createAccount: first wallet, cold factory storage");

        vm.prank(user1);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[1], pubKey2, 8002);
        vm.snapshotGasLastCall(NAMESPACE, "createAccount: second wallet, warm factory storage");
    }

    /// @notice The admin batch at one entry, which carries the whole fixed cost
    function test_deployDeviceWalletForUsers_singleEntry() public {
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _batch(1, "GasDeviceSingle_", 8100);

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);
        vm.snapshotGasLastCall(NAMESPACE, "deployDeviceWalletForUsers: batch of 1");
    }

    /// @notice The same batch at five entries, so the fixed cost can be separated from the per-entry
    /// @dev Five is the ceiling here because the fixture holds five owner keys and the factory
    ///      rejects a key that is not a point on the curve.
    function test_deployDeviceWalletForUsers_fiveEntries() public {
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _batch(5, "GasDeviceFive_", 8200);

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);
        vm.snapshotGasLastCall(NAMESPACE, "deployDeviceWalletForUsers: batch of 5");
    }

    /// @notice A batch entry that funds the wallet it deploys
    /// @dev The deposit lands on the wallet rather than on the entry point, so this is an ordinary
    ///      value transfer on top of the deploy rather than a `depositTo` call.
    function test_deployDeviceWalletForUsers_withDeposit() public {
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _batch(1, "GasDeviceFunded_", 8300);
        deposits[0] = 1 ether;

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(identifiers, keys, salts, deposits);
        vm.snapshotGasLastCall(NAMESPACE, "deployDeviceWalletForUsers: batch of 1, funded");
    }

    /// @notice Rotating the vault the factory hands to new wallets
    function test_updateVaultAddress() public {
        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.updateVaultAddress(user5);
        vm.snapshotGasLastCall(NAMESPACE, "updateVaultAddress");
    }
}
