// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

// Contracts
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ProtocolAdmin} from "../../contracts/admin/ProtocolAdmin.sol";
import {P256Verifier} from "../../contracts/P256Verifier.sol";
import {Registry} from "../../contracts/Registry.sol";
import {LazyWalletRegistry} from "../../contracts/LazyWalletRegistry.sol";
import {DeviceWallet} from "../../contracts/device-wallet/DeviceWallet.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWallet} from "../../contracts/esim-wallet/ESIMWallet.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter} from "../../contracts/payments/PaymentAdapter.sol";

// Config
import {DeployConfig} from "../deploy/config/DeployConfig.sol";
import {DeploymentRecord} from "../deploy/config/DeploymentRecord.sol";

/// @notice Upgrades a live deployment in place and moves it to a newly deployed ProtocolAdmin
/// @dev ProtocolAdmin is not upgradeable, so a change to it means a new one. Two runs, set by
///      `MIGRATE_ACTION`:
///
///      `schedule` deploys the new ProtocolAdmin (same roles as the live one) and every new
///      implementation, then schedules one batch on the live timelock: the five proxy upgrades, the
///      registry's default admin allowance, both beacon upgrades, and the five ownership offers.
///      One batch, so the order holds: the registry is upgraded before the eSIM wallet beacon,
///      whose new wallets read the default allowance from it.
///
///      `execute` runs the batch once the delay has passed, has the new ProtocolAdmin accept all
///      five contracts, checks the result and updates the record. Both runs need
///      `DEPLOYER_PRIVATE_KEY`; `schedule` also needs `PROPOSER_PRIVATE_KEY` and
///      `ADMIN_ALLOWANCE_USD_CENTS`.
///
///      Check the storage layouts before scheduling (`scripts/checks/storage-layouts.py` against
///      `build.storageLayoutHashes`). Nothing onchain can.
contract MigrateProtocolAdmin is Script {

    /// @notice Record path of the pending batch
    string private constant PENDING = "pending.ProtocolAdminMigration";

    /// @notice ERC-1967 implementation slot
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Number of calls in the batch: 5 upgrades, 1 setting, 2 beacons, 5 ownership offers
    uint256 private constant CALLS = 13;

    /// @notice `MIGRATE_ACTION` is neither `schedule` nor `execute`
    error UnknownAction(string action);

    /// @notice A batch is already recorded, so scheduling again would leave two
    error AlreadyScheduled(bytes32 operationId);

    /// @notice The record holds no batch to execute
    error NothingScheduled();

    /// @notice A contract is not owned by the timelock the record names
    error NotOwnedByRecordedAdmin(address target, address owner);

    /// @notice The recorded batch hashes to a different operation than the one stored
    error OperationMismatch(bytes32 recorded, bytes32 recomputed);

    /// @notice The batch is scheduled but the delay has not passed
    error NotReady(bytes32 operationId, uint256 readyAt, uint256 nowTimestamp);

    /// @notice A check after execution failed
    error CheckFailed(string what);

    struct Proxies {
        address registry;
        address lazyWalletRegistry;
        address deviceWalletFactory;
        address eSIMWalletFactory;
        address paymentAdapter;
    }

    struct Deployed {
        address protocolAdmin;
        address registry;
        address lazyWalletRegistry;
        address deviceWalletFactory;
        address eSIMWalletFactory;
        address paymentAdapter;
        address deviceWallet;
        address eSIMWallet;
    }

    /// @notice Schedules or executes the migration, depending on `MIGRATE_ACTION`
    function run() external {
        string memory action = vm.envString("MIGRATE_ACTION");

        if(_is(action, "schedule")) _schedule();
        else if(_is(action, "execute")) _execute();
        else revert UnknownAction(action);
    }

    // ---------------------------------------------------------------------------------------------
    // Schedule
    // ---------------------------------------------------------------------------------------------

    function _schedule() private {
        if(DeploymentRecord.has(string.concat(PENDING, ".operationId"))) {
            revert AlreadyScheduled(DeploymentRecord.readBytes32(string.concat(PENDING, ".operationId")));
        }

        ProtocolAdmin oldAdmin = _recordedAdmin();
        Proxies memory proxies = _proxies();
        _requireOwnedBy(proxies, address(oldAdmin));

        uint64 allowance = uint64(vm.envUint("ADMIN_ALLOWANCE_USD_CENTS"));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        Deployed memory deployed = _deploy();
        vm.stopBroadcast();

        (address[] memory targets, bytes[] memory payloads) = _batch(proxies, deployed, allowance);
        uint256[] memory values = new uint256[](CALLS);
        bytes32 salt = keccak256(abi.encode("ProtocolAdminMigration", targets, payloads));
        uint256 delay = oldAdmin.getMinDelay();
        bytes32 operationId = oldAdmin.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        vm.startBroadcast(vm.envUint("PROPOSER_PRIVATE_KEY"));
        oldAdmin.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.stopBroadcast();

        _recordPending(oldAdmin, deployed, targets, payloads, salt, operationId, delay, allowance);

        console.log("Old ProtocolAdmin  ", address(oldAdmin));
        console.log("New ProtocolAdmin  ", deployed.protocolAdmin);
        console.log("Default allowance  ", allowance);
        console.log("Operation          ", vm.toString(operationId));
        console.log("Executable at unix ", block.timestamp + delay);
        console.log("");
        console.log("Run again with MIGRATE_ACTION=execute once the delay has passed.");
    }

    /// @notice Deploys the new ProtocolAdmin and every implementation the batch installs
    /// @dev Roles are copied from the live record. The device wallet keeps the recorded
    ///      EntryPoint and verifier, so no wallet is moved to a different one.
    function _deploy() private returns (Deployed memory deployed) {
        string memory json = vm.readFile(DeploymentRecord.recordPath());

        deployed.protocolAdmin = address(
            new ProtocolAdmin(
                DeployConfig.TIMELOCK_DELAY,
                DeployConfig.TIMELOCK_DELAY_FLOOR,
                vm.parseJsonAddressArray(json, ".admin.proposers"),
                vm.parseJsonAddressArray(json, ".admin.cancellers"),
                vm.parseJsonAddressArray(json, ".admin.guardians")
            )
        );

        deployed.registry = address(new Registry());
        deployed.lazyWalletRegistry = address(new LazyWalletRegistry());
        deployed.deviceWalletFactory = address(new DeviceWalletFactory());
        deployed.eSIMWalletFactory = address(new ESIMWalletFactory());
        deployed.paymentAdapter = address(new PaymentAdapter());
        deployed.deviceWallet = address(
            new DeviceWallet(
                IEntryPoint(DeploymentRecord.readRaw("external.entryPoint")),
                P256Verifier(DeploymentRecord.readAddress("P256Verifier"))
            )
        );
        deployed.eSIMWallet = address(new ESIMWallet());
    }

    /// @notice The calls the live timelock makes, in the order it makes them
    function _batch(Proxies memory proxies, Deployed memory deployed, uint64 allowance)
        private
        pure
        returns (address[] memory targets, bytes[] memory payloads)
    {
        targets = new address[](CALLS);
        payloads = new bytes[](CALLS);

        (targets[0], payloads[0]) = (proxies.registry, _upgrade(deployed.registry));
        (targets[1], payloads[1]) = (proxies.lazyWalletRegistry, _upgrade(deployed.lazyWalletRegistry));
        (targets[2], payloads[2]) = (proxies.deviceWalletFactory, _upgrade(deployed.deviceWalletFactory));
        (targets[3], payloads[3]) = (proxies.eSIMWalletFactory, _upgrade(deployed.eSIMWalletFactory));
        (targets[4], payloads[4]) = (proxies.paymentAdapter, _upgrade(deployed.paymentAdapter));

        // Existing eSIM wallets keep 0. Only wallets created after this get the default.
        (targets[5], payloads[5]) = (
            proxies.registry,
            abi.encodeCall(Registry.setDefaultAdminAllowanceUSDCents, (allowance))
        );

        (targets[6], payloads[6]) = (
            proxies.deviceWalletFactory,
            abi.encodeCall(DeviceWalletFactory.updateDeviceWalletImplementation, (deployed.deviceWallet))
        );
        (targets[7], payloads[7]) = (
            proxies.eSIMWalletFactory,
            abi.encodeCall(ESIMWalletFactory.updateESIMWalletImplementation, (deployed.eSIMWallet))
        );

        address[5] memory owned = _asArray(proxies);
        for(uint256 i = 0; i < owned.length; ++i) {
            targets[8 + i] = owned[i];
            payloads[8 + i] = abi.encodeCall(OwnableUpgradeable.transferOwnership, (deployed.protocolAdmin));
        }
    }

    function _recordPending(
        ProtocolAdmin oldAdmin,
        Deployed memory deployed,
        address[] memory targets,
        bytes[] memory payloads,
        bytes32 salt,
        bytes32 operationId,
        uint256 delay,
        uint64 allowance
    ) private {
        string memory key = "pendingMigration";
        vm.serializeAddress(key, "oldProtocolAdmin", address(oldAdmin));
        vm.serializeAddress(key, "newProtocolAdmin", deployed.protocolAdmin);
        vm.serializeString(key, "implementations", _implementations(deployed));
        vm.serializeUint(key, "defaultAdminAllowanceUSDCents", allowance);
        vm.serializeAddress(key, "targets", targets);
        vm.serializeBytes(key, "payloads", payloads);
        vm.serializeBytes32(key, "salt", salt);
        vm.serializeBytes32(key, "operationId", operationId);
        vm.serializeUint(key, "delay", delay);
        vm.serializeUint(key, "scheduledAt", block.timestamp);
        vm.serializeUint(key, "executableAt", block.timestamp + delay);
        vm.serializeString(key, "build", _buildProvenance());
        string memory entry = vm.serializeBool(key, "executed", false);

        DeploymentRecord.writeObject(PENDING, entry);
    }

    function _implementations(Deployed memory deployed) private returns (string memory json) {
        string memory key = "migrationImplementations";
        vm.serializeAddress(key, "RegistryProxy", deployed.registry);
        vm.serializeAddress(key, "LazyWalletRegistryProxy", deployed.lazyWalletRegistry);
        vm.serializeAddress(key, "DeviceWalletFactoryProxy", deployed.deviceWalletFactory);
        vm.serializeAddress(key, "ESIMWalletFactoryProxy", deployed.eSIMWalletFactory);
        vm.serializeAddress(key, "PaymentAdapterProxy", deployed.paymentAdapter);
        vm.serializeAddress(key, "DeviceWalletImplementation", deployed.deviceWallet);
        json = vm.serializeAddress(key, "ESIMWalletImplementation", deployed.eSIMWallet);
    }

    // ---------------------------------------------------------------------------------------------
    // Execute
    // ---------------------------------------------------------------------------------------------

    function _execute() private {
        if(!DeploymentRecord.has(string.concat(PENDING, ".operationId"))) revert NothingScheduled();

        string memory json = vm.readFile(DeploymentRecord.recordPath());
        ProtocolAdmin oldAdmin = ProtocolAdmin(payable(_pendingAddress(json, "oldProtocolAdmin")));
        ProtocolAdmin newAdmin = ProtocolAdmin(payable(_pendingAddress(json, "newProtocolAdmin")));
        address[] memory targets = vm.parseJsonAddressArray(json, string.concat(".", PENDING, ".targets"));
        bytes[] memory payloads = vm.parseJsonBytesArray(json, string.concat(".", PENDING, ".payloads"));
        bytes32 salt = vm.parseJsonBytes32(json, string.concat(".", PENDING, ".salt"));
        bytes32 recorded = vm.parseJsonBytes32(json, string.concat(".", PENDING, ".operationId"));
        uint256[] memory values = new uint256[](targets.length);

        bytes32 recomputed = oldAdmin.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if(recomputed != recorded) revert OperationMismatch(recorded, recomputed);
        if(!oldAdmin.isOperationReady(recorded)) {
            revert NotReady(recorded, oldAdmin.getTimestamp(recorded), block.timestamp);
        }

        Proxies memory proxies = _proxies();
        address[] memory owned = new address[](5);
        address[5] memory list = _asArray(proxies);
        for(uint256 i = 0; i < 5; ++i) owned[i] = list[i];

        // Execution and acceptance are open to anyone, so the deployer key is enough
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        oldAdmin.executeBatch(targets, values, payloads, bytes32(0), salt);
        newAdmin.acceptOwnershipBatch(owned);
        vm.stopBroadcast();

        _verify(json, proxies, address(newAdmin));
        _recordDone(json, oldAdmin, newAdmin);

        console.log("Executed           ", vm.toString(recorded));
        console.log("Owner of all five  ", address(newAdmin));
    }

    /// @notice Reads the result back from the chain rather than trusting the batch
    function _verify(string memory json, Proxies memory proxies, address newAdmin) private view {
        _requireOwnedBy(proxies, newAdmin);

        string[5] memory names = _names();
        address[5] memory list = _asArray(proxies);
        for(uint256 i = 0; i < 5; ++i) {
            if(_implementationOf(list[i]) != _pendingImplementation(json, names[i])) {
                revert CheckFailed(string.concat(names[i], " implementation"));
            }
        }

        if(
            address(DeviceWalletFactory(proxies.deviceWalletFactory).beacon().implementation())
                != _pendingImplementation(json, "DeviceWalletImplementation")
        ) revert CheckFailed("DeviceWallet beacon");
        if(
            address(ESIMWalletFactory(proxies.eSIMWalletFactory).beacon().implementation())
                != _pendingImplementation(json, "ESIMWalletImplementation")
        ) revert CheckFailed("ESIMWallet beacon");

        uint256 allowance = vm.parseJsonUint(json, string.concat(".", PENDING, ".defaultAdminAllowanceUSDCents"));
        if(Registry(proxies.registry).defaultAdminAllowanceUSDCents() != allowance) {
            revert CheckFailed("default admin allowance");
        }
        if(ProtocolAdmin(payable(newAdmin)).getMinDelay() != DeployConfig.TIMELOCK_DELAY) {
            revert CheckFailed("new timelock delay");
        }
    }

    /// @notice Points the record and address book at the new admin and implementations
    function _recordDone(string memory json, ProtocolAdmin oldAdmin, ProtocolAdmin newAdmin) private {
        if(vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console.log("Dry run: record not written");
            return;
        }

        string memory record = DeploymentRecord.recordPath();
        vm.writeJson(_quoted(address(newAdmin)), record, ".admin.protocolAdmin");
        vm.writeJson(_quoted(address(oldAdmin)), record, ".admin.previousProtocolAdmin");
        vm.writeJson(vm.toString(DeployConfig.TIMELOCK_DELAY_FLOOR), record, ".admin.minDelayFloor");
        vm.writeJson(_quoted(address(newAdmin)), record, ".contracts.ProtocolAdmin.address");
        vm.writeJson(_quoted(address(newAdmin).codehash), record, ".contracts.ProtocolAdmin.codehash");

        string[5] memory names = _names();
        for(uint256 i = 0; i < 5; ++i) {
            vm.writeJson(
                _quoted(_pendingImplementation(json, names[i])),
                record,
                string.concat(".contracts.", names[i], ".implementation")
            );
        }

        address deviceWallet = _pendingImplementation(json, "DeviceWalletImplementation");
        address eSIMWallet = _pendingImplementation(json, "ESIMWalletImplementation");
        vm.writeJson(_quoted(deviceWallet), record, ".contracts.DeviceWalletImplementation.address");
        vm.writeJson(_quoted(deviceWallet.codehash), record, ".contracts.DeviceWalletImplementation.codehash");
        vm.writeJson(_quoted(eSIMWallet), record, ".contracts.ESIMWalletImplementation.address");
        vm.writeJson(_quoted(eSIMWallet.codehash), record, ".contracts.ESIMWalletImplementation.codehash");
        vm.writeJson("true", record, string.concat(".", PENDING, ".executed"));

        string memory book = DeploymentRecord.addressBookPath();
        string memory entry = string.concat(".", DeployConfig.recordKey());
        vm.writeJson(_quoted(address(newAdmin)), book, string.concat(entry, ".ProtocolAdmin"));
        vm.writeJson(_quoted(deviceWallet), book, string.concat(entry, ".DeviceWalletImpl"));
        vm.writeJson(_quoted(eSIMWallet), book, string.concat(entry, ".ESIMWalletImpl"));
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _recordedAdmin() private view returns (ProtocolAdmin admin) {
        admin = ProtocolAdmin(payable(DeploymentRecord.readRaw("admin.protocolAdmin")));
    }

    function _proxies() private view returns (Proxies memory proxies) {
        proxies.registry = DeploymentRecord.readAddress("RegistryProxy");
        proxies.lazyWalletRegistry = DeploymentRecord.readAddress("LazyWalletRegistryProxy");
        proxies.deviceWalletFactory = DeploymentRecord.readAddress("DeviceWalletFactoryProxy");
        proxies.eSIMWalletFactory = DeploymentRecord.readAddress("ESIMWalletFactoryProxy");
        proxies.paymentAdapter = DeploymentRecord.readAddress("PaymentAdapterProxy");
    }

    function _asArray(Proxies memory proxies) private pure returns (address[5] memory list) {
        list = [
            proxies.registry,
            proxies.lazyWalletRegistry,
            proxies.deviceWalletFactory,
            proxies.eSIMWalletFactory,
            proxies.paymentAdapter
        ];
    }

    /// @notice Record names in the same order as `_asArray`
    function _names() private pure returns (string[5] memory names) {
        names = [
            "RegistryProxy",
            "LazyWalletRegistryProxy",
            "DeviceWalletFactoryProxy",
            "ESIMWalletFactoryProxy",
            "PaymentAdapterProxy"
        ];
    }

    function _requireOwnedBy(Proxies memory proxies, address admin) private view {
        address[5] memory list = _asArray(proxies);
        for(uint256 i = 0; i < 5; ++i) {
            address owner = OwnableUpgradeable(list[i]).owner();
            if(owner != admin) revert NotOwnedByRecordedAdmin(list[i], owner);
        }
    }

    function _upgrade(address implementation) private pure returns (bytes memory payload) {
        payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, ""));
    }

    function _implementationOf(address proxy) private view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _pendingAddress(string memory json, string memory field) private pure returns (address value) {
        value = vm.parseJsonAddress(json, string.concat(".", PENDING, ".", field));
    }

    function _pendingImplementation(string memory json, string memory name) private pure returns (address value) {
        value = vm.parseJsonAddress(json, string.concat(".", PENDING, ".implementations.", name));
    }

    /// @notice Same provenance the deploy script records, for the code this batch installs
    function _buildProvenance() private returns (string memory provenance) {
        string[] memory command = new string[](2);
        command[0] = "python3";
        command[1] = "scripts/checks/build-provenance.py";
        provenance = string(vm.ffi(command));
    }

    function _quoted(address value) private pure returns (string memory json) {
        json = string.concat('"', vm.toString(value), '"');
    }

    function _quoted(bytes32 value) private pure returns (string memory json) {
        json = string.concat('"', vm.toString(value), '"');
    }

    function _is(string memory left, string memory right) private pure returns (bool equal) {
        equal = keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
