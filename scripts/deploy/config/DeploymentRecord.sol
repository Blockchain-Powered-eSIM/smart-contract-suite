// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Vm} from "forge-std/Vm.sol";

// Config
import {DeployConfig} from "./DeployConfig.sol";

/// @notice Reads and writes `deployments/address.json`, the record every later script starts from
/// @dev The deploy, the configuration step, the ownership handover and both upgrade scripts all run
///      separately and none of them takes an address as an argument. Passing addresses on the
///      command line is how the wrong proxy gets upgraded, so each script looks its targets up here
///      instead and fails loudly when an entry is missing.
///
///      Records are keyed by chain name and chain id together, `base-sepolia-84532`, so writing one
///      chain never touches another and the key cannot disagree with the chain it came from.
///      Everything under a key is written by the scripts and nothing is hand edited: a hand edited
///      address is indistinguishable from a deployed one to every reader of this file.
library DeploymentRecord {

    /// @notice The record a run reads and writes unless it is pointed somewhere else
    string internal constant DEFAULT_PATH = "deployments/address.json";

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice File this run reads and writes
    /// @dev A function rather than a constant so a test can point a script at a scratch file. The
    ///      real record is the only thing that remembers a live deployment's addresses, so a test
    ///      writing over it loses them. `fs_permissions` keeps any value inside `deployments/`.
    /// @return location Path to the record for this run
    function recordPath() internal view returns (string memory location) {
        location = vm.envOr("DEPLOYMENT_RECORD_PATH", DEFAULT_PATH);
    }

    /// @notice The deployment record has no entry for this contract on this chain
    error NotRecorded(string network, string key);

    /// @notice A recorded address carries no code on chain
    error NoCodeAt(string key, address target);

    /// @notice Reads a deployed address out of the record and checks it carries code
    /// @dev The code check is the point. A missing key and a key holding an address from another
    ///      chain both read as a plain address, and only one of them fails at parse time.
    /// @param key Contract name as recorded, for example `RegistryProxy`
    /// @return target Address recorded for this contract on the current chain
    function readAddress(string memory key) internal view returns (address target) {
        string memory network = DeployConfig.recordKey();
        string memory json = vm.readFile(recordPath());
        string memory pointer = string.concat(".", network, ".contracts.", key, ".address");

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(network, key);

        target = vm.parseJsonAddress(json, pointer);
        if(target.code.length == 0) revert NoCodeAt(key, target);
    }

    /// @notice Reads a recorded address without requiring it to carry code
    /// @dev For entries that name an account rather than a contract, and for reading a value back
    ///      on a chain the script is not connected to.
    /// @param path Dotted path below the network key, for example `admin.protocolAdmin`
    /// @return value Address at that path
    function readRaw(string memory path) internal view returns (address value) {
        string memory network = DeployConfig.recordKey();
        string memory json = vm.readFile(recordPath());
        string memory pointer = string.concat(".", network, ".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(network, path);

        value = vm.parseJsonAddress(json, pointer);
    }

    /// @notice Reads a recorded number
    /// @param path Dotted path below the network key
    /// @return value Number at that path
    function readUint(string memory path) internal view returns (uint256 value) {
        string memory network = DeployConfig.recordKey();
        string memory json = vm.readFile(recordPath());
        string memory pointer = string.concat(".", network, ".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(network, path);

        value = vm.parseJsonUint(json, pointer);
    }

    /// @notice Reads recorded bytes, used for a scheduled operation's payload
    /// @param path Dotted path below the network key
    /// @return value Bytes at that path
    function readBytes(string memory path) internal view returns (bytes memory value) {
        string memory network = DeployConfig.recordKey();
        string memory json = vm.readFile(recordPath());
        string memory pointer = string.concat(".", network, ".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(network, path);

        value = vm.parseJsonBytes(json, pointer);
    }

    /// @notice Reads a recorded 32 byte value, used for salts and operation ids
    /// @param path Dotted path below the network key
    /// @return value Word at that path
    function readBytes32(string memory path) internal view returns (bytes32 value) {
        string memory network = DeployConfig.recordKey();
        string memory json = vm.readFile(recordPath());
        string memory pointer = string.concat(".", network, ".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(network, path);

        value = vm.parseJsonBytes32(json, pointer);
    }

    /// @notice Records a step as complete under the current network
    /// @dev Written by the configuration and handover scripts so a partially finished deployment
    ///      says so in the file rather than in somebody's terminal history.
    /// @param key Name of the step, for example `configured`
    /// @param done Whether the step finished
    function writeStatus(string memory key, bool done) internal {
        // `writeJson` takes the value as JSON text, so a bool is the literal word rather than a
        // serialized object. Serializing here would write `{"configured":true}` where the bool goes.
        vm.writeJson(
            done ? "true" : "false",
            recordPath(),
            string.concat(".", DeployConfig.recordKey(), ".status.", key)
        );
    }

    /// @notice Writes a pre-serialized JSON object under the current network
    /// @dev Used for the pending upgrade entries, where a schedule and its later execution have to
    ///      agree on an implementation address, a salt and a delay down to the byte. Recomputing
    ///      those at execution time is how an operation id stops matching the one that was
    ///      scheduled, and the timelock rejects it with nothing to show why.
    /// @param path Dotted path below the network key
    /// @param json Serialized object to write there
    function writeObject(string memory path, string memory json) internal {
        vm.writeJson(json, recordPath(), string.concat(".", DeployConfig.recordKey(), ".", path));
    }

    /// @notice True when the record already holds an entry at this path for the current chain
    /// @param path Dotted path below the network key
    /// @return present Whether the path resolves
    function has(string memory path) internal view returns (bool present) {
        string memory json = vm.readFile(recordPath());
        present = vm.keyExistsJson(
            json,
            string.concat(".", DeployConfig.recordKey(), ".", path)
        );
    }
}
