// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {ScriptBase} from "./base/ScriptBase.sol";
import {Registry} from "contracts/Registry.sol";
import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter, Asset} from "contracts/payments/PaymentAdapter.sol";
import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";

// Scripts
import {Deploy} from "scripts/deploy/Deploy.s.sol";
import {Configure} from "scripts/deploy/Configure.s.sol";
import {TransferOwnership} from "scripts/deploy/TransferOwnership.s.sol";
import {DeployConfig} from "scripts/deploy/config/DeployConfig.sol";
import {DeploymentRecord} from "scripts/deploy/config/DeploymentRecord.sol";

/// @notice Reaches the record library from outside, so a revert can be caught
contract RecordReader {
    function readAddress(string memory key) external view returns (address target) {
        target = DeploymentRecord.readAddress(key);
    }

    function readRaw(string memory path) external view returns (address value) {
        value = DeploymentRecord.readRaw(path);
    }

    function readUint(string memory path) external view returns (uint256 value) {
        value = DeploymentRecord.readUint(path);
    }
}

/// @notice A contract with code that answers nothing, for the token checks
contract NotAToken {
    fallback() external { revert(); }
}

/// @notice The three deployment scripts, run against a scratch record
/// @dev `rehearse.sh` already runs these against a Base Sepolia fork and is the better check of the
///      happy path, but it needs an RPC key and a live anvil, so CI never runs it. What no fork
///      rehearsal reaches at all is the failure and resume branches: every one of them needs a
///      deployment that has already gone wrong in a particular way, which is not a state a
///      rehearsal can arrive at. Those are what most of this file is.
///
///      One contract for all of it, and that is forced rather than chosen. The record path is an
///      environment variable, forge runs every `setUp` before any test, and the environment belongs
///      to the process, so two contracts cannot point at two different files. Sharing one file
///      across contracts that run at the same time would interleave their writes.
///
///      For the same reason nothing here rewrites an environment variable. A broken configuration
///      is arrived at through EVM state instead, which forge does restore between tests.
contract DeployScriptsTest is ScriptBase {

    /// @notice Symbols `Configure` puts in the adapter's table
    bytes32 private constant ASSET_USD = bytes32("USD");
    bytes32 private constant ASSET_USDC = bytes32("USDC");

    /// @notice ERC-1967 implementation slot, read back rather than assumed
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    RecordReader private reader;

    function setUp() public {
        _setUpScriptEnvironment();
        reader = new RecordReader();
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @notice Empties the record and runs the deploy
    /// @dev Every test starts here rather than in `setUp`, because `setUp` runs once for the whole
    ///      contract while the file it wrote outlives each test.
    function _deploy() private {
        _resetRecord();
        new Deploy().run();
    }

    function _configure() private {
        new Configure().run();
    }

    function _recordedAddress(string memory key) private view returns (address target) {
        target = vm.parseJsonAddress(
            vm.readFile(scratchRecord),
            string.concat(".", _recordKey(), ".contracts.", key, ".address")
        );
    }

    function _registry() private view returns (Registry) {
        return Registry(_recordedAddress("RegistryProxy"));
    }

    function _adapter() private view returns (PaymentAdapter) {
        return PaymentAdapter(_recordedAddress("PaymentAdapterProxy"));
    }

    // ---------------------------------------------------------------------------------------------
    // The record itself
    // ---------------------------------------------------------------------------------------------

    function test_recordPath_followsTheOverride() public view {
        assertEq(DeploymentRecord.recordPath(), scratchRecord, "override");
        assertEq(DeploymentRecord.DEFAULT_PATH, "deployments/address.json", "default");
    }

    function test_readAddress_returnsWhatTheDeployWrote() public {
        _deploy();

        assertEq(
            DeploymentRecord.readAddress("RegistryProxy"),
            address(_registry()),
            "registry read back"
        );
    }

    function test_readAddress_revertsForAKeyThisChainHasNoEntryFor() public {
        _deploy();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRecord.NotRecorded.selector,
                _recordKey(),
                "NotAContractWeDeploy"
            )
        );
        reader.readAddress("NotAContractWeDeploy");
    }

    /// @dev The code check is the point of `readAddress`. A key holding an address from another
    ///      chain parses exactly like one from this chain, and only the code tells them apart.
    function test_readAddress_revertsWhenTheRecordedAddressHasNoCode() public {
        _deploy();

        address registry = address(_registry());
        vm.etch(registry, "");

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentRecord.NoCodeAt.selector, "RegistryProxy", registry)
        );
        reader.readAddress("RegistryProxy");
    }

    function test_readRaw_returnsAnAccountThatCarriesNoCode() public {
        _deploy();

        address recordedAdmin = DeploymentRecord.readRaw("admin.protocolAdmin");
        assertEq(recordedAdmin, _recordedAddress("ProtocolAdmin"), "protocol admin");
    }

    function test_readRaw_revertsForAPathTheRecordDoesNotHold() public {
        _deploy();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRecord.NotRecorded.selector,
                _recordKey(),
                "admin.notARole"
            )
        );
        reader.readRaw("admin.notARole");
    }

    function test_readUint_returnsARecordedNumber() public {
        _deploy();

        assertEq(
            DeploymentRecord.readUint("params.priceCapUSDCents"),
            PRICE_CAP_CENTS,
            "price cap"
        );
        assertEq(
            DeploymentRecord.readUint("admin.initialDelay"),
            DeployConfig.TIMELOCK_DELAY,
            "timelock delay"
        );
    }

    function test_readUint_revertsForAPathTheRecordDoesNotHold() public {
        _deploy();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentRecord.NotRecorded.selector,
                _recordKey(),
                "params.notAParameter"
            )
        );
        reader.readUint("params.notAParameter");
    }

    function test_has_answersForBothAPresentAndAnAbsentPath() public {
        _deploy();

        assertTrue(DeploymentRecord.has("contracts.RegistryProxy"), "present");
        assertFalse(DeploymentRecord.has("contracts.SomethingElse"), "absent");
    }

    /// @dev `writeStatus` passes the bool as JSON text rather than serializing it, so the value
    ///      lands where the bool goes instead of as an object wrapping it.
    function test_writeStatus_writesABoolAndNotAnObject() public {
        _deploy();

        DeploymentRecord.writeStatus("configured", true);

        assertTrue(
            vm.parseJsonBool(
                vm.readFile(scratchRecord),
                string.concat(".", _recordKey(), ".status.configured")
            ),
            "configured reads as a bool"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy
    // ---------------------------------------------------------------------------------------------

    function test_deploy_wiresTheRegistryToBothFactoriesAndTheAdapter() public {
        _deploy();

        Registry registry = _registry();

        assertEq(
            address(registry.deviceWalletFactory()),
            _recordedAddress("DeviceWalletFactoryProxy"),
            "device factory"
        );
        assertEq(
            address(registry.eSIMWalletFactory()),
            _recordedAddress("ESIMWalletFactoryProxy"),
            "esim factory"
        );
        assertEq(
            registry.paymentAdapter(),
            _recordedAddress("PaymentAdapterProxy"),
            "payment adapter"
        );
    }

    function test_deploy_pointsTheAdapterAndLazyRegistryBackAtTheRegistry() public {
        _deploy();

        address registry = address(_registry());

        assertEq(_adapter().registry(), registry, "adapter registry");
        assertEq(
            address(LazyWalletRegistry(_recordedAddress("LazyWalletRegistryProxy")).registry()),
            registry,
            "lazy registry"
        );
    }

    /// @dev The deployer holds all five across the three scripts, because the wiring calls are owner
    ///      gated and cannot run through a timelock that is not yet the owner.
    function test_deploy_leavesTheDeployerOwningEverySingleton() public {
        _deploy();

        assertEq(_registry().owner(), deployer, "registry");
        assertEq(LazyWalletRegistry(_recordedAddress("LazyWalletRegistryProxy")).owner(), deployer, "lazy");
        assertEq(DeviceWalletFactory(_recordedAddress("DeviceWalletFactoryProxy")).owner(), deployer, "device");
        assertEq(ESIMWalletFactory(_recordedAddress("ESIMWalletFactoryProxy")).owner(), deployer, "esim");
        assertEq(_adapter().owner(), deployer, "adapter");
    }

    function test_deploy_takesTheParametersFromTheEnvironment() public {
        _deploy();

        Registry registry = _registry();

        assertEq(registry.eSIMWalletAdmin(), eSIMWalletAdmin, "admin");
        assertEq(registry.vault(), vault, "vault");
        assertEq(registry.defaultPriceCapUSDCents(), PRICE_CAP_CENTS, "price cap");
        assertEq(_adapter().settlementToken(), address(settlementToken), "settlement token");
    }

    /// @dev Read out of the ERC-1967 slot rather than repeated from the constructor argument, so a
    ///      proxy that came up pointing somewhere else shows in the record instead of being
    ///      described by it.
    function test_deploy_recordsTheImplementationEachProxyActuallyPointsAt() public {
        _deploy();

        address proxy = address(_registry());
        address recorded = vm.parseJsonAddress(
            vm.readFile(scratchRecord),
            string.concat(".", _recordKey(), ".contracts.RegistryProxy.implementation")
        );

        assertEq(
            recorded,
            address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))),
            "recorded implementation"
        );
        assertTrue(recorded.code.length > 0, "implementation carries code");
    }

    function test_deploy_recordsBothBeacons() public {
        _deploy();

        assertEq(
            vm.parseJsonAddress(
                vm.readFile(scratchRecord),
                string.concat(".", _recordKey(), ".contracts.ESIMWalletFactoryProxy.beacon")
            ),
            address(ESIMWalletFactory(_recordedAddress("ESIMWalletFactoryProxy")).beacon()),
            "esim beacon"
        );
        assertEq(
            vm.parseJsonAddress(
                vm.readFile(scratchRecord),
                string.concat(".", _recordKey(), ".contracts.DeviceWalletFactoryProxy.beacon")
            ),
            address(DeviceWalletFactory(_recordedAddress("DeviceWalletFactoryProxy")).beacon()),
            "device beacon"
        );
    }

    function test_deploy_startsWithBothLaterStepsUnfinished() public {
        _deploy();

        string memory record = vm.readFile(scratchRecord);

        assertFalse(
            vm.parseJsonBool(record, string.concat(".", _recordKey(), ".status.configured")),
            "not configured yet"
        );
        assertFalse(
            vm.parseJsonBool(
                record,
                string.concat(".", _recordKey(), ".status.ownershipTransferred")
            ),
            "not handed over yet"
        );
    }

    /// @dev Overwriting the record is how a live proxy stops being reachable by any script, since
    ///      nothing else remembers where it is.
    function test_deploy_refusesAChainThatAlreadyHasADeployment() public {
        _deploy();

        Deploy second = new Deploy();
        vm.expectRevert(abi.encodeWithSelector(Deploy.AlreadyDeployed.selector, _recordKey()));
        second.run();
    }

    // ---------------------------------------------------------------------------------------------
    // Configure
    // ---------------------------------------------------------------------------------------------

    function test_configure_bindsBothFactoriesToTheRegistry() public {
        _deploy();
        _configure();

        address registry = address(_registry());

        assertEq(
            address(DeviceWalletFactory(_recordedAddress("DeviceWalletFactoryProxy")).registry()),
            registry,
            "device factory"
        );
        assertEq(
            address(ESIMWalletFactory(_recordedAddress("ESIMWalletFactoryProxy")).registry()),
            registry,
            "esim factory"
        );
    }

    function test_configure_pointsTheRegistryAtTheLazyWalletRegistry() public {
        _deploy();
        _configure();

        assertEq(
            _registry().lazyWalletRegistry(),
            _recordedAddress("LazyWalletRegistryProxy"),
            "lazy wallet registry"
        );
    }

    /// @dev An adapter with an empty table prices nothing, so every purchase on both paths reverts
    ///      until this has run.
    function test_configure_registersBothCurrencies() public {
        _deploy();
        _configure();

        (bool usdAllowed, bool usdIsDollar, uint8 usdDecimals, address usdToken) =
            _adapter().assets(ASSET_USD);

        assertTrue(usdAllowed, "USD allowed");
        assertTrue(usdIsDollar, "USD is a dollar unit");
        assertEq(usdDecimals, 2, "USD decimals are cents");
        assertEq(usdToken, address(0), "USD moves no token");

        (bool usdcAllowed,, uint8 usdcDecimals, address usdcToken) = _adapter().assets(ASSET_USDC);

        assertTrue(usdcAllowed, "USDC allowed");
        assertEq(usdcDecimals, SETTLEMENT_DECIMALS, "USDC decimals off the token");
        assertEq(usdcToken, address(settlementToken), "USDC token");
    }

    function test_configure_marksTheRecordConfigured() public {
        _deploy();
        _configure();

        assertTrue(
            vm.parseJsonBool(
                vm.readFile(scratchRecord),
                string.concat(".", _recordKey(), ".status.configured")
            ),
            "configured"
        );
    }

    /// @dev The whole point of the skip branches. Both `addRegistryAddress` functions and
    ///      `registerAsset` refuse a second call, so without them one failed transaction would
    ///      leave this script unable to finish the run it started.
    function test_configure_canBeRunTwice() public {
        _deploy();
        _configure();
        _configure();

        assertEq(
            address(DeviceWalletFactory(_recordedAddress("DeviceWalletFactoryProxy")).registry()),
            address(_registry()),
            "still bound after a second run"
        );
    }

    function test_configure_revertsWhenAFactoryIsBoundToADifferentRegistry() public {
        _deploy();

        address factory = _recordedAddress("DeviceWalletFactoryProxy");
        address impostor = makeAddr("impostorRegistry");

        vm.prank(deployer);
        DeviceWalletFactory(factory).addRegistryAddress(impostor);

        Configure configure = new Configure();
        vm.expectRevert(
            abi.encodeWithSelector(
                Configure.BoundElsewhere.selector,
                "DeviceWalletFactory",
                address(_registry()),
                impostor
            )
        );
        configure.run();
    }

    /// @dev `updateAsset` would change the address every future payment is recorded into, so a
    ///      symbol already pointing somewhere else has to stop the run rather than be corrected.
    function test_configure_revertsWhenACurrencyPointsAtADifferentToken() public {
        _deploy();

        address other = address(new MockERC20("Other", "OTH", 6));

        vm.prank(deployer);
        _adapter().registerAsset(ASSET_USDC, Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: 6,
            token: other
        }));

        Configure configure = new Configure();
        vm.expectRevert(
            abi.encodeWithSelector(
                Configure.AssetBoundElsewhere.selector,
                ASSET_USDC,
                address(settlementToken),
                other
            )
        );
        configure.run();
    }

    /// @dev USDC sits at a different address on every chain, and the address for the wrong one can
    ///      still hold code, so this has to fail before anything is broadcast.
    function test_configure_revertsWhenTheSettlementTokenHasNoCode() public {
        _deploy();

        vm.etch(SETTLEMENT_TOKEN_ADDRESS, "");

        Configure configure = new Configure();
        vm.expectRevert(
            abi.encodeWithSelector(
                Configure.SettlementTokenNotDeployed.selector,
                SETTLEMENT_TOKEN_ADDRESS,
                block.chainid
            )
        );
        configure.run();
    }

    function test_configure_revertsWhenTheSettlementTokenAnswersNothing() public {
        _deploy();

        vm.etch(SETTLEMENT_TOKEN_ADDRESS, address(new NotAToken()).code);

        Configure configure = new Configure();
        vm.expectRevert(
            abi.encodeWithSelector(
                Configure.SettlementTokenNotTokenLike.selector,
                SETTLEMENT_TOKEN_ADDRESS
            )
        );
        configure.run();
    }

    // ---------------------------------------------------------------------------------------------
    // TransferOwnership
    // ---------------------------------------------------------------------------------------------

    function test_transferOwnership_movesAllFiveToTheTimelock() public {
        _deploy();
        _configure();
        new TransferOwnership().run();

        address protocolAdmin = _recordedAddress("ProtocolAdmin");

        assertEq(_registry().owner(), protocolAdmin, "registry");
        assertEq(LazyWalletRegistry(_recordedAddress("LazyWalletRegistryProxy")).owner(), protocolAdmin, "lazy");
        assertEq(DeviceWalletFactory(_recordedAddress("DeviceWalletFactoryProxy")).owner(), protocolAdmin, "device");
        assertEq(ESIMWalletFactory(_recordedAddress("ESIMWalletFactoryProxy")).owner(), protocolAdmin, "esim");
        assertEq(_adapter().owner(), protocolAdmin, "adapter");
    }

    function test_transferOwnership_marksTheRecordHandedOver() public {
        _deploy();
        _configure();
        new TransferOwnership().run();

        assertTrue(
            vm.parseJsonBool(
                vm.readFile(scratchRecord),
                string.concat(".", _recordKey(), ".status.ownershipTransferred")
            ),
            "ownership transferred"
        );
    }

    /// @dev Checked over all five before the first offer is sent, so a run that would hand over
    ///      four and revert on the fifth never sends any of them.
    function test_transferOwnership_refusesToStartWhenTheDeployerLostOne() public {
        _deploy();
        _configure();

        address stranger = makeAddr("stranger");
        PaymentAdapter adapter = _adapter();

        vm.prank(deployer);
        adapter.transferOwnership(stranger);
        vm.prank(stranger);
        adapter.acceptOwnership();

        TransferOwnership handover = new TransferOwnership();
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferOwnership.NotOwner.selector,
                address(adapter),
                stranger,
                deployer
            )
        );
        handover.run();
    }

    /// @dev The timelock is what every owner gated call waits on afterwards, so the delay it comes
    ///      up with is part of the deployment rather than something set later.
    function test_transferOwnership_leavesTheTimelockHoldingItsConfiguredDelay() public {
        _deploy();
        _configure();
        new TransferOwnership().run();

        ProtocolAdmin admin = ProtocolAdmin(payable(_recordedAddress("ProtocolAdmin")));

        assertEq(admin.getMinDelay(), DeployConfig.TIMELOCK_DELAY, "delay");
        assertTrue(admin.hasRole(admin.PROPOSER_ROLE(), proposer), "proposer");
        assertTrue(admin.hasRole(admin.CANCELLER_ROLE(), canceller), "canceller");
    }
}
