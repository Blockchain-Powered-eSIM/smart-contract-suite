// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Gas for what a device wallet does once it exists.
/// @dev `execute` and `executeBatch` are measured from the entry point rather than through
///      `handleOps`, so these are the wallet's own cost with none of the bundler accounting on top.
///      A bundler pays this plus validation, and validation is in the signature file.
contract DeviceWalletOperationsGasTest is GasBase {

    string internal NAMESPACE = "DeviceWallet.Operations";

    MockDeviceWallet internal wallet;
    MockESIMWallet internal firstESIMWallet;

    /// @dev DeployerBase does not declare setUp virtual, so the wallet is deployed per test.
    function _deploy() internal {
        (wallet, firstESIMWallet) = _deployDeviceWallet(customDeviceUniqueIdentifiers[0], 0, 8500);
    }

    /// @notice Adding another eSIM wallet to a device that already has one
    /// @dev The first eSIM wallet comes with the device deployment, so this is the marginal cost of
    ///      the second and every one after it. The grant is measured in `test_toggleAccessToFunds`.
    function test_deployESIMWallet() public {
        _deploy();

        vm.prank(eSIMWalletAdmin);
        wallet.deployESIMWallet(false, 8501);
        vm.snapshotGasLastCall(NAMESPACE, "deployESIMWallet: second wallet on the device");
    }

    /// @notice A single call out of the wallet, and a batch of three
    function test_executeAndExecuteBatch() public {
        _deploy();
        vm.deal(address(wallet), 10 ether);

        Call memory single = Call({dest: user4, value: 1 ether, data: ""});

        vm.prank(address(entryPoint));
        wallet.execute(single);
        vm.snapshotGasLastCall(NAMESPACE, "execute: ETH transfer to an EOA");

        Call[] memory batch = new Call[](3);
        batch[0] = Call({dest: user4, value: 1 ether, data: ""});
        batch[1] = Call({dest: user5, value: 1 ether, data: ""});
        batch[2] = Call({dest: user3, value: 1 ether, data: ""});

        vm.prank(address(entryPoint));
        wallet.executeBatch(batch);
        vm.snapshotGasLastCall(NAMESPACE, "executeBatch: 3 ETH transfers");
    }

    /// @notice Granting and revoking an eSIM wallet's access to the device's ETH
    /// @dev Gated on the wallet calling itself, which in production means it arrives as the target
    ///      of an `execute` rather than as a transaction of its own.
    function test_toggleAccessToFunds() public {
        _deploy();

        vm.prank(address(wallet));
        wallet.toggleAccessToFunds(address(firstESIMWallet), true);
        vm.snapshotGasLastCall(NAMESPACE, "toggleAccessToFunds: grant");

        vm.prank(address(wallet));
        wallet.toggleAccessToFunds(address(firstESIMWallet), false);
        vm.snapshotGasLastCall(NAMESPACE, "toggleAccessToFunds: revoke");
    }

    /// @notice An eSIM wallet pulling an ERC-20 from the device wallet that owns it
    /// @dev Two cases because the eSIM wallet's balance slot is cold on its first purchase and warm
    ///      after, and the difference is what a wallet buying more than once actually pays.
    function test_pullToken() public {
        _deploy();
        fundSettlementToken(address(wallet), 1_000e6);

        vm.prank(address(wallet));
        wallet.toggleAccessToFunds(address(firstESIMWallet), true);

        vm.prank(address(firstESIMWallet));
        wallet.pullToken(settlementToken, 100e6);
        vm.snapshotGasLastCall(NAMESPACE, "pullToken: first pull, the wallet holds none of it");

        vm.prank(address(firstESIMWallet));
        wallet.pullToken(settlementToken, 100e6);
        vm.snapshotGasLastCall(NAMESPACE, "pullToken: the wallet already holds some");
    }

    /// @notice Funding the wallet's entry point deposit
    function test_addDeposit() public {
        _deploy();
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        wallet.addDeposit{value: 1 ether}();
        vm.snapshotGasLastCall(NAMESPACE, "addDeposit: 1 ether");
    }
}
