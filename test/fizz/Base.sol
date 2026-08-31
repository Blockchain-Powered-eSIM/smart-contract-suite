// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";

import {Asset} from "contracts/payments/PaymentAdapter.sol";
import {DataBundleDetails, Settlement, Wallets} from "contracts/CustomStructs.sol";
import {P256Verifier} from "contracts/P256Verifier.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter} from "contracts/payments/PaymentAdapter.sol";

import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockEntryPoint} from "test/utils/mocks/MockEntryPoint.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";
import {MockLazyWalletRegistry} from "test/utils/mocks/MockLazyWalletRegistry.sol";
import {MockRegistry} from "test/utils/mocks/MockRegistry.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";

/// @notice Base contract with state variables and setup functions
/// @dev The `Mock*` contracts are the repo's own view-exposing subclasses of the real ones, not
///      substitutes for them. They add getters for `transactionHistory` and the string-keyed lazy
///      mappings, which have no public accessor and which the properties have to read.
///      `MockEntryPoint` is the one genuine stand-in, because the real singleton is not deployed in
///      a fuzz environment and no property here depends on its accounting.
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;

    // ―――――――――――――――――――――――― Protocol constants ―――――――――――――――――――――――

    uint8 internal constant SETTLEMENT_DECIMALS = 6;
    bytes32 internal constant ASSET_USDC = bytes32("USDC");
    bytes32 internal constant ASSET_USD = bytes32("USD");
    bytes32 internal constant ASSET_ETH = bytes32("ETH");

    /// @dev $1000. Matches the unit suite so a price that trips the ceiling here trips it there.
    uint64 internal constant DEFAULT_PRICE_CAP_CENTS = 100_000;

    /// @dev Enough settlement token that no run ends because a wallet went broke, and small enough
    ///      that the balance still moves visibly when a purchase lands.
    uint256 internal constant INITIAL_TOKEN_BALANCE = 1_000_000 * 10 ** 6;

    /// @dev How many device wallets the run starts with. Handlers deploy more; this is only so the
    ///      first call already has somewhere to land instead of spending the early sequence
    ///      building a population.
    uint256 internal constant BOOTSTRAP_DEVICE_WALLETS = 3;

    /// @notice How many identifiers the two deployment routes are made to contend over
    /// @dev Small on purpose. Each route generates identifiers in its own namespace, so without a
    ///      shared pool a cross-route property would hold over a state no sequence ever reaches.
    uint256 internal constant CONTESTED_IDENTIFIERS = 8;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    /// @dev Only what a property cannot read back off the protocol. Everything else is read live,
    ///      because a mirror that drifts is a false alarm rather than a finding.
    struct Ghosts {
        // GL-01: what each eSIM wallet's history looked like the last time it was read. An entry
        // once seen must still hash the same, which is the only way a rewritten entry shows up.
        mapping(address eSIMWallet => uint256 length) historyLength;
        mapping(address eSIMWallet => mapping(uint256 index => bytes32 digest)) historyEntry;
        // GL-02, GL-03: last reading of each cursor, so a decrease is visible
        mapping(string identifier => uint256 copied) lastCopied;
        mapping(string identifier => uint256 deployed) lastDeployed;
        // GL-04: the identifier list length at the moment the device first had a wallet
        mapping(string identifier => bool frozen) listFrozen;
        mapping(string identifier => uint256 length) frozenLength;
        // GL-05, GL-14: latches that must never fall back
        mapping(address wallet => bool seen) everRegisteredESIM;
        mapping(address wallet => bool seen) everValidDevice;
        mapping(address wallet => bool seen) everDeployedESIM;
        mapping(address adapter => mapping(bytes32 symbol => bool seen)) everRegisteredAsset;
        // GL-06: every reference the campaign has spent, so the latch can be re-read
        bytes32[] spentReferences;
        mapping(bytes32 scopedReference => bool recorded) referenceRecorded;
        // GL-13: purchases that actually moved money, counted at the one call site that can
        mapping(address eSIMWallet => uint256 count) witnessedPurchases;
        // Set by a handler when a call the protocol should have refused went through anyway.
        // Held in ghost state rather than asserted inline: an assertion inside a handler body
        // reverts the call, and a reverted call is discarded rather than reported.
        bool unauthorizedBind;
        bool unauthorizedStandby;
        bool unauthorizedPull;
        bool unauthorizedForeignDeploy;
        bool pausedCallSucceeded;
        // Set when a purchase went through priced above the ceiling in force at that moment. Read
        // at write time because a later reduction of the cap does not make an earlier purchase
        // illegal, and comparing history against today's cap would report every one of them.
        bool purchaseAboveCap;
    }

    Ghosts internal ghosts;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    /// @dev The roles the protocol actually distinguishes. Device wallets are contracts rather than
    ///      keys, so they are tracked separately in `deviceWallets` below.
    address internal upgradeManager;
    address internal adminSuccessor;
    address internal vault;

    modifier asActor() {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    /// @dev Reads the admin out of the registry rather than using the address set at deployment.
    ///      Every admin check in the protocol resolves through that one field, so a handler holding
    ///      its own copy would go on impersonating an address the protocol already demoted, and
    ///      every admin path would sit dead for the rest of the run after one rotation.
    modifier asAdmin() {
        vm.startPrank(registry.eSIMWalletAdmin());
        _;
        vm.stopPrank();
    }

    modifier asOwner() {
        vm.startPrank(upgradeManager);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    MockEntryPoint internal entryPoint;
    P256Verifier internal p256Verifier;
    MockRegistry internal registry;
    MockLazyWalletRegistry internal lazyWalletRegistry;
    DeviceWalletFactory internal deviceWalletFactory;
    ESIMWalletFactory internal eSIMWalletFactory;
    PaymentAdapter internal paymentAdapter;
    MockERC20 internal settlementERC20;
    address internal settlementToken;

    /// @dev Valid alternatives the config handlers swap to, rather than an address off the fuzzer.
    ///      A random pointer here would brick every later purchase and the run would spend the rest
    ///      of its budget reverting. Rotating the adapter is also the one shape that shows whether
    ///      spent payment references survive a swap, which they only do because the store moved to
    ///      the registry.
    PaymentAdapter internal spareAdapter;
    address internal spareVault;
    address internal spareDeviceWalletImpl;
    address internal spareESIMWalletImpl;

    // ―――――――――――――――――――― Deployed entity registry ――――――――――――――――――――

    /// @dev What the campaign has built. Handlers index into these rather than inventing addresses,
    ///      because every gated call needs a caller the protocol already recognises.
    address[] internal deviceWallets;
    address[] internal eSIMWallets;

    /// @dev Identifiers already handed out, so a handler wanting a fresh one does not have to
    ///      guess. Reused deliberately when a test of the duplicate guards is what is wanted.
    mapping(string => bool) internal deviceIdentifierUsed;

    uint256 internal saltNonce;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        upgradeManager = address(uint160(uint256(keccak256("fizz.upgradeManager"))));
        admin = address(uint160(uint256(keccak256("fizz.eSIMWalletAdmin"))));
        adminSuccessor = address(uint160(uint256(keccak256("fizz.adminSuccessor"))));
        vault = address(uint160(uint256(keccak256("fizz.vault"))));

        vm.label(upgradeManager, "UpgradeManager");
        vm.label(admin, "ESIMWalletAdmin");
        vm.label(adminSuccessor, "AdminSuccessor");
        vm.label(vault, "Vault");

        deployProtocol();
        setupActors();
        bootstrapWallets();
    }

    /// @notice Deploys the five singletons behind proxies and wires them to each other
    /// @dev Deployment order follows the one the deploy scripts use: both factories first, because
    ///      the registry initializer takes their addresses, then the registry, then the two
    ///      contracts that take the registry's.
    function deployProtocol() internal {
        entryPoint = new MockEntryPoint();
        p256Verifier = new P256Verifier();

        MockESIMWallet eSIMWalletImpl = new MockESIMWallet();
        ESIMWalletFactory eSIMWalletFactoryImpl = new ESIMWalletFactory();
        eSIMWalletFactory = ESIMWalletFactory(
            address(
                new ERC1967Proxy(
                    address(eSIMWalletFactoryImpl),
                    abi.encodeCall(eSIMWalletFactoryImpl.initialize, (address(eSIMWalletImpl), upgradeManager))
                )
            )
        );

        MockDeviceWallet deviceWalletImpl = new MockDeviceWallet(IEntryPoint(address(entryPoint)), p256Verifier);
        DeviceWalletFactory deviceWalletFactoryImpl = new DeviceWalletFactory();
        deviceWalletFactory = DeviceWalletFactory(
            address(
                new ERC1967Proxy(
                    address(deviceWalletFactoryImpl),
                    abi.encodeCall(
                        deviceWalletFactoryImpl.initialize,
                        (
                            address(deviceWalletImpl),
                            upgradeManager,
                            address(eSIMWalletFactory),
                            IEntryPoint(address(entryPoint)),
                            p256Verifier
                        )
                    )
                )
            )
        );

        MockRegistry registryImpl = new MockRegistry();
        registry = MockRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImpl),
                    abi.encodeCall(
                        registryImpl.initialize,
                        (
                            admin,
                            vault,
                            upgradeManager,
                            address(deviceWalletFactory),
                            address(eSIMWalletFactory),
                            IEntryPoint(address(entryPoint)),
                            DEFAULT_PRICE_CAP_CENTS
                        )
                    )
                )
            )
        );

        MockLazyWalletRegistry lazyImpl = new MockLazyWalletRegistry();
        lazyWalletRegistry = MockLazyWalletRegistry(
            address(
                new ERC1967Proxy(
                    address(lazyImpl),
                    abi.encodeCall(lazyImpl.initialize, (address(registry), upgradeManager))
                )
            )
        );

        settlementERC20 = new MockERC20("USD Coin", "USDC", SETTLEMENT_DECIMALS);
        settlementToken = address(settlementERC20);

        PaymentAdapter paymentAdapterImpl = new PaymentAdapter();
        paymentAdapter = PaymentAdapter(
            address(
                new ERC1967Proxy(
                    address(paymentAdapterImpl),
                    abi.encodeCall(paymentAdapterImpl.initialize, (address(registry), settlementToken, upgradeManager))
                )
            )
        );

        spareAdapter = PaymentAdapter(
            address(
                new ERC1967Proxy(
                    address(paymentAdapterImpl),
                    abi.encodeCall(paymentAdapterImpl.initialize, (address(registry), settlementToken, upgradeManager))
                )
            )
        );
        spareVault = address(uint160(uint256(keccak256("fizz.spareVault"))));
        spareDeviceWalletImpl = address(new MockDeviceWallet(IEntryPoint(address(entryPoint)), p256Verifier));
        spareESIMWalletImpl = address(new MockESIMWallet());

        vm.startPrank(upgradeManager);
        registry.addOrUpdateLazyWalletRegistryAddress(address(lazyWalletRegistry));
        registry.setPaymentAdapter(address(paymentAdapter));
        deviceWalletFactory.addRegistryAddress(address(registry));
        eSIMWalletFactory.addRegistryAddress(address(registry));
        registerDefaultAssets();
        registerDefaultAssetsOn(spareAdapter);
        vm.stopPrank();

        vm.label(address(registry), "Registry");
        vm.label(address(lazyWalletRegistry), "LazyWalletRegistry");
        vm.label(address(deviceWalletFactory), "DeviceWalletFactory");
        vm.label(address(eSIMWalletFactory), "ESIMWalletFactory");
        vm.label(address(paymentAdapter), "PaymentAdapter");
        vm.label(settlementToken, "USDC");
    }

    /// @notice Registers the three currencies the harness prices in
    /// @dev Only USDC can actually move: USD has no token address, and ETH is allowed but is not
    ///      priced in dollars, which is the case `quote` has to refuse. Keeping all three registered
    ///      means the fuzzer reaches both refusals without needing to guess an unregistered symbol.
    function registerDefaultAssets() internal {
        registerDefaultAssetsOn(paymentAdapter);
    }

    function registerDefaultAssetsOn(PaymentAdapter adapter) internal {
        adapter.registerAsset(
            ASSET_USDC,
            Asset({allowed: true, isDollarUnit: true, decimals: SETTLEMENT_DECIMALS, token: settlementToken})
        );
        adapter.registerAsset(ASSET_USD, Asset({allowed: true, isDollarUnit: true, decimals: 2, token: address(0)}));
        adapter.registerAsset(ASSET_ETH, Asset({allowed: true, isDollarUnit: false, decimals: 18, token: address(0)}));
    }

    /// @notice Whichever adapter the registry currently points at
    /// @dev Read live for the same reason the admin is: the config handlers rotate it, and a
    ///      handler holding its own copy would keep funding an adapter nothing settles through.
    function _activeAdapter() internal view returns (PaymentAdapter) {
        return PaymentAdapter(registry.paymentAdapter());
    }

    function setupActors() internal {
        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            vm.label(_actor, ACTOR_LABELS[i]);
            settlementERC20.mint(_actor, INITIAL_TOKEN_BALANCE);
        }
        actor = actors[0];

        vm.deal(admin, INITIAL_ETH_BALANCE);
        vm.deal(upgradeManager, INITIAL_ETH_BALANCE);
        vm.deal(adminSuccessor, INITIAL_ETH_BALANCE);
    }

    /// @notice Deploys the starting population of device wallets, each with one eSIM wallet
    /// @dev Through the admin batch route, which is the same path a handler uses, so the starting
    ///      state is one the protocol could have reached on its own. Funds access is granted to the
    ///      eSIM wallet here because it is owner-signed in production and no fuzzer input can
    ///      produce that signature; without it every purchase needing a pull would revert.
    function bootstrapWallets() internal {
        for (uint256 i; i < BOOTSTRAP_DEVICE_WALLETS; ++i) {
            string[] memory identifiers = new string[](1);
            bytes32[2][] memory keys = new bytes32[2][](1);
            uint256[] memory salts = new uint256[](1);
            uint256[] memory deposits = new uint256[](1);

            identifiers[0] = string(abi.encodePacked("BOOT", toString(i)));
            keys[0] = _ownerKey(i + 1);
            salts[0] = ++saltNonce;
            deposits[0] = 10 ether;

            vm.deal(admin, admin.balance + 10 ether);
            vm.prank(admin);
            Wallets[] memory deployed =
                deviceWalletFactory.deployDeviceWalletForUsers{value: 10 ether}(identifiers, keys, salts, deposits);

            deviceIdentifierUsed[identifiers[0]] = true;
            _trackDeviceWallet(deployed[0].deviceWallet);
            _trackESIMWallet(deployed[0].eSIMWallet);

            settlementERC20.mint(deployed[0].deviceWallet, INITIAL_TOKEN_BALANCE);
            settlementERC20.mint(deployed[0].eSIMWallet, INITIAL_TOKEN_BALANCE);

            vm.prank(deployed[0].deviceWallet);
            MockDeviceWallet(payable(deployed[0].deviceWallet)).toggleAccessToFunds(deployed[0].eSIMWallet, true);
        }
    }

    // ――――――――――――――――――――――― Entity tracking ―――――――――――――――――――――――

    /// @dev Only what the factory derived and deployed, for the same reason as `_trackESIMWallet`.
    function _trackDeviceWallet(address wallet) internal {
        if (wallet == address(0) || wallet.code.length == 0) return;
        deviceWallets.push(wallet);
        vm.label(wallet, string(abi.encodePacked("DeviceWallet", toString(deviceWallets.length))));
    }

    /// @dev Only what the factory says it deployed. The unclamped handlers take an address off the
    ///      fuzzer, so without this an address that merely returned something gets into the list the
    ///      global properties walk, and every one of them then reports on a contract that is not an
    ///      eSIM wallet at all.
    function _trackESIMWallet(address wallet) internal {
        if (wallet == address(0)) return;
        if (!eSIMWalletFactory.isESIMWalletDeployed(wallet)) return;
        eSIMWallets.push(wallet);
        vm.label(wallet, string(abi.encodePacked("ESIMWallet", toString(eSIMWallets.length))));
    }

    /// @notice Picks a device wallet the campaign has deployed, or zero when none exists yet
    function _pickDeviceWallet(uint256 seed) internal view returns (address) {
        if (deviceWallets.length == 0) return address(0);
        return deviceWallets[seed % deviceWallets.length];
    }

    /// @notice Picks an eSIM wallet the campaign has deployed, or zero when none exists yet
    function _pickESIMWallet(uint256 seed) internal view returns (address) {
        if (eSIMWallets.length == 0) return address(0);
        return eSIMWallets[seed % eSIMWallets.length];
    }

    /// @notice An eSIM wallet together with whichever device wallet currently owns it
    /// @dev Ownership moves during a run, so the pair has to be read rather than remembered. A
    ///      handler pranking the wallet that used to own one is refused on every gated call.
    function _pickOwnedPair(uint256 seed) internal view returns (address eSIMWallet, address deviceWallet) {
        uint256 count = eSIMWallets.length;
        if (count == 0) return (address(0), address(0));

        for (uint256 i; i < count; ++i) {
            address candidate = eSIMWallets[(seed + i) % count];
            address owner = MockESIMWallet(payable(candidate)).owner();
            if (registry.isDeviceWalletValid(owner)) return (candidate, owner);
        }
        return (address(0), address(0));
    }

    // ――――――――――――――――――――――― Identifier helpers ―――――――――――――――――――――――

    /// @notice A device identifier for the ordinary deploy route
    function _deviceIdentifier(uint256 seed) internal pure returns (string memory) {
        return string(abi.encodePacked("D", toString(seed % 1_000_000)));
    }

    /// @notice A device identifier for the lazy route, in its own namespace
    function _lazyDeviceIdentifier(uint256 seed) internal pure returns (string memory) {
        return string(abi.encodePacked("L", toString(seed % 1_000_000)));
    }

    /// @notice An eSIM identifier for the lazy route
    function _lazyESIMIdentifier(uint256 seed) internal pure returns (string memory) {
        return string(abi.encodePacked("E", toString(seed % 1_000_000)));
    }

    /// @notice An eSIM identifier for the ordinary route
    function _ordinaryESIMIdentifier(uint256 seed) internal pure returns (string memory) {
        return string(abi.encodePacked("O", toString(seed % 1_000_000)));
    }

    /// @notice A device identifier both routes draw from
    function _contestedDeviceIdentifier(uint256 seed) internal pure returns (string memory) {
        return string(abi.encodePacked("CD", toString(seed % CONTESTED_IDENTIFIERS)));
    }

    /// @notice An eSIM identifier both routes draw from
    function _contestedESIMIdentifier(uint256 seed) internal pure returns (string memory) {
        return string(abi.encodePacked("CE", toString(seed % CONTESTED_IDENTIFIERS)));
    }

    /// @notice How many lazy eSIM identifiers the handlers draw from
    uint256 internal constant LAZY_ESIM_IDENTIFIERS = 12;

    /// @notice How many lazy device identifiers the handlers draw from
    uint256 internal constant LAZY_DEVICE_IDENTIFIERS = 6;

    /// @notice Every device identifier the lazy route can reach
    /// @dev Built rather than tracked. The handlers draw from two fixed namespaces, so the whole
    ///      key space is known ahead of time and a property can walk it without the campaign having
    ///      to remember which ones it used. The string-keyed mappings have no other way to be
    ///      enumerated.
    function _allLazyDeviceIdentifiers() internal pure returns (string[] memory identifiers) {
        identifiers = new string[](LAZY_DEVICE_IDENTIFIERS + CONTESTED_IDENTIFIERS);
        for (uint256 i; i < LAZY_DEVICE_IDENTIFIERS; ++i) {
            identifiers[i] = _lazyDeviceIdentifier(i);
        }
        for (uint256 i; i < CONTESTED_IDENTIFIERS; ++i) {
            identifiers[LAZY_DEVICE_IDENTIFIERS + i] = _contestedDeviceIdentifier(i);
        }
    }

    /// @notice Every eSIM identifier the lazy route can reach
    function _allLazyESIMIdentifiers() internal pure returns (string[] memory identifiers) {
        identifiers = new string[](LAZY_ESIM_IDENTIFIERS + CONTESTED_IDENTIFIERS);
        for (uint256 i; i < LAZY_ESIM_IDENTIFIERS; ++i) {
            identifiers[i] = _lazyESIMIdentifier(i);
        }
        for (uint256 i; i < CONTESTED_IDENTIFIERS; ++i) {
            identifiers[LAZY_ESIM_IDENTIFIERS + i] = _contestedESIMIdentifier(i);
        }
    }

    /// @notice Every currency symbol the handlers can register
    function _allSymbols() internal pure returns (bytes32[] memory symbols) {
        symbols = new bytes32[](9);
        symbols[0] = ASSET_USDC;
        symbols[1] = ASSET_USD;
        symbols[2] = ASSET_ETH;
        for (uint256 i; i < 6; ++i) {
            symbols[3 + i] = bytes32(i + 1);
        }
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @notice A P256 public key that is genuinely on the curve
    /// @dev Every deploy path rejects an off-curve key, so a random pair would spend the whole run
    ///      being refused before reaching any state. Walking x upward until the curve equation has
    ///      a square root finds one in two tries on average.
    function _ownerKey(uint256 seed) internal view returns (bytes32[2] memory) {
        uint256 x = uint256(keccak256(abi.encode("fizz.ownerKey", seed)));
        for (uint256 i; i < 32; ++i) {
            uint256 y = FCL_Elliptic_ZZ.ec_Decompress(x, seed & 1);
            if (FCL_Elliptic_ZZ.ecAff_isOnCurve(x, y)) return [bytes32(x), bytes32(y)];
            unchecked {
                ++x;
            }
        }
        revert("no on-curve key found");
    }

    /// @notice What a price in cents costs in the settlement token's own units
    /// @dev Worked out here rather than read from `quote`, so a property comparing the two compares
    ///      the adapter against a second calculation instead of against itself.
    function _settlementAmount(uint64 priceUSDCents) internal pure returns (uint256) {
        return (uint256(priceUSDCents) * 10 ** SETTLEMENT_DECIMALS) / 100;
    }

    /// @notice One data bundle, priced under whichever ceiling currently applies
    function _bundle(uint256 idSeed, uint64 priceUSDCents) internal pure returns (DataBundleDetails memory) {
        return DataBundleDetails({
            id: keccak256(abi.encode("bundle", idSeed)),
            priceUSDCents: priceUSDCents,
            settlement: Settlement.Fiat
        });
    }

    /// @notice A payment reference derived from a seed
    /// @dev Drawn from a small space on purpose. References are spent once, so a reference the run
    ///      never repeats would leave the replay guard untested.
    function _paymentReference(uint256 seed) internal pure returns (bytes32) {
        return keccak256(abi.encode("ref", seed % 64));
    }

    /// @notice An eSIM wallet's owner, or zero when the address is not one
    /// @dev The unclamped handlers take an address straight off the fuzzer, and calling `owner()` on
    ///      something that is not a wallet reverts before the handler reaches the call it was
    ///      written to make.
    function _safeESIMOwner(address wallet) internal view returns (address) {
        if (wallet.code.length == 0) return address(0);
        try MockESIMWallet(payable(wallet)).owner() returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    /// @notice Whichever ceiling currently applies to a wallet, its own or the registry default
    /// @dev Tolerates an address that is not a wallet, because the unclamped handlers take one
    ///      straight off the fuzzer and read this before the call that would have refused it.
    function _effectiveCap(address eSIMWallet) internal view returns (uint256) {
        if (eSIMWallet.code.length == 0) return registry.defaultPriceCapUSDCents();

        try MockESIMWallet(payable(eSIMWallet)).priceCapUSDCents() returns (uint64 own) {
            return own == 0 ? registry.defaultPriceCapUSDCents() : own;
        } catch {
            return registry.defaultPriceCapUSDCents();
        }
    }

    /// @notice Records a payment reference the campaign has spent, so a property can re-read it
    function _recordSpentReference(address eSIMWallet, bytes32 paymentRef) internal {
        bytes32 scoped = keccak256(abi.encode(eSIMWallet, paymentRef));
        if (ghosts.referenceRecorded[scoped]) return;
        if (!registry.usedPaymentReferences(scoped)) return;

        ghosts.referenceRecorded[scoped] = true;
        ghosts.spentReferences.push(scoped);
    }

    /// @notice Caps a bound at what the account making the call can actually pay
    /// @dev The value on a pranked call comes out of the pranked account, not out of the harness,
    ///      so a ceiling taken from this contract's balance would run every call out of funds.
    function _spendable(address account, uint256 ceiling) internal view returns (uint256) {
        uint256 balance = account.balance;
        return balance < ceiling ? balance : ceiling;
    }

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
