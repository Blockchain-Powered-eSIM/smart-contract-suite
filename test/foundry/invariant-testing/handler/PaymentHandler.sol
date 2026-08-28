// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";
import {PaymentAdapter, Asset} from "contracts/payments/PaymentAdapter.sol";

import {HandlerBase, HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";

/// @notice Drives both payment paths and the currency table against one another.
/// @dev The two paths spend payment references through the same adapter but reach it by different
///      routes, one from the wallet and one from the admin, so whether a reference can be spent
///      twice is a question about the pair rather than about either one.
///
///      Ghost state sits on this handler rather than in `ProtocolState`, because this is the only
///      contract that writes it. A handler body that reverts takes its ghost writes with it, so a
///      reference is only counted once the spend it belongs to has actually landed.
contract PaymentHandler is HandlerBase {

    /// @notice How many payment references the run draws from
    /// @dev Small on purpose. Drawing from the whole `bytes32` space would never present the same
    ///      reference twice, and a second call on one already spent is the only case worth
    ///      catching here. At this size a sequence collides several times over.
    uint256 private constant REFERENCE_POOL = 128;

    /// @notice Decimals of the currency the token path settles in
    uint8 private constant SETTLEMENT_DECIMALS = 6;

    /// @notice Symbol the token path settles in
    bytes32 private constant SETTLEMENT_SYMBOL = bytes32("USDC");

    PaymentAdapter internal immutable paymentAdapter;
    MockERC20 internal immutable settlementERC20;

    bytes32[] internal symbols;

    /// @notice What every settled purchase should have moved to the vault, added up
    uint256 public ghost_settledToVault;

    /// @notice How many times each reference has been spent by a call that went through
    mapping(bytes32 paymentReference => uint256 spends) public ghost_spendCount;

    /// @notice Every reference a call has spent, listed once each
    bytes32[] public spentReferences;

    /// @notice Set when a reference was spent by a second call that went through
    bool public ghost_referenceSpentTwice;

    /// @notice Set when `quote` answered for a currency the table had already withdrawn
    bool public ghost_withdrawnCurrencyQuoted;

    constructor(
        HandlerConfig memory config,
        PaymentAdapter _paymentAdapter,
        MockERC20 _settlementERC20,
        bytes32[] memory _symbols
    ) HandlerBase(config) {
        paymentAdapter = _paymentAdapter;
        settlementERC20 = _settlementERC20;
        symbols = _symbols;
    }

    /// @notice One of the four references the run draws from
    function _reference(uint256 seed) internal pure returns (bytes32) {
        return keccak256(abi.encode("payment-handler", seed % REFERENCE_POOL));
    }

    /// @notice One of the currencies the campaign registered
    function _symbol(uint256 seed) internal view returns (bytes32) {
        return symbols[bound(seed, 0, symbols.length - 1)];
    }

    /// @notice Counts a spend that went through, and notices a second one on the same reference
    function _recordSpend(bytes32 _paymentReference) internal {
        if (ghost_spendCount[_paymentReference] == 0) {
            spentReferences.push(_paymentReference);
        } else {
            ghost_referenceSpentTwice = true;
        }

        ghost_spendCount[_paymentReference] += 1;
    }

    /// @notice The ceiling that applies to this wallet right now
    /// @dev Prices are bound to it so the ceiling never decides the call. What decides it is the
    ///      reference, which is the subject here.
    function _effectiveCap(address wallet) internal view returns (uint64) {
        uint64 cap = ESIMWallet(payable(wallet)).priceCapUSDCents();
        return cap == 0 ? registry.defaultPriceCapUSDCents() : cap;
    }

    /// @notice How many references this run has spent
    function spentReferenceCount() external view returns (uint256) {
        return spentReferences.length;
    }

    // ---------------------------------------------------------------------------------------------
    // The two payment paths
    // ---------------------------------------------------------------------------------------------

    /// @notice A wallet buys a data bundle with ETH
    /// @param eSIMIndex Picks the wallet
    /// @param priceUSDCents Price to record, bound under whichever ceiling applies
    /// @param priceWei ETH to send to the vault
    /// @param referenceSeed Picks the payment reference from the pool
    function buyDataBundle(
        uint256 eSIMIndex,
        uint64 priceUSDCents,
        uint256 priceWei,
        uint256 referenceSeed
    ) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("buyDataBundle");
            return;
        }

        bytes32 paymentReference = _reference(referenceSeed);
        priceUSDCents = uint64(bound(priceUSDCents, 1, _effectiveCap(wallet)));
        priceWei = bound(priceWei, 1, 1 ether);

        vm.prank(_currentAdmin());
        try ESIMWallet(payable(wallet)).buyDataBundle(
            DataBundleDetails({
                id: "bundle",
                priceUSDCents: priceUSDCents,
                settlement: Settlement.Fiat
            }),
            priceWei,
            paymentReference
        ) {
            _recordSpend(paymentReference);
            state.recordCall("buyDataBundle");
        } catch {
            state.recordRevert("buyDataBundle");
        }
    }

    /// @notice A wallet buys a data bundle with the settlement token
    /// @dev The funding is minted to the eSIM wallet rather than to its device wallet, so whether
    ///      the call goes through turns on the reference rather than on an access flag another
    ///      handler happens to have toggled.
    /// @param eSIMIndex Picks the wallet
    /// @param priceUSDCents Price to charge, bound under whichever ceiling applies
    /// @param fundingSeed How much of the price the wallet is given, so both funded and short cases run
    /// @param referenceSeed Picks the payment reference from the pool
    function buyDataBundleWithToken(
        uint256 eSIMIndex,
        uint64 priceUSDCents,
        uint256 fundingSeed,
        uint256 referenceSeed
    ) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("buyDataBundleWithToken");
            return;
        }

        bytes32 paymentReference = _reference(referenceSeed);
        priceUSDCents = uint64(bound(priceUSDCents, 1, _effectiveCap(wallet)));

        uint256 needed = (uint256(priceUSDCents) * 10 ** SETTLEMENT_DECIMALS) / 100;
        settlementERC20.mint(wallet, bound(fundingSeed, 0, needed * 2));

        vm.prank(_currentAdmin());
        try ESIMWallet(payable(wallet)).buyDataBundleWithToken(
            DataBundleDetails({
                id: "token",
                priceUSDCents: priceUSDCents,
                settlement: Settlement.Fiat
            }),
            SETTLEMENT_SYMBOL,
            needed,
            paymentReference
        ) {
            _recordSpend(paymentReference);
            ghost_settledToVault += needed;
            state.recordCall("buyDataBundleWithToken");
        } catch {
            state.recordRevert("buyDataBundleWithToken");
        }
    }

    /// @notice The admin records a purchase paid for outside the protocol
    /// @param eSIMIndex Picks the wallet
    /// @param priceUSDCents Price to record, bound under whichever ceiling applies
    /// @param referenceSeed Picks the payment reference from the pool
    /// @param symbolSeed Picks the currency the user is said to have paid in
    /// @param paidFromAWallet Whether the payment is claimed as an external wallet or as fiat
    function recordSettledPurchase(
        uint256 eSIMIndex,
        uint64 priceUSDCents,
        uint256 referenceSeed,
        uint256 symbolSeed,
        bool paidFromAWallet
    ) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("recordSettledPurchase");
            return;
        }

        bytes32 paymentReference = _reference(referenceSeed);
        priceUSDCents = uint64(bound(priceUSDCents, 1, _effectiveCap(wallet)));

        vm.prank(_currentAdmin());
        try registry.recordSettledPurchase(
            wallet,
            DataBundleDetails({
                id: "settled",
                priceUSDCents: priceUSDCents,
                settlement: paidFromAWallet ? Settlement.ExternalWallet : Settlement.Fiat
            }),
            _symbol(symbolSeed),
            uint256(priceUSDCents),
            paymentReference
        ) {
            _recordSpend(paymentReference);
            state.recordCall("recordSettledPurchase");
        } catch {
            state.recordRevert("recordSettledPurchase");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // The currency table
    // ---------------------------------------------------------------------------------------------

    /// @notice The owner withdraws a currency or puts it back
    /// @param symbolSeed Picks the currency
    /// @param allowed Whether the currency is being allowed or withdrawn
    /// @param isDollarUnit Whether it is being marked as already in dollars
    function updateAsset(uint256 symbolSeed, bool allowed, bool isDollarUnit) external counted {
        bytes32 symbol = _symbol(symbolSeed);
        (,, uint8 decimals, address token) = paymentAdapter.assets(symbol);

        vm.prank(upgradeManager);
        try paymentAdapter.updateAsset(symbol, Asset({
            allowed: allowed,
            isDollarUnit: isDollarUnit,
            decimals: decimals,
            token: token
        })) {
            state.recordCall("updateAsset");
        } catch {
            state.recordRevert("updateAsset");
        }
    }

    /// @notice Asks for a price in one of the currencies
    /// @dev The answer is checked against the table read in the same call. A withdrawn currency
    ///      that still answers is the stale success this is looking for.
    /// @param symbolSeed Picks the currency
    /// @param priceUSDCents Price to ask about
    function quote(uint256 symbolSeed, uint64 priceUSDCents) external counted {
        bytes32 symbol = _symbol(symbolSeed);
        (bool allowed,,,) = paymentAdapter.assets(symbol);

        try paymentAdapter.quote(symbol, priceUSDCents) returns (uint256) {
            if (!allowed) ghost_withdrawnCurrencyQuoted = true;
            state.recordCall("quote");
        } catch {
            state.recordRevert("quote");
        }
    }
}
