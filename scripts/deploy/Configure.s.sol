// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Contracts
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Registry} from "../../contracts/Registry.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter, Asset} from "../../contracts/payments/PaymentAdapter.sol";

// Config
import {DeployConfig} from "./config/DeployConfig.sol";
import {DeploymentRecord} from "./config/DeploymentRecord.sol";

/// @notice Wires the deployed contracts to each other and sets the price ceiling
/// @dev Run after `Deploy.s.sol` and before `TransferOwnership.s.sol`. Every call here is owner
///      gated, and the deployer is still the owner at this point, so none of them waits on the
///      timelock. After the handover each of them would be a scheduled operation.
///
///      The three wiring calls exist because the dependency between the registry and the two
///      factories is circular: both factories are constructor arguments to the registry, and the
///      registry cannot be an argument to either of them. There is no ordering that removes this
///      step.
///
///      Every step checks whether it has already been done and skips it if so. Both
///      `addRegistryAddress` functions revert once set, so without that a single failed
///      transaction would leave this script unable to finish the run it started.
contract Configure is Script {

    /// @notice Symbol the protocol prices fiat payments in
    /// @dev No token address, so nothing can be transferred in it. It exists so a purchase settled
    ///      in cash or on a card has a currency to be recorded against.
    bytes32 private constant ASSET_USD = bytes32("USD");

    /// @notice Symbol the settlement token is registered under
    bytes32 private constant ASSET_USDC = bytes32("USDC");

    /// @notice Decimals a fiat dollar is expressed in, which is cents
    uint8 private constant USD_DECIMALS = 2;

    /// @notice A wiring call did not take effect
    error NotWired(string what, address expected, address actual);

    /// @notice The registry is already bound to a different address than the one recorded
    error BoundElsewhere(string what, address recorded, address bound);

    /// @notice A currency is registered against a different token than the one configured
    error AssetBoundElsewhere(bytes32 symbol, address expected, address actual);

    /// @notice The settlement token address holds no code on this chain
    error SettlementTokenNotDeployed(address token, uint256 chainId);

    /// @notice The settlement token did not answer `decimals()`
    error SettlementTokenNotTokenLike(address token);

    /// @notice Wires the protocol together and records that it is configured
    /// @dev Broadcasts as the deployer, which is still the owner of all four singletons.
    function run() external {
        DeployConfig.Config memory config = DeployConfig.load();

        address registryAddress = DeploymentRecord.readAddress("RegistryProxy");
        address lazyWalletRegistry = DeploymentRecord.readAddress("LazyWalletRegistryProxy");
        address deviceWalletFactory = DeploymentRecord.readAddress("DeviceWalletFactoryProxy");
        address eSIMWalletFactory = DeploymentRecord.readAddress("ESIMWalletFactoryProxy");
        address paymentAdapter = DeploymentRecord.readAddress("PaymentAdapterProxy");

        // Read before anything is broadcast. The settlement token address is per chain, and the
        // one for the wrong chain can still hold code, so asking it for its decimals is what tells
        // the two apart.
        uint8 settlementDecimals = _settlementTokenDecimals(config.settlementToken);

        vm.startBroadcast(config.deployerPrivateKey);

        _bindRegistryToFactory("DeviceWalletFactory", deviceWalletFactory, registryAddress);
        _bindRegistryToFactory("ESIMWalletFactory", eSIMWalletFactory, registryAddress);
        _bindLazyWalletRegistry(registryAddress, lazyWalletRegistry);
        _setPriceCap(registryAddress, config.priceCapUSDCents);
        _registerCurrencies(paymentAdapter, config.settlementToken, settlementDecimals);

        vm.stopBroadcast();

        _verify(registryAddress, lazyWalletRegistry, deviceWalletFactory, eSIMWalletFactory);
        _verifyCurrencies(paymentAdapter, config.settlementToken);
        DeploymentRecord.writeStatus("configured", true);

        console.log("");
        console.log("Configured. Next: TransferOwnership.s.sol.");
    }

    /// @notice Points a factory at the registry, unless it already is
    /// @dev Both factories store the registry as `Registry public registry` and both refuse a
    ///      second write, so a factory already bound to the right address is a finished step and a
    ///      factory bound to a different one is a mismatch nothing here can fix.
    function _bindRegistryToFactory(string memory name, address factory, address registryAddress)
        private
    {
        // Both factories declare the same getter, so either type reads the other correctly.
        address bound = address(DeviceWalletFactory(factory).registry());

        if(bound == registryAddress) {
            console.log(string.concat(name, ": already bound, skipping"));
            return;
        }
        if(bound != address(0)) revert BoundElsewhere(name, registryAddress, bound);

        DeviceWalletFactory(factory).addRegistryAddress(registryAddress);
        console.log(string.concat(name, ": bound to registry"));
    }

    /// @notice Tells the registry where the lazy wallet registry lives
    /// @dev This one is an update rather than a one-time set, so re-running it is harmless. It is
    ///      still skipped when already correct, to keep a resumed run from spending gas on nothing.
    function _bindLazyWalletRegistry(address registryAddress, address lazyWalletRegistry) private {
        if(Registry(registryAddress).lazyWalletRegistry() == lazyWalletRegistry) {
            console.log("Registry: lazy wallet registry already set, skipping");
            return;
        }

        Registry(registryAddress).addOrUpdateLazyWalletRegistryAddress(lazyWalletRegistry);
        console.log("Registry: lazy wallet registry set");
    }

    /// @notice Rotates the fallback ceiling on what an eSIM wallet may be charged for a data bundle
    /// @dev `Registry.initialize` already required a non-zero cap, so this only ever handles a
    ///      later change to it. Zero is not a legal configuration at any point after deployment
    ///      either: `setDefaultPriceCapUSDCents` refuses it the same way `initialize` does.
    function _setPriceCap(address registryAddress, uint64 cap) private {
        if(Registry(registryAddress).defaultPriceCapUSDCents() == cap) {
            console.log("Registry: price cap already set, skipping");
            return;
        }

        Registry(registryAddress).setDefaultPriceCapUSDCents(cap);
        console.log("Registry: price cap set to", cap);
    }

    /// @notice The settlement token's own decimals, checked to be a token at all
    /// @dev Read from the token rather than assumed to be six. USDC is at a different address on
    ///      every chain and the address for the wrong one can still hold code, so a copied value
    ///      has to fail here rather than register a currency nothing can be paid in. Runs before
    ///      the broadcast, since a revert inside one leaves the earlier calls of the run sent.
    function _settlementTokenDecimals(address token) private view returns (uint8) {
        if(token.code.length == 0) revert SettlementTokenNotDeployed(token, block.chainid);

        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            revert SettlementTokenNotTokenLike(token);
        }
    }

    /// @notice Puts the two currencies the protocol prices in into the adapter's table
    /// @dev An adapter with an empty table prices nothing, so every purchase on both paths reverts
    ///      until this has run. USD carries no token address: a fiat payment happens somewhere the
    ///      contracts cannot see, and the entry exists only to record what it was priced in.
    function _registerCurrencies(address paymentAdapter, address settlementToken, uint8 settlementDecimals)
        private
    {
        _registerCurrency(paymentAdapter, ASSET_USD, Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: USD_DECIMALS,
            token: address(0)
        }));

        _registerCurrency(paymentAdapter, ASSET_USDC, Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: settlementDecimals,
            token: settlementToken
        }));
    }

    /// @notice Adds one currency, unless it is already there
    /// @dev `registerAsset` refuses a symbol already in the table, so a re-run after a partial one
    ///      has to skip rather than call it again. A symbol registered against a different token is
    ///      a mismatch this script must not paper over: `updateAsset` would change the address
    ///      every future payment is recorded into.
    function _registerCurrency(address paymentAdapter, bytes32 symbol, Asset memory asset) private {
        (bool allowed,, uint8 decimals, address token) = PaymentAdapter(paymentAdapter).assets(symbol);

        if(decimals != 0) {
            if(token != asset.token) revert AssetBoundElsewhere(symbol, asset.token, token);

            console.log(string.concat("PaymentAdapter: ", _symbolName(symbol), " already registered, skipping"));
            if(!allowed) console.log("  warning: it is registered but withdrawn");
            return;
        }

        PaymentAdapter(paymentAdapter).registerAsset(symbol, asset);
        console.log(string.concat("PaymentAdapter: ", _symbolName(symbol), " registered"), asset.decimals);
    }

    /// @notice Reads the currency table back out of the adapter
    function _verifyCurrencies(address paymentAdapter, address settlementToken) private view {
        (bool usdAllowed,,, address usdToken) = PaymentAdapter(paymentAdapter).assets(ASSET_USD);
        if(!usdAllowed || usdToken != address(0)) {
            revert NotWired("PaymentAdapter.assets(USD)", address(0), usdToken);
        }

        (bool usdcAllowed,,, address usdcToken) = PaymentAdapter(paymentAdapter).assets(ASSET_USDC);
        if(!usdcAllowed || usdcToken != settlementToken) {
            revert NotWired("PaymentAdapter.assets(USDC)", settlementToken, usdcToken);
        }
    }

    /// @notice The trailing zero bytes trimmed off a symbol, so it prints readably
    function _symbolName(bytes32 symbol) private pure returns (string memory) {
        uint256 length;
        while(length < 32 && symbol[length] != 0) ++length;

        bytes memory trimmed = new bytes(length);
        for(uint256 i = 0; i < length; ++i) trimmed[i] = symbol[i];

        return string(trimmed);
    }

    /// @notice Reads every wiring back out of the contracts that hold it
    function _verify(
        address registryAddress,
        address lazyWalletRegistry,
        address deviceWalletFactory,
        address eSIMWalletFactory
    ) private view {
        address boundOnDevice = address(DeviceWalletFactory(deviceWalletFactory).registry());
        if(boundOnDevice != registryAddress) {
            revert NotWired("DeviceWalletFactory.registry", registryAddress, boundOnDevice);
        }

        address boundOnESIM = address(ESIMWalletFactory(eSIMWalletFactory).registry());
        if(boundOnESIM != registryAddress) {
            revert NotWired("ESIMWalletFactory.registry", registryAddress, boundOnESIM);
        }

        address boundLazy = Registry(registryAddress).lazyWalletRegistry();
        if(boundLazy != lazyWalletRegistry) {
            revert NotWired("Registry.lazyWalletRegistry", lazyWalletRegistry, boundLazy);
        }
    }
}
