// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Registry} from "contracts/Registry.sol";
import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";
import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Gas for every call the admin contract takes, and for what an upgrade costs through it.
/// @dev The figure worth reading is the pair: what the same change costs announced and waited out
///      against what it costs taken instantly. Both routes end in the same call to the same target,
///      so the difference is what the delay itself costs, and it is the number to quote when
///      someone asks whether the guardian path is worth having.
///
///      Every input is fixed. Nothing here signs anything offchain, so these rows are stable
///      between runs without any pinning beyond the salts.
contract ProtocolAdminOperationsGasTest is AdminBase {

    string internal NAMESPACE = "ProtocolAdmin.Operations";

    /// @notice Announcing a change, one call and four
    function test_schedule() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        vm.prank(proposer);
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(uint256(1)), DELAY);
        vm.snapshotGasLastCall(NAMESPACE, "schedule: one call");

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _fourCapCalls();

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(uint256(2)), DELAY);
        vm.snapshotGasLastCall(NAMESPACE, "scheduleBatch: four calls");
    }

    /// @notice Running an announced change once its delay has passed
    /// @dev Held apart from the batch below because both land on the same registry slot. Measured
    ///      in one body, whichever ran first would pay the cold write and make the other look free.
    function test_execute_oneCall() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        _schedule(address(registry), data, bytes32(uint256(1)));

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(uint256(1)));
        vm.snapshotGasLastCall(NAMESPACE, "execute: one call, delay served");
    }

    /// @notice The same, as a batch of four
    function test_execute_fourCalls() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _fourCapCalls();

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(uint256(2)), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(uint256(2)));
        vm.snapshotGasLastCall(NAMESPACE, "executeBatch: four calls, delay served");
    }

    /// @notice Stripping the cancel power, one account and a whole signer set
    /// @dev The batch row is the one that matters. A guardian doing this during an incident is
    ///      racing whatever the compromised account scheduled, and every account it has to name in
    ///      a separate transaction is another chance to lose that race.
    function test_revokeCancellersInstantly() public {
        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));
        vm.snapshotGasLastCall(NAMESPACE, "revokeCancellersInstantly: one account");

        address[] memory rest = new address[](3);
        rest[0] = secondCanceller;
        rest[1] = thirdCanceller;
        rest[2] = proposer;

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(rest);
        vm.snapshotGasLastCall(NAMESPACE, "revokeCancellersInstantly: three accounts");
    }

    /// @notice Calling off something already announced
    function test_cancel() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        vm.prank(proposer);
        protocolAdmin.cancel(id);
        vm.snapshotGasLastCall(NAMESPACE, "cancel");
    }

    /// @notice Taking ownership of all four contracts, which happens once per deployment
    function test_acceptOwnershipBatch() public {
        ProtocolAdmin next = _deployReplacement(DELAY);
        address[] memory targets = _ownedContracts();

        _offerAllFourTo(address(next));

        next.acceptOwnershipBatch(targets);
        vm.snapshotGasLastCall(NAMESPACE, "acceptOwnershipBatch: four contracts");
    }

    /// @notice What the real thing costs: four proxies moved in one operation
    /// @dev The number the deployment is sized against. A batch this size has to fit inside a block
    ///      on both chains, and it is the one call where that is not obviously true.
    function test_upgradeAllFourSingletons() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _fourUpgrades();

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);
        vm.snapshotGasLastCall(NAMESPACE, "scheduleBatch: four proxy upgrades");

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        vm.snapshotGasLastCall(NAMESPACE, "executeBatch: four proxy upgrades");
    }

    /// @notice Both wallet beacons in one operation
    function test_upgradeBothBeacons() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);

        targets[0] = address(deviceWalletFactory);
        payloads[0] = abi.encodeCall(
            deviceWalletFactory.updateDeviceWalletImplementation,
            (address(new MockDeviceWallet(typeCastEntryPoint, p256Verifier)))
        );
        targets[1] = address(eSIMWalletFactory);
        payloads[1] = abi.encodeCall(
            eSIMWalletFactory.updateESIMWalletImplementation,
            (address(new MockESIMWallet()))
        );

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        vm.snapshotGasLastCall(NAMESPACE, "executeBatch: both wallet beacons");
    }

    /// @notice Releasing a protocol wide pause, the call the guardian role exists for
    /// @dev Read this against `execute: one call, delay served` plus `schedule: one call`. The
    ///      difference is not the gas, it is the two days, and this row is here so the cost of the
    ///      one call that cannot wait is on the record.
    function test_unpause() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(registry));
        vm.snapshotGasLastCall(NAMESPACE, "unpauseInstantly: release a protocol wide pause");
    }

    /// @dev Four calls at the same target, so the batch rows measure the batch machinery rather
    ///      than four different pieces of protocol logic.
    function _fourCapCalls()
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](4);
        values = new uint256[](4);
        payloads = new bytes[](4);

        for(uint256 i = 0; i < 4; ++i) {
            targets[i] = address(registry);
            payloads[i] = abi.encodeCall(registry.setDefaultDataBundlePriceCap, ((i + 1) * 1 ether));
        }
    }

    function _fourUpgrades()
        private
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = _ownedContracts();
        values = new uint256[](4);
        payloads = new bytes[](4);

        address[4] memory nexts = [
            address(new Registry()),
            address(new LazyWalletRegistry()),
            address(new DeviceWalletFactory()),
            address(new ESIMWalletFactory())
        ];

        for(uint256 i = 0; i < 4; ++i) {
            payloads[i] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (nexts[i], ""));
        }
    }

    function _offerAllFourTo(address _destination) private {
        address[] memory targets = _ownedContracts();
        uint256[] memory values = new uint256[](4);
        bytes[] memory payloads = new bytes[](4);

        for(uint256 i = 0; i < targets.length; ++i) {
            payloads[i] = abi.encodeCall(Ownable2StepUpgradeable.transferOwnership, (_destination));
        }

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(uint256(7)), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(uint256(7)));
    }
}
