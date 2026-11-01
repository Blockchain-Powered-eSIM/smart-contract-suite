// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {console} from "forge-std/console.sol";
import {Registry} from "../../contracts/Registry.sol";
import {ProtocolAdmin} from "../../contracts/admin/ProtocolAdmin.sol";

// Config
import {DeploymentRecord} from "../deploy/config/DeploymentRecord.sol";
import {TimelockOperation} from "../upgrade/TimelockOperation.sol";

/// @notice Changes the admin allowance new eSIM wallets start with, through the timelock
/// @dev The proposer is a Safe, so this never schedules anything itself. `ACTION=prepare` builds
///      the call from typed values, rehearses schedule, delay and execute on the connected chain's
///      state, then writes a Transaction Builder file for the Safe and the operation into the
///      record. `ACTION=execute` runs it once the delay has passed; any key may do that.
contract SetDefaultAdminAllowance is TimelockOperation {

    /// @notice Name the operation is recorded under in `pending`
    string private constant NAME = "RegistryDefaultAdminAllowance";

    /// @notice No predecessor, matching `TimelockOperation`
    bytes32 private constant NO_PREDECESSOR = bytes32(0);

    /// @notice The record names a proposer that does not hold `PROPOSER_ROLE` on chain
    error NotAProposer(address account);

    /// @notice The rehearsal ended with a different allowance than the one prepared
    error RehearsalFailed(uint64 expected, uint64 actual);

    /// @notice `ACTION` is neither `prepare` nor `execute`
    error UnknownAction(string action);

    /// @notice Prepares or executes the change, depending on `ACTION`
    function run() external {
        string memory action = vm.envString("ACTION");

        if(_is(action, "prepare")) {
            // A dedicated variable, so a stale ADMIN_ALLOWANCE_USD_CENTS from deploy time is never picked up
            _prepare(uint64(vm.envUint("NEW_DEFAULT_ADMIN_ALLOWANCE_USD_CENTS")));
            return;
        }
        if(_is(action, "execute")) {
            _execute(NAME);
            return;
        }

        revert UnknownAction(action);
    }

    /// @notice Builds, checks and records the operation, and writes the Safe file
    /// @param allowance Allowance new eSIM wallets should start with, in USD cents
    function _prepare(uint64 allowance) private {
        Registry registry = Registry(DeploymentRecord.readAddress("RegistryProxy"));
        ProtocolAdmin admin = _admin();
        address safe = _proposerSafe(admin);

        bytes memory data = abi.encodeCall(Registry.setDefaultAdminAllowanceUSDCents, (allowance));
        bytes32 salt = keccak256(abi.encode(NAME, data));
        uint256 delay = admin.getMinDelay();
        bytes32 operationId = admin.hashOperation(address(registry), 0, data, NO_PREDECESSOR, salt);
        bytes memory scheduleData = abi.encodeCall(
            admin.schedule,
            (address(registry), 0, data, NO_PREDECESSOR, salt, delay)
        );

        console.log("Registry       ", address(registry));
        console.log("ProtocolAdmin  ", address(admin));
        console.log("Proposer Safe  ", safe);
        console.log("Allowance now  ", registry.defaultAdminAllowanceUSDCents());
        console.log("Allowance next ", allowance);
        console.log("Delay (s)      ", delay);
        console.log("Operation id   ", vm.toString(operationId));
        console.log("Safe tx data   ", vm.toString(scheduleData));

        if(admin.isOperation(operationId)) {
            console.log("Already scheduled on chain, ready:", admin.isOperationReady(operationId));
        } else {
            _rehearse(admin, registry, safe, data, salt, delay, allowance);
        }

        _writeSafeBatch(safe, address(admin), address(registry), allowance, data, salt, delay);
        _writePending(address(registry), data, salt, delay, operationId, safe);
    }

    /// @notice Schedules as the Safe, waits out the delay and executes, then rolls all of it back
    function _rehearse(
        ProtocolAdmin admin,
        Registry registry,
        address safe,
        bytes memory data,
        bytes32 salt,
        uint256 delay,
        uint64 allowance
    ) private {
        uint256 snapshot = vm.snapshotState();

        vm.prank(safe);
        admin.schedule(address(registry), 0, data, NO_PREDECESSOR, salt, delay);

        vm.warp(block.timestamp + delay);
        vm.prank(makeAddr("anyone"));
        admin.execute(address(registry), 0, data, NO_PREDECESSOR, salt);

        uint64 actual = registry.defaultAdminAllowanceUSDCents();
        vm.revertToState(snapshot);

        if(actual != allowance) revert RehearsalFailed(allowance, actual);
        console.log("Rehearsal      schedule, delay and execute all passed");
    }

    /// @notice The proposer Safe named in the record, checked against the role on chain
    function _proposerSafe(ProtocolAdmin admin) private view returns (address safe) {
        string memory record = vm.readFile(DeploymentRecord.recordPath());
        safe = vm.parseJsonAddressArray(record, ".admin.proposers")[0];

        if(!admin.hasRole(admin.PROPOSER_ROLE(), safe)) revert NotAProposer(safe);
    }

    /// @notice Writes a Safe Transaction Builder file for the `schedule` call
    /// @dev Carries the method and named inputs, so the Safe UI shows each field instead of one
    ///      hex blob. No checksum: Transaction Builder warns on import and loads it anyway.
    function _writeSafeBatch(
        address safe,
        address admin,
        address registry,
        uint64 allowance,
        bytes memory data,
        bytes32 salt,
        uint256 delay
    ) private {
        string memory inputs = string.concat(
            '[{"internalType":"address","name":"target","type":"address"},',
            '{"internalType":"uint256","name":"value","type":"uint256"},',
            '{"internalType":"bytes","name":"data","type":"bytes"},',
            '{"internalType":"bytes32","name":"predecessor","type":"bytes32"},',
            '{"internalType":"bytes32","name":"salt","type":"bytes32"},',
            '{"internalType":"uint256","name":"delay","type":"uint256"}]'
        );
        string memory values = string.concat(
            '{"target":"', vm.toString(registry),
            '","value":"0","data":"', vm.toString(data),
            '","predecessor":"', vm.toString(NO_PREDECESSOR),
            '","salt":"', vm.toString(salt),
            '","delay":"', vm.toString(delay), '"}'
        );
        string memory transaction = string.concat(
            '{"to":"', vm.toString(admin),
            '","value":"0","data":null,"contractMethod":{"inputs":', inputs,
            ',"name":"schedule","payable":false},"contractInputsValues":', values, '}'
        );
        string memory meta = string.concat(
            '{"name":"Set default admin allowance to ', vm.toString(allowance),
            ' USD cents","description":"ProtocolAdmin.schedule(Registry.setDefaultAdminAllowanceUSDCents(',
            vm.toString(allowance), '))","createdFromSafeAddress":"', vm.toString(safe), '"}'
        );
        string memory batch = string.concat(
            '{"version":"1.0","chainId":"', vm.toString(block.chainid),
            '","createdAt":', vm.toString(vm.unixTime()),
            ',"meta":', meta, ',"transactions":[', transaction, ']}'
        );

        string memory path = string.concat(
            "deployments/safe/", vm.toString(block.chainid), "-set-default-admin-allowance-",
            vm.toString(allowance), ".json"
        );
        vm.createDir("deployments/safe", true);
        vm.writeJson(batch, path);
        console.log("Safe batch     ", path);
    }

    /// @notice Records the operation in the same shape `TimelockOperation._execute` reads back
    /// @dev Written only with `--broadcast`, like every other record entry. Nothing is sent.
    function _writePending(
        address target,
        bytes memory data,
        bytes32 salt,
        uint256 delay,
        bytes32 operationId,
        address safe
    ) private {
        string memory key = string.concat("pending", NAME);

        vm.serializeAddress(key, "target", target);
        vm.serializeAddress(key, "proposerSafe", safe);
        vm.serializeBytes(key, "payload", data);
        vm.serializeBytes32(key, "salt", salt);
        vm.serializeBytes32(key, "operationId", operationId);
        vm.serializeUint(key, "delay", delay);
        vm.serializeUint(key, "preparedAt", block.timestamp);
        string memory entry = vm.serializeBool(key, "executed", false);

        DeploymentRecord.writeObject(string.concat("pending.", NAME), entry);
    }

    function _is(string memory left, string memory right) private pure returns (bool equal) {
        equal = keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
