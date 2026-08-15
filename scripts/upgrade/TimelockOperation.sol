// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ProtocolAdmin} from "../../contracts/admin/ProtocolAdmin.sol";

// Config
import {DeploymentRecord} from "../deploy/config/DeploymentRecord.sol";

/// @notice Shared schedule and execute halves of an upgrade that has to wait for the timelock
/// @dev Once `TransferOwnership.s.sol` has run, every upgrade in this protocol is two transactions
///      separated by the delay, and the two have to describe the same operation to the byte. The
///      timelock identifies an operation by hashing target, value, payload, predecessor and salt
///      together, so a payload rebuilt at execution time from a freshly deployed implementation is
///      a different operation, and the only thing the contract can say about it is that it was
///      never scheduled.
///
///      So the schedule half writes the whole operation into the deployment record and the execute
///      half reads it back rather than recomputing anything. That also means the two halves can run
///      from different machines days apart, which is the normal case.
abstract contract TimelockOperation is Script {

    /// @notice No predecessor. Operations here are independent rather than ordered.
    bytes32 private constant NO_PREDECESSOR = bytes32(0);

    /// @notice The record holds no scheduled operation under this name
    error NothingScheduled(string name);

    /// @notice The operation is scheduled but its delay has not elapsed
    error NotReady(bytes32 operationId, uint256 readyAt, uint256 nowTimestamp);

    /// @notice The operation the record describes is not the one the timelock is holding
    error OperationMismatch(bytes32 recorded, bytes32 recomputed);

    /// @notice Schedules a call the timelock will make on the protocol's behalf
    /// @dev Broadcast from a key holding `PROPOSER_ROLE`. The salt is derived from the name and the
    ///      payload rather than drawn at random, so scheduling the same upgrade twice collides
    ///      loudly instead of leaving two operations that both look correct.
    /// @param name Short name this operation is recorded under, for example `RegistryProxy`
    /// @param target Contract the timelock will call
    /// @param data Encoded call the timelock will make
    /// @param newImplementation Implementation this upgrade installs, recorded for the audit trail
    function _schedule(
        string memory name,
        address target,
        bytes memory data,
        address newImplementation
    ) internal {
        ProtocolAdmin admin = _admin();
        bytes32 salt = keccak256(abi.encode(name, data));
        uint256 delay = admin.getMinDelay();

        bytes32 operationId = admin.hashOperation(target, 0, data, NO_PREDECESSOR, salt);

        vm.startBroadcast(vm.envUint("PROPOSER_PRIVATE_KEY"));
        admin.schedule(target, 0, data, NO_PREDECESSOR, salt, delay);
        vm.stopBroadcast();

        _record(name, target, data, salt, delay, operationId, newImplementation);

        console.log("Scheduled  ", name);
        console.log("Operation  ", vm.toString(operationId));
        console.log("Executable at unix time", block.timestamp + delay);
        console.log("");
        console.log("Run the same script with UPGRADE_ACTION=execute once the delay has elapsed.");
    }

    /// @notice Executes an operation whose delay has elapsed
    /// @dev Execution is open to everyone, so this needs no privileged key. The reads below are
    ///      checks rather than logging: an operation id recomputed from the record has to match the
    ///      one that was stored, or the record and the chain disagree about what is pending.
    /// @param name Name the operation was scheduled under
    function _execute(string memory name) internal {
        string memory path = string.concat("pending.", name);
        if(!DeploymentRecord.has(string.concat(path, ".operationId"))) {
            revert NothingScheduled(name);
        }

        ProtocolAdmin admin = _admin();
        address target = DeploymentRecord.readRaw(string.concat(path, ".target"));
        bytes memory data = DeploymentRecord.readBytes(string.concat(path, ".payload"));
        bytes32 salt = DeploymentRecord.readBytes32(string.concat(path, ".salt"));
        bytes32 recorded = DeploymentRecord.readBytes32(string.concat(path, ".operationId"));

        bytes32 recomputed = admin.hashOperation(target, 0, data, NO_PREDECESSOR, salt);
        if(recomputed != recorded) revert OperationMismatch(recorded, recomputed);

        // `isOperationReady` is the right question. A stored timestamp of 1 means done, and a naive
        // `getTimestamp(id) > block.timestamp` admits that value rather than excluding it.
        if(!admin.isOperationReady(recorded)) {
            revert NotReady(recorded, admin.getTimestamp(recorded), block.timestamp);
        }

        vm.startBroadcast(vm.envUint("EXECUTOR_PRIVATE_KEY"));
        admin.execute(target, 0, data, NO_PREDECESSOR, salt);
        vm.stopBroadcast();

        DeploymentRecord.writeObject(string.concat(path, ".executed"), "true");

        console.log("Executed   ", name);
        console.log("Operation  ", vm.toString(recorded));
    }

    /// @notice The timelock that owns every upgradeable contract in the deployment
    function _admin() internal view returns (ProtocolAdmin admin) {
        admin = ProtocolAdmin(payable(DeploymentRecord.readRaw("admin.protocolAdmin")));
    }

    /// @notice Writes the whole operation so the execute half has nothing left to derive
    function _record(
        string memory name,
        address target,
        bytes memory data,
        bytes32 salt,
        uint256 delay,
        bytes32 operationId,
        address newImplementation
    ) private {
        string memory key = string.concat("pending", name);

        vm.serializeAddress(key, "target", target);
        vm.serializeAddress(key, "implementation", newImplementation);
        vm.serializeBytes(key, "payload", data);
        vm.serializeBytes32(key, "salt", salt);
        vm.serializeBytes32(key, "operationId", operationId);
        vm.serializeUint(key, "delay", delay);
        vm.serializeUint(key, "scheduledAt", block.timestamp);
        vm.serializeUint(key, "executableAt", block.timestamp + delay);
        string memory entry = vm.serializeBool(key, "executed", false);

        DeploymentRecord.writeObject(string.concat("pending.", name), entry);
    }
}
