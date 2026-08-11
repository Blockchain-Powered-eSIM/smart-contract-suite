// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolAdmin} from "../../contracts/admin/ProtocolAdmin.sol";
import {P256Verifier} from "../../contracts/P256Verifier.sol";
import {Registry} from "../../contracts/Registry.sol";
import {LazyWalletRegistry} from "../../contracts/LazyWalletRegistry.sol";
import {DeviceWallet} from "../../contracts/device-wallet/DeviceWallet.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWallet} from "../../contracts/esim-wallet/ESIMWallet.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";

// Config
import {DeployConfig} from "./config/DeployConfig.sol";
import {DeploymentRecord} from "./config/DeploymentRecord.sol";

/// @notice Deploys the protocol from nothing and records what it deployed
/// @dev Run first, then `Configure.s.sol`, then `TransferOwnership.s.sol`. The three are separate
///      because only the first is expensive to repeat: a configuration call that runs out of gas
///      should not mean redeploying eight contracts to try again.
///
///      The deployer is passed as `_upgradeManager` to all four singletons rather than
///      `ProtocolAdmin`, and that is deliberate. Three configuration calls are owner gated and
///      structurally cannot be folded into any `initialize`, because both factories have to exist
///      before the registry and the registry has to exist before either factory can be told about
///      it. Handing ownership to the timelock first would put a two day wait between deployment and
///      a working protocol, and would spend that window with the timelock deliberately weakened to
///      shorten it. Instead the deployer holds ownership across three scripts in one sitting and
///      hands it over at the end, which is what `ProtocolAdmin.acceptOwnershipBatch` exists for.
///
///      `ProtocolAdmin` is still deployed first, so its address is recorded before anything can
///      depend on it and the handover script has nothing left to decide.
///
///      Ordinary `ERC1967Proxy`, not the upgrades plugin. The whole test suite stands the protocol
///      up this way, so the deployed shape is the shape 573 tests run against, and the safety the
///      plugin checks at deploy time is already pinned by `ImplementationLocks.t.sol` and
///      `StorageLayout.t.sol`.
contract Deploy is Script {

    /// @notice Addresses produced by one run, carried between the deploy and the record
    /// @dev A struct rather than locals because the recording step reads all of them at once, and a
    ///      long run of consecutive calls in one body is what pushes this repo into stack-too-deep.
    struct Deployed {
        address protocolAdmin;
        address p256Verifier;
        address eSIMWalletImplementation;
        address eSIMWalletFactory;
        address deviceWalletImplementation;
        address deviceWalletFactory;
        address registry;
        address lazyWalletRegistry;
    }

    /// @notice ERC-1967 implementation slot, read back rather than assumed
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice A proxy did not come up pointing at the implementation it was given
    error ImplementationMismatch(address proxy, address expected, address actual);

    /// @notice The record already holds a deployment for this chain
    error AlreadyDeployed(string network);

    /// @notice A deployed contract does not point at what its constructor argument named
    error WiringMismatch(string what, address expected, address actual);

    /// @notice Deploys the protocol and writes the record for this chain
    /// @dev Broadcasts. Reverts before sending anything if the environment is incomplete or if the
    ///      record already holds a deployment for this chain.
    function run() external {
        DeployConfig.Config memory config = DeployConfig.load();

        // Refuse to write over a chain that already has a deployment. Overwriting the record is
        // how a live proxy stops being reachable by any script, since nothing else remembers it.
        if(DeploymentRecord.has("contracts.RegistryProxy")) {
            revert AlreadyDeployed(DeployConfig.recordKey());
        }

        _logPlan(config);

        vm.startBroadcast(config.deployerPrivateKey);
        Deployed memory deployed = _deploy(config);
        vm.stopBroadcast();

        _verify(deployed);
        _record(config, deployed);

        console.log("");
        console.log("Deployed. Next: Configure.s.sol, then TransferOwnership.s.sol.");
        console.log("The protocol does not work until both have run.");
    }

    /// @notice Deploys every contract in dependency order
    /// @dev The deployer is the upgrade manager for now. Ownership moves in the third script.
    function _deploy(DeployConfig.Config memory config) private returns (Deployed memory deployed) {
        deployed.protocolAdmin = address(
            new ProtocolAdmin(
                DeployConfig.TIMELOCK_DELAY,
                DeployConfig.TIMELOCK_DELAY_FLOOR,
                config.proposers,
                config.cancellers,
                config.guardians
            )
        );

        deployed.p256Verifier = address(new P256Verifier());

        deployed.eSIMWalletImplementation = address(new ESIMWallet());
        deployed.eSIMWalletFactory = _deployProxy(
            address(new ESIMWalletFactory()),
            abi.encodeCall(
                ESIMWalletFactory.initialize,
                (deployed.eSIMWalletImplementation, config.deployer)
            )
        );

        deployed.deviceWalletImplementation = address(
            new DeviceWallet(config.entryPoint, P256Verifier(deployed.p256Verifier))
        );
        deployed.deviceWalletFactory = _deployProxy(
            address(new DeviceWalletFactory()),
            abi.encodeCall(
                DeviceWalletFactory.initialize,
                (
                    deployed.deviceWalletImplementation,
                    config.vault,
                    config.deployer,
                    deployed.eSIMWalletFactory,
                    config.entryPoint,
                    P256Verifier(deployed.p256Verifier)
                )
            )
        );

        deployed.registry = _deployProxy(
            address(new Registry()),
            abi.encodeCall(
                Registry.initialize,
                (
                    config.eSIMWalletAdmin,
                    config.vault,
                    config.deployer,
                    deployed.deviceWalletFactory,
                    deployed.eSIMWalletFactory,
                    config.entryPoint
                )
            )
        );

        deployed.lazyWalletRegistry = _deployProxy(
            address(new LazyWalletRegistry()),
            abi.encodeCall(LazyWalletRegistry.initialize, (deployed.registry, config.deployer))
        );
    }

    /// @notice Stands a UUPS implementation up behind a proxy and initializes it in one transaction
    /// @dev Initializing in the proxy constructor closes the window where a deployed proxy sits
    ///      uninitialized and anybody can call `initialize` on it.
    /// @param implementation Logic contract the proxy delegates to
    /// @param initData Encoded `initialize` call run during construction
    /// @return proxy Address of the deployed proxy
    function _deployProxy(address implementation, bytes memory initData)
        private
        returns (address proxy)
    {
        proxy = address(new ERC1967Proxy(implementation, initData));

        address stored = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        if(stored != implementation) {
            revert ImplementationMismatch(proxy, implementation, stored);
        }
    }

    /// @notice Reads the deployment back through its own getters
    /// @dev Checks the wiring the constructor arguments were supposed to produce rather than
    ///      trusting the arguments, which is the difference between a deployment log and a check.
    ///      Runs outside the broadcast, so nothing here costs gas.
    function _verify(Deployed memory deployed) private view {
        Registry registry = Registry(deployed.registry);

        address boundDeviceFactory = address(registry.deviceWalletFactory());
        if(boundDeviceFactory != deployed.deviceWalletFactory) {
            revert WiringMismatch(
                "Registry.deviceWalletFactory",
                deployed.deviceWalletFactory,
                boundDeviceFactory
            );
        }

        address boundESIMFactory = address(registry.eSIMWalletFactory());
        if(boundESIMFactory != deployed.eSIMWalletFactory) {
            revert WiringMismatch(
                "Registry.eSIMWalletFactory",
                deployed.eSIMWalletFactory,
                boundESIMFactory
            );
        }

        address boundRegistry = address(LazyWalletRegistry(deployed.lazyWalletRegistry).registry());
        if(boundRegistry != deployed.registry) {
            revert WiringMismatch("LazyWalletRegistry.registry", deployed.registry, boundRegistry);
        }
    }

    /// @notice Writes the deployment record for this chain
    function _record(DeployConfig.Config memory config, Deployed memory deployed) private {
        string memory network = DeployConfig.recordKey();

        string memory record = vm.serializeString("record", "build", _buildProvenance());
        record = vm.serializeString("record", "chain", _chainSection(config));
        record = vm.serializeString("record", "external", _externalSection(config));
        record = vm.serializeString("record", "params", _paramsSection(config));
        record = vm.serializeString("record", "admin", _adminSection(config, deployed));
        record = vm.serializeString("record", "contracts", _contractsSection(deployed));
        record = vm.serializeString("record", "status", _statusSection());

        vm.writeJson(record, DeploymentRecord.PATH, string.concat(".", network));
        console.log("Record written to", DeploymentRecord.PATH, "under", network);
    }

    /// @notice Everything needed to rebuild this bytecode later, collected offchain
    /// @dev Through `ffi`, which this repo already enables for the WebAuthn test signer. A commit
    ///      hash on its own does not reproduce a build here: seven submodules and six compiler
    ///      settings move the output without touching this repo's history.
    function _buildProvenance() private returns (string memory provenance) {
        string[] memory command = new string[](2);
        command[0] = "python3";
        command[1] = "scripts/checks/build-provenance.py";

        provenance = vm.serializeJson("build", string(vm.ffi(command)));
    }

    function _chainSection(DeployConfig.Config memory config)
        private
        returns (string memory section)
    {
        vm.serializeUint("chain", "chainId", config.chainId);
        vm.serializeString("chain", "network", DeployConfig.chainLabel());
        vm.serializeString("chain", "recordKey", DeployConfig.recordKey());
        vm.serializeUint("chain", "deployedAtBlock", block.number);
        vm.serializeUint("chain", "deployedAtTimestamp", block.timestamp);
        section = vm.serializeAddress("chain", "deployer", config.deployer);
    }

    function _externalSection(DeployConfig.Config memory config)
        private
        returns (string memory section)
    {
        vm.serializeString("external", "entryPointVersion", "0.8.0");
        section = vm.serializeAddress("external", "entryPoint", address(config.entryPoint));
    }

    function _paramsSection(DeployConfig.Config memory config)
        private
        returns (string memory section)
    {
        vm.serializeAddress("params", "eSIMWalletAdmin", config.eSIMWalletAdmin);
        vm.serializeAddress("params", "vault", config.vault);
        section = vm.serializeUint("params", "dataBundlePriceCap", config.dataBundlePriceCap);
    }

    function _adminSection(DeployConfig.Config memory config, Deployed memory deployed)
        private
        returns (string memory section)
    {
        vm.serializeAddress("admin", "protocolAdmin", deployed.protocolAdmin);
        vm.serializeUint("admin", "initialDelay", DeployConfig.TIMELOCK_DELAY);
        vm.serializeUint("admin", "minDelayFloor", DeployConfig.TIMELOCK_DELAY_FLOOR);
        vm.serializeAddress("admin", "proposers", config.proposers);
        vm.serializeAddress("admin", "cancellers", config.cancellers);
        section = vm.serializeAddress("admin", "guardians", config.guardians);
    }

    /// @notice One entry per deployed contract, each carrying enough to check it onchain
    /// @dev `codehash` is what makes the record checkable without a block explorer: rebuild at the
    ///      recorded commit and submodule pins, hash the runtime bytecode, compare. The
    ///      implementation address is read out of the ERC-1967 slot rather than repeated from the
    ///      constructor argument, so a proxy that came up wrong shows here.
    function _contractsSection(Deployed memory deployed) private returns (string memory section) {
        vm.serializeString("contracts", "ProtocolAdmin", _plain(deployed.protocolAdmin));
        vm.serializeString("contracts", "P256Verifier", _plain(deployed.p256Verifier));
        vm.serializeString(
            "contracts",
            "ESIMWalletImplementation",
            _plain(deployed.eSIMWalletImplementation)
        );
        vm.serializeString(
            "contracts",
            "DeviceWalletImplementation",
            _plain(deployed.deviceWalletImplementation)
        );
        vm.serializeString(
            "contracts",
            "ESIMWalletFactoryProxy",
            _factory(
                "esimFactory",
                deployed.eSIMWalletFactory,
                address(ESIMWalletFactory(deployed.eSIMWalletFactory).beacon())
            )
        );
        vm.serializeString(
            "contracts",
            "DeviceWalletFactoryProxy",
            _factory(
                "deviceFactory",
                deployed.deviceWalletFactory,
                address(DeviceWalletFactory(deployed.deviceWalletFactory).beacon())
            )
        );
        vm.serializeString("contracts", "RegistryProxy", _proxy("registry", deployed.registry));
        section = vm.serializeString(
            "contracts",
            "LazyWalletRegistryProxy",
            _proxy("lazyRegistry", deployed.lazyWalletRegistry)
        );
    }

    function _statusSection() private returns (string memory section) {
        vm.serializeBool("status", "configured", false);
        section = vm.serializeBool("status", "ownershipTransferred", false);
    }

    /// @notice Record entry for a contract deployed directly
    function _plain(address target) private returns (string memory entry) {
        string memory key = string.concat("plain", vm.toString(target));
        vm.serializeAddress(key, "address", target);
        entry = vm.serializeBytes32(key, "codehash", target.codehash);
    }

    /// @notice Record entry for a UUPS proxy, carrying the implementation it points at
    function _proxy(string memory key, address proxy) private returns (string memory entry) {
        vm.serializeAddress(key, "address", proxy);
        vm.serializeBytes32(key, "codehash", proxy.codehash);
        entry = vm.serializeAddress(
            key,
            "implementation",
            address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))))
        );
    }

    /// @notice Record entry for a factory, which is a UUPS proxy that also owns a beacon
    /// @dev The beacon is recorded because a beacon upgrade reaches every wallet at once and
    ///      nothing else in the file names it.
    function _factory(string memory key, address proxy, address beacon)
        private
        returns (string memory entry)
    {
        vm.serializeAddress(key, "address", proxy);
        vm.serializeBytes32(key, "codehash", proxy.codehash);
        vm.serializeAddress(
            key,
            "implementation",
            address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))))
        );
        entry = vm.serializeAddress(key, "beacon", beacon);
    }

    function _logPlan(DeployConfig.Config memory config) private view {
        console.log("Network        ", DeployConfig.chainLabel());
        console.log("Chain id       ", config.chainId);
        console.log("Record key     ", DeployConfig.recordKey());
        console.log("Deployer       ", config.deployer);
        console.log("EntryPoint     ", address(config.entryPoint));
        console.log("eSIM admin     ", config.eSIMWalletAdmin);
        console.log("Vault          ", config.vault);
        console.log("Proposers      ", config.proposers.length);
        console.log("Cancellers     ", config.cancellers.length);
        console.log("Guardians      ", config.guardians.length);
        console.log("");
    }
}
