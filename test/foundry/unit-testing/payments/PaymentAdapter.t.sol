// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Errors} from "contracts/Errors.sol";
import {PaymentAdapter, Asset} from "contracts/payments/PaymentAdapter.sol";

import "test/utils/DeployerBase.sol";

/// @notice Covers the currency table, the cent to token conversion, and the payment references.
/// @dev The adapter that `DeployerBase` deploys already carries USDC, USD and ETH, so the tests
///      below reuse those three rather than registering their own. USD is the 2-decimal fiat entry
///      and ETH is the entry `quote` has to refuse.
contract PaymentAdapterTest is DeployerBase {

    bytes32 constant ASSET_DAI = bytes32("DAI");
    bytes32 constant ASSET_TON = bytes32("TON");

    address daiToken = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    /// @notice A dollar-denominated entry with the given decimals
    function _dollarAsset(uint8 _decimals, address _token) internal pure returns (Asset memory) {
        return Asset({allowed: true, isDollarUnit: true, decimals: _decimals, token: _token});
    }

    /// @notice Spends a reference the way the registry does
    function _consumeAsRegistry(bytes32 _paymentReference) internal {
        vm.prank(address(registry));
        paymentAdapter.consumePaymentReference(_paymentReference);
    }

    /// @notice Reads one field back, since the public getter returns the struct flattened
    function _allowedOf(bytes32 _symbol) internal view returns (bool allowed) {
        (allowed,,,) = paymentAdapter.assets(_symbol);
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice The adapter knows the registry, the settlement token and its owner
    function test_initialize_storesTheAddressesItWasGiven() public view {
        assertEq(paymentAdapter.registry(), address(registry), "Registry address must be stored");
        assertEq(paymentAdapter.settlementToken(), settlementToken, "Settlement token must be stored");
        assertEq(paymentAdapter.owner(), upgradeManager, "Upgrade manager must own the adapter");
    }

    /// @notice The upgrade authority is read from the owner, not from a second copy
    function test_upgradeManager_matchesTheOwner() public view {
        assertEq(paymentAdapter.upgradeManager(), paymentAdapter.owner(), "Both must name one address");
    }

    /// @notice An adapter without a registry could never spend a reference
    function test_initialize_rejectsAZeroRegistry() public {
        PaymentAdapter implementation = new PaymentAdapter();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_registry"));
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(implementation.initialize, (address(0), settlementToken, upgradeManager))
        );
    }

    /// @notice The settlement token is fixed at initialisation, so a zero cannot be corrected later
    function test_initialize_rejectsAZeroSettlementToken() public {
        PaymentAdapter implementation = new PaymentAdapter();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_settlementToken"));
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(implementation.initialize, (address(registry), address(0), upgradeManager))
        );
    }

    /// @notice A zero owner would leave the currency table and the upgrade path both closed
    function test_initialize_rejectsAZeroUpgradeManager() public {
        PaymentAdapter implementation = new PaymentAdapter();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_upgradeManager"));
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(implementation.initialize, (address(registry), settlementToken, address(0)))
        );
    }

    /// @notice The live adapter cannot be initialised a second time
    function test_initialize_cannotRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        paymentAdapter.initialize(address(registry), settlementToken, upgradeManager);
    }

    /// @notice The implementation contract is locked, so nobody can own the address the proxy
    ///         delegates into
    function test_implementationCannotBeInitialized() public {
        PaymentAdapter implementation = new PaymentAdapter();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(registry), settlementToken, upgradeManager);

        assertEq(implementation.owner(), address(0), "Implementation must have no owner");
    }

    // ---------------------------------------------------------------------------------------------
    // Registering a currency
    // ---------------------------------------------------------------------------------------------

    /// @notice A new currency is stored and announced
    function test_registerAsset_storesTheEntry() public {
        vm.expectEmit(true, true, true, true);
        emit PaymentAdapter.AssetUpdated(ASSET_DAI, true, true, 18, daiToken);

        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(ASSET_DAI, _dollarAsset(18, daiToken));

        (bool allowed, bool isDollarUnit, uint8 decimals, address token) = paymentAdapter.assets(ASSET_DAI);
        assertTrue(allowed, "The new currency must be allowed");
        assertTrue(isDollarUnit, "The new currency must be marked as a dollar unit");
        assertEq(decimals, 18, "Decimals must be stored");
        assertEq(token, daiToken, "Token address must be stored");
    }

    /// @notice Only the owner adds currencies
    /// @dev The admin names the price on every purchase. One that could add a currency too would
    ///      be naming the token address it gets paid into.
    function test_registerAsset_rejectsTheAdmin() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin));
        paymentAdapter.registerAsset(ASSET_DAI, _dollarAsset(18, daiToken));
    }

    /// @notice A symbol already in the table cannot be registered over
    /// @dev Overwriting is `updateAsset`, so a typo cannot land on a currency already in use.
    function test_registerAsset_rejectsASymbolAlreadyRegistered() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetAlreadyRegistered.selector, ASSET_USDC));
        paymentAdapter.registerAsset(ASSET_USDC, _dollarAsset(6, settlementToken));
    }

    /// @notice An empty symbol is refused
    function test_registerAsset_rejectsAnEmptySymbol() public {
        vm.prank(upgradeManager);
        vm.expectRevert(Errors.EmptyAssetSymbol.selector);
        paymentAdapter.registerAsset(bytes32(0), _dollarAsset(6, settlementToken));
    }

    /// @notice Fewer than two decimals cannot carry a cent
    /// @dev `quote` divides by 100, so a one-decimal currency would round every price down to a
    ///      figure the user was never charged.
    function test_registerAsset_rejectsFewerThanTwoDecimals() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetDecimalsTooLow.selector, ASSET_DAI, uint8(1)));
        paymentAdapter.registerAsset(ASSET_DAI, _dollarAsset(1, daiToken));
    }

    /// @notice Zero decimals is refused for the same reason
    /// @dev Also the value that marks a symbol as unregistered, so accepting it would leave an
    ///      entry `updateAsset` could never reach.
    function test_registerAsset_rejectsZeroDecimals() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetDecimalsTooLow.selector, ASSET_DAI, uint8(0)));
        paymentAdapter.registerAsset(ASSET_DAI, _dollarAsset(0, daiToken));
    }

    // ---------------------------------------------------------------------------------------------
    // Changing a currency
    // ---------------------------------------------------------------------------------------------

    /// @notice An existing entry can be rewritten
    function test_updateAsset_rewritesTheEntry() public {
        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, _dollarAsset(18, daiToken));

        (,, uint8 decimals, address token) = paymentAdapter.assets(ASSET_USDC);
        assertEq(decimals, 18, "Decimals must be rewritten");
        assertEq(token, daiToken, "Token address must be rewritten");
    }

    /// @notice Withdrawing a currency leaves the entry in place with `allowed` false
    /// @dev Deleting it would set decimals back to zero, which reads as never registered, and
    ///      `registerAsset` would then accept the symbol again.
    function test_updateAsset_withdrawsACurrency() public {
        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: 6,
            token: settlementToken
        }));

        assertFalse(_allowedOf(ASSET_USDC), "The currency must no longer be allowed");

        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetAlreadyRegistered.selector, ASSET_USDC));
        paymentAdapter.registerAsset(ASSET_USDC, _dollarAsset(6, settlementToken));
    }

    /// @notice Only the owner changes currencies
    function test_updateAsset_rejectsTheAdmin() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin));
        paymentAdapter.updateAsset(ASSET_USDC, _dollarAsset(6, settlementToken));
    }

    /// @notice A symbol that was never registered cannot be updated
    function test_updateAsset_rejectsAnUnregisteredSymbol() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotRegistered.selector, ASSET_TON));
        paymentAdapter.updateAsset(ASSET_TON, _dollarAsset(9, address(0)));
    }

    /// @notice The decimals floor applies to a change as well as to a new entry
    function test_updateAsset_rejectsFewerThanTwoDecimals() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetDecimalsTooLow.selector, ASSET_USDC, uint8(1)));
        paymentAdapter.updateAsset(ASSET_USDC, _dollarAsset(1, settlementToken));
    }

    // ---------------------------------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------------------------------

    /// @notice A dollar in cents is a dollar in USDC
    function test_quote_convertsCentsToSixDecimals() public view {
        assertEq(paymentAdapter.quote(ASSET_USDC, 100), 1e6, "$1.00 must be 1 USDC");
    }

    /// @notice The smallest price the protocol can express survives the conversion
    function test_quote_keepsASingleCent() public view {
        assertEq(paymentAdapter.quote(ASSET_USDC, 1), 10_000, "One cent must be 0.01 USDC");
    }

    /// @notice A two-decimal fiat entry converts one to one
    function test_quote_convertsCentsToTwoDecimals() public view {
        assertEq(paymentAdapter.quote(ASSET_USD, 1234), 1234, "Cents and a 2-decimal unit are the same");
    }

    /// @notice Zero cents quotes zero rather than reverting
    /// @dev The zero price check belongs to the purchase paths, which reject it before quoting.
    function test_quote_returnsZeroForAZeroPrice() public view {
        assertEq(paymentAdapter.quote(ASSET_USDC, 0), 0, "Zero cents must quote zero");
    }

    /// @notice A currency the protocol does not know cannot be priced
    function test_quote_rejectsAnUnregisteredCurrency() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, ASSET_TON));
        paymentAdapter.quote(ASSET_TON, 100);
    }

    /// @notice A withdrawn currency stops quoting immediately
    function test_quote_rejectsAWithdrawnCurrency() public {
        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: 6,
            token: settlementToken
        }));

        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, ASSET_USDC));
        paymentAdapter.quote(ASSET_USDC, 100);
    }

    /// @notice A currency that is not already in dollars needs a rate this contract does not have
    function test_quote_rejectsACurrencyThatNeedsARate() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNeedsSwap.selector, ASSET_ETH));
        paymentAdapter.quote(ASSET_ETH, 100);
    }

    // ---------------------------------------------------------------------------------------------
    // Reading a currency back
    // ---------------------------------------------------------------------------------------------

    /// @notice Callers get the decimals and token address from the table, not from their own input
    function test_resolveAsset_returnsTheStoredEntry() public view {
        Asset memory asset = paymentAdapter.resolveAsset(ASSET_USDC);

        assertTrue(asset.allowed, "USDC must be allowed");
        assertTrue(asset.isDollarUnit, "USDC must be marked as a dollar unit");
        assertEq(asset.decimals, 6, "USDC must have six decimals");
        assertEq(asset.token, settlementToken, "USDC must carry its token address");
    }

    /// @notice A currency that needs a rate still resolves, since only pricing needs the rate
    function test_resolveAsset_returnsACurrencyThatNeedsARate() public view {
        Asset memory asset = paymentAdapter.resolveAsset(ASSET_ETH);

        assertFalse(asset.isDollarUnit, "ETH must not be marked as a dollar unit");
        assertEq(asset.decimals, 18, "ETH must have eighteen decimals");
    }

    /// @notice An unknown currency cannot be resolved
    function test_resolveAsset_rejectsAnUnregisteredCurrency() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, ASSET_TON));
        paymentAdapter.resolveAsset(ASSET_TON);
    }

    // ---------------------------------------------------------------------------------------------
    // Payment references
    // ---------------------------------------------------------------------------------------------

    /// @notice Spending a reference marks it and announces it
    function test_consumePaymentReference_marksTheReference() public {
        bytes32 orderRef = paymentRef("first-order");
        assertFalse(paymentAdapter.usedReferences(orderRef), "A fresh reference must be unspent");

        vm.expectEmit(true, true, true, true);
        emit PaymentAdapter.PaymentReferenceConsumed(orderRef);
        _consumeAsRegistry(orderRef);

        assertTrue(paymentAdapter.usedReferences(orderRef), "The reference must now be spent");
    }

    /// @notice The same reference cannot be spent twice
    /// @dev The backend retries the whole onchain step on any failure, so without this a retry of
    ///      a call that already landed would record the purchase a second time.
    function test_consumePaymentReference_rejectsAReferenceAlreadySpent() public {
        bytes32 orderRef = paymentRef("retried-order");
        _consumeAsRegistry(orderRef);

        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentReferenceAlreadyUsed.selector, orderRef));
        paymentAdapter.consumePaymentReference(orderRef);
    }

    /// @notice An empty reference is refused
    /// @dev It ties nothing to an offchain payment, and the first caller to pass one would close
    ///      the value for everyone after it.
    function test_consumePaymentReference_rejectsAnEmptyReference() public {
        vm.prank(address(registry));
        vm.expectRevert(Errors.EmptyPaymentReference.selector);
        paymentAdapter.consumePaymentReference(bytes32(0));
    }

    /// @notice Only the registry spends references
    /// @dev Both purchase paths go through the registry, so one reference cannot be spent once on
    ///      each of them.
    function test_consumePaymentReference_rejectsAnyoneButTheRegistry() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyRegistry.selector);
        paymentAdapter.consumePaymentReference(paymentRef("admin-order"));
    }

    /// @notice Not even the owner spends a reference
    function test_consumePaymentReference_rejectsTheOwner() public {
        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OnlyRegistry.selector);
        paymentAdapter.consumePaymentReference(paymentRef("owner-order"));
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Ownership cannot be given up
    /// @dev The owner is the only address that can change the currency table or upgrade this
    ///      contract, so renouncing would freeze both for good.
    function test_renounceOwnership_alwaysReverts() public {
        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OwnershipCannotBeRenounced.selector);
        paymentAdapter.renounceOwnership();
    }

    /// @notice Only the owner upgrades the adapter
    function test_upgrade_rejectsAnyoneButTheOwner() public {
        PaymentAdapter newImplementation = new PaymentAdapter();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin));
        UUPSUpgradeable(address(paymentAdapter)).upgradeToAndCall(address(newImplementation), "");
    }

    /// @notice An upgrade keeps the spent references
    /// @dev A fresh table would re-open every reference already spent, which is why this contract
    ///      is upgraded rather than replaced.
    function test_upgrade_keepsTheSpentReferences() public {
        bytes32 orderRef = paymentRef("pre-upgrade-order");
        _consumeAsRegistry(orderRef);

        PaymentAdapter newImplementation = new PaymentAdapter();

        vm.prank(upgradeManager);
        UUPSUpgradeable(address(paymentAdapter)).upgradeToAndCall(address(newImplementation), "");

        assertTrue(paymentAdapter.usedReferences(orderRef), "The reference must still read as spent");
    }
}
