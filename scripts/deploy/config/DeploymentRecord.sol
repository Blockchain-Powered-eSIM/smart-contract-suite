// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Vm} from "forge-std/Vm.sol";

// Config
import {DeployConfig} from "./DeployConfig.sol";

/// @notice Reads and writes the deployment record every later script starts from
/// @dev The deploy, the configuration step, the ownership handover and both upgrade scripts all run
///      separately and none of them takes an address as an argument. Passing addresses on the
///      command line is how the wrong proxy gets upgraded, so each script looks its targets up here
///      instead and fails loudly when an entry is missing.
///
///      Two files, because they are read by different people. The address book is a flat name to
///      address map keyed by chain, which is what a reader wants and what the SDK and the README
///      quote. The record is the full detail for one deployment: build provenance, constructor
///      arguments, role holders, codehashes, status. Keeping the detail out of the address book is
///      what stops the address book growing past the point where anyone reads it.
///
///      The record file is named after the record key, `base-sepolia-84532-entrypoint-v8.json`, so
///      the filename cannot disagree with the chain and EntryPoint version it describes, and the
///      record itself is written at the file's root rather than nested under that key again.
///
///      Both paths can be overridden through an environment variable, `DEPLOYMENT_RECORD_PATH` and
///      `ADDRESS_BOOK_PATH`. A test or a fork rehearsal points both at a scratch file so nothing it
///      does can reach the files that track a live deployment. Nothing here is hand edited outside
///      of that override: a hand edited address is indistinguishable from a deployed one to every
///      reader of this file.
library DeploymentRecord {

    /// @notice Flat name to address map, one entry per deployment, unless overridden
    string internal constant DEFAULT_ADDRESS_BOOK = "deployments/address.json";

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The deployment record has no entry for this contract on this chain
    error NotRecorded(string network, string key);

    /// @notice A recorded address carries no code on chain
    error NoCodeAt(string key, address target);

    /// @notice No deployment record exists for this chain
    /// @dev Separate from `NotRecorded` because the fix is different. A missing entry means the
    ///      deploy wrote a record and left something out; a missing file means this chain was never
    ///      deployed by these scripts, or was deployed before the record was split in two.
    error NoRecordFile(string network, string path);

    /// @notice Path to the full record for the chain the script is connected to
    /// @dev A function rather than a constant so a test or a rehearsal can point a script at a
    ///      scratch file. The real record is the only thing that remembers a live deployment's
    ///      addresses, so a run writing over it loses them. `fs_permissions` keeps any value inside
    ///      `deployments/`.
    /// @return path Record file path, for example `deployments/base-sepolia-84532-entrypoint-v8.json`
    function recordPath() internal view returns (string memory path) {
        path = vm.envOr("DEPLOYMENT_RECORD_PATH", _defaultRecordPath());
    }

    /// @notice Path to the flat address book, unless overridden
    /// @dev Same override reasoning as `recordPath`. The real address book is committed and shared
    ///      across every chain, so a test writing an entry into it would corrupt the tracked file
    ///      for everyone rather than for one test run.
    /// @return path Address book path
    function addressBookPath() internal view returns (string memory path) {
        path = vm.envOr("ADDRESS_BOOK_PATH", DEFAULT_ADDRESS_BOOK);
    }

    function _defaultRecordPath() private view returns (string memory path) {
        path = string.concat("deployments/", DeployConfig.recordKey(), ".json");
    }

    /// @notice Reads a deployed address out of the record and checks it carries code
    /// @dev The code check is the point. A missing key and a key holding an address from another
    ///      chain both read as a plain address, and only one of them fails at parse time.
    /// @param key Contract name as recorded, for example `RegistryProxy`
    /// @return target Address recorded for this contract on the current chain
    function readAddress(string memory key) internal view returns (address target) {
        string memory json = _record();
        string memory pointer = string.concat(".contracts.", key, ".address");

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(DeployConfig.recordKey(), key);

        target = vm.parseJsonAddress(json, pointer);
        if(target.code.length == 0) revert NoCodeAt(key, target);
    }

    /// @notice Reads a recorded address without requiring it to carry code
    /// @dev For entries that name an account rather than a contract, and for reading a value back
    ///      on a chain the script is not connected to.
    /// @param path Dotted path into the record, for example `admin.protocolAdmin`
    /// @return value Address at that path
    function readRaw(string memory path) internal view returns (address value) {
        string memory json = _record();
        string memory pointer = string.concat(".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(DeployConfig.recordKey(), path);

        value = vm.parseJsonAddress(json, pointer);
    }

    /// @notice Reads a recorded number
    /// @param path Dotted path into the record
    /// @return value Number at that path
    function readUint(string memory path) internal view returns (uint256 value) {
        string memory json = _record();
        string memory pointer = string.concat(".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(DeployConfig.recordKey(), path);

        value = vm.parseJsonUint(json, pointer);
    }

    /// @notice Reads recorded bytes, used for a scheduled operation's payload
    /// @param path Dotted path into the record
    /// @return value Bytes at that path
    function readBytes(string memory path) internal view returns (bytes memory value) {
        string memory json = _record();
        string memory pointer = string.concat(".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(DeployConfig.recordKey(), path);

        value = vm.parseJsonBytes(json, pointer);
    }

    /// @notice Reads a recorded 32 byte value, used for salts and operation ids
    /// @param path Dotted path into the record
    /// @return value Word at that path
    function readBytes32(string memory path) internal view returns (bytes32 value) {
        string memory json = _record();
        string memory pointer = string.concat(".", path);

        if(!vm.keyExistsJson(json, pointer)) revert NotRecorded(DeployConfig.recordKey(), path);

        value = vm.parseJsonBytes32(json, pointer);
    }

    /// @notice Creates this chain's record file
    /// @dev Whole file at once, so a rerun leaves no field behind from the run before it.
    /// @param json Serialized record
    function writeRecord(string memory json) internal {
        vm.writeJson(json, recordPath());
    }

    /// @notice Adds this chain's entry to the flat address book
    /// @param json Serialized name to address map
    function writeAddressBook(string memory json) internal {
        vm.writeJson(json, addressBookPath(), string.concat(".", DeployConfig.recordKey()));
    }

    /// @notice Records a step as complete
    /// @dev Written by the configuration and handover scripts so a partially finished deployment
    ///      says so in the file rather than in somebody's terminal history.
    /// @param key Name of the step, for example `configured`
    /// @param done Whether the step finished
    function writeStatus(string memory key, bool done) internal {
        // `writeJson` takes the value as JSON text, so a bool is the literal word rather than a
        // serialized object. Serializing here would write `{"configured":true}` where the bool goes.
        vm.writeJson(done ? "true" : "false", recordPath(), string.concat(".status.", key));
    }

    /// @notice Writes a pre-serialized JSON object into the record
    /// @dev Used for the pending upgrade entries, where a schedule and its later execution have to
    ///      agree on an implementation address, a salt and a delay down to the byte. Recomputing
    ///      those at execution time is how an operation id stops matching the one that was
    ///      scheduled, and the timelock rejects it with nothing to show why.
    /// @param path Dotted path into the record
    /// @param json Serialized object to write there
    function writeObject(string memory path, string memory json) internal {
        vm.writeJson(json, recordPath(), string.concat(".", path));
    }

    /// @notice True when the record already holds an entry at this path for the current chain
    /// @dev A chain with no record file has no entry at any path, so this answers false rather than
    ///      reverting. Callers use it to ask whether something has happened yet.
    /// @param path Dotted path into the record
    /// @return present Whether the path resolves
    function has(string memory path) internal view returns (bool present) {
        if(!vm.isFile(recordPath())) return false;
        present = vm.keyExistsJson(vm.readFile(recordPath()), string.concat(".", path));
    }

    /// @notice True when this chain already carries a deployment, in either file
    /// @dev Both files are checked because either one alone is enough to make a redeploy destructive.
    ///      A record file with no address book entry is a half-written deploy; an address book entry
    ///      with no record file is a live deployment whose detail was lost, and overwriting it would
    ///      leave the live proxies reachable by nothing.
    /// @return deployed Whether anything is recorded for this chain
    function isRecorded() internal view returns (bool deployed) {
        if(vm.isFile(recordPath())) return true;

        string memory book = addressBookPath();
        if(!vm.isFile(book)) return false;

        deployed = vm.keyExistsJson(vm.readFile(book), string.concat(".", DeployConfig.recordKey()));
    }

    /// @notice Reads the record file, failing with the path when there is none
    function _record() private view returns (string memory json) {
        string memory path = recordPath();
        if(!vm.isFile(path)) revert NoRecordFile(DeployConfig.recordKey(), path);
        json = vm.readFile(path);
    }
}
