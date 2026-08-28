// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import "contracts/CustomStructs.sol";
import {P256Verifier} from "contracts/P256Verifier.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter, Asset} from "contracts/payments/PaymentAdapter.sol";

import "test/utils/mocks/MockEntryPoint.sol";
import "test/utils/mocks/MockRegistry.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice Deploys the whole protocol once for an invariant campaign to run against.
/// @dev Deliberately not a subclass of `DeployerBase`. That base carries the fixture arrays every
///      unit test shares, and it starts every test from the same five-device layout. A campaign
///      needs an empty world it can build up itself, so the deployment is repeated here without
///      the fixtures.
///
///      The entry point is the mock. The real one from `lib/account-abstraction` imports
///      `ReentrancyGuardTransient`, which OpenZeppelin added in 5.1 and this repo does not carry.
///      That costs the campaign nothing: no invariant routed here reads `getUserOpHash`, since
///      every signature invariant is deferred to a unit or fork test, and the mock's deposit
///      accounting keeps ETH inside itself, so the conservation invariants still balance.
///
///      The four wallet and registry contracts are the `Mock` subclasses. Those add view
///      helpers to the real contracts and override nothing, so what runs is production logic.
contract InvariantBase is Test {

    address internal constant ADMIN = address(0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db);
    address internal constant UPGRADE_MANAGER = address(0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2);
    address internal constant VAULT = address(0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB);
    address internal constant ATTACKER = address(0xbADc0DE000000000000000000000000000000001);
    uint64 internal constant DEFAULT_PRICE_CAP_USD_CENTS = 100_000;   // $1000

    /// @dev A stand-in for USDC. Nothing settles onchain yet, so it only has to be resolvable.
    address internal constant SETTLEMENT_TOKEN = address(0x036CbD53842c5426634e7929541eC2318f3dCF7e);

    /// @notice The address the admin role rotates onto, and back off
    /// @dev Carries a budget of its own. Every admin path reads the role out of the registry, so
    ///      once the role moves the successor is the one paying for deposits, and an unfunded
    ///      successor would turn every remaining admin deploy into a zero-value one.
    address internal constant ADMIN_SUCCESSOR =
        address(0xaDD1E55000000000000000000000000000000001);

    MockEntryPoint internal entryPoint;
    P256Verifier internal p256Verifier;

    MockDeviceWallet internal deviceWalletImpl;
    MockESIMWallet internal eSIMWalletImpl;

    DeviceWalletFactory internal deviceWalletFactory;
    ESIMWalletFactory internal eSIMWalletFactory;
    MockRegistry internal registry;
    MockLazyWalletRegistry internal lazyWalletRegistry;
    PaymentAdapter internal paymentAdapter;

    /// @notice Deploys the system in the same order the deploy script does
    function _deployProtocol() internal {
        entryPoint = new MockEntryPoint();
        p256Verifier = new P256Verifier();

        eSIMWalletImpl = new MockESIMWallet();

        ESIMWalletFactory eSIMWalletFactoryImpl = new ESIMWalletFactory();
        ERC1967Proxy eSIMWalletFactoryProxy = new ERC1967Proxy(
            address(eSIMWalletFactoryImpl),
            abi.encodeCall(eSIMWalletFactoryImpl.initialize, (address(eSIMWalletImpl), UPGRADE_MANAGER))
        );
        eSIMWalletFactory = ESIMWalletFactory(address(eSIMWalletFactoryProxy));

        deviceWalletImpl = new MockDeviceWallet(IEntryPoint(address(entryPoint)), p256Verifier);

        DeviceWalletFactory deviceWalletFactoryImpl = new DeviceWalletFactory();
        ERC1967Proxy deviceWalletFactoryProxy = new ERC1967Proxy(
            address(deviceWalletFactoryImpl),
            abi.encodeCall(
                deviceWalletFactoryImpl.initialize,
                (
                    address(deviceWalletImpl),
                    UPGRADE_MANAGER,
                    address(eSIMWalletFactory),
                    IEntryPoint(address(entryPoint)),
                    p256Verifier
                )
            )
        );
        deviceWalletFactory = DeviceWalletFactory(address(deviceWalletFactoryProxy));

        MockRegistry registryImpl = new MockRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                registryImpl.initialize,
                (
                    ADMIN,
                    VAULT,
                    UPGRADE_MANAGER,
                    address(deviceWalletFactory),
                    address(eSIMWalletFactory),
                    IEntryPoint(address(entryPoint)),
                    DEFAULT_PRICE_CAP_USD_CENTS
                )
            )
        );
        registry = MockRegistry(address(registryProxy));

        MockLazyWalletRegistry lazyWalletRegistryImpl = new MockLazyWalletRegistry();
        ERC1967Proxy lazyWalletRegistryProxy = new ERC1967Proxy(
            address(lazyWalletRegistryImpl),
            abi.encodeCall(lazyWalletRegistryImpl.initialize, (address(registry), UPGRADE_MANAGER))
        );
        lazyWalletRegistry = MockLazyWalletRegistry(address(lazyWalletRegistryProxy));

        PaymentAdapter paymentAdapterImpl = new PaymentAdapter();
        ERC1967Proxy paymentAdapterProxy = new ERC1967Proxy(
            address(paymentAdapterImpl),
            abi.encodeCall(
                paymentAdapterImpl.initialize,
                (address(registry), SETTLEMENT_TOKEN, UPGRADE_MANAGER)
            )
        );
        paymentAdapter = PaymentAdapter(address(paymentAdapterProxy));

        vm.startPrank(UPGRADE_MANAGER);
        registry.addOrUpdateLazyWalletRegistryAddress(address(lazyWalletRegistry));
        registry.setPaymentAdapter(address(paymentAdapter));
        // Every purchase spends a payment reference through the adapter, so with no currencies
        // registered a campaign would see all of them revert before reaching anything else.
        paymentAdapter.registerAsset("USD", Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: 2,
            token: address(0)
        }));
        deviceWalletFactory.addRegistryAddress(address(registry));
        eSIMWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }
}
