// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../Errors.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPaymentRegistry} from "../interfaces/IPaymentRegistry.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @notice One currency the protocol will price a data bundle in
/// @dev 23 bytes, so it fits one slot with nine to spare. New fields have to stay inside those
///      nine bytes: a second slot moves every entry in the mapping, and a live table cannot be
///      moved.
struct Asset {
    bool allowed;
    bool isDollarUnit;   // USDC, USDT, DAI and USD are true. ETH, TON and ZEC are not
    uint8 decimals;      // USDC 6, ETH 18, TON 9, ZEC 8, USD 2
    address token;       // ERC-20 address, or zero for fiat and non-EVM assets
}

/// @notice Holds the accepted currencies, converts prices, moves tokens to the vault, and spends
///         payment references
/// @dev Prices cross contract boundaries in USD cents only, and this is the one place a cent
///      figure becomes a token amount, so a decimals mismatch cannot happen rather than having to
///      be checked for. There are no price feeds, so a currency not already in dollars has no
///      conversion here. UUPS and not swappable: `usedReferences` is replay protection, and a
///      fresh copy would re-open every reference already spent.
///
///      Tokens pass through in one call and never rest here.
contract PaymentAdapter is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Cents per dollar, the divisor that takes a cent price down to whole units
    uint256 private constant CENTS_PER_DOLLAR = 100;

    /// @notice Fewest decimals a currency may have. `quote` divides by 100, so fewer loses the cents.
    uint8 private constant MIN_ASSET_DECIMALS = 2;

    /// @notice Most decimals a currency may have
    /// @dev Above this, the largest price the protocol can express overflows `quote` and the
    ///      currency can never be priced at all. Well past the 18 any real token uses.
    uint8 private constant MAX_ASSET_DECIMALS = 36;

    /// @notice Registry contract address, the only caller allowed to spend a payment reference
    address public registry;

    /// @notice Currency the vault is meant to end up holding
    /// @dev Nothing reads it yet. Set at initialisation anyway, so adding the swap path later needs
    ///      no migration transaction on every chain.
    address public settlementToken;

    /// @notice Every currency the protocol will accept or record a payment in
    mapping(bytes32 symbol => Asset asset) public assets;

    /// @notice Payment references already spent, protocol-wide
    /// @dev One reference is one offchain payment. The backend retries the whole onchain step on
    ///      any failure, so without this a retry of a call that already landed records it twice.
    mapping(bytes32 paymentReference => bool used) public usedReferences;

    /// @notice Emitted when this contract is wired up
    event PaymentAdapterInitialized(address indexed _registry, address indexed _settlementToken);

    /// @notice Emitted when a currency enters the vocabulary or its entry changes
    event AssetUpdated(
        bytes32 indexed _symbol,
        bool _allowed,
        bool _isDollarUnit,
        uint8 _decimals,
        address indexed _token
    );

    /// @notice Emitted when a payment reference is spent
    event PaymentReferenceConsumed(bytes32 indexed _paymentReference);

    /// @notice Emitted when a data bundle is paid for in tokens through this contract
    /// @dev One address for an indexer to watch instead of every eSIM wallet. The vault is
    ///      recorded because it can be rotated, and reconciliation needs the one that was paid.
    event PaymentSettled(
        bytes32 indexed _symbol,
        address indexed _eSIMWallet,
        address indexed _vault,
        uint64 _priceUSDCents,
        uint256 _spent,
        uint256 _refunded
    );

    /// @notice Restricts a call to the registry
    modifier onlyRegistry() {
        if(msg.sender != registry) revert Errors.OnlyRegistry();
        _;
    }

    /// @notice Restricts a call to an eSIM wallet the registry has a record of
    /// @dev Read from the registry on every call rather than held here, so a wallet the registry
    ///      has let go cannot keep paying through this contract.
    modifier onlyProtocolESIMWallet() {
        if(IPaymentRegistry(registry).isESIMWalletValid(msg.sender) == address(0)) {
            revert Errors.NotAProtocolESIMWallet(msg.sender);
        }
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @dev Locks the implementation contract itself, so nobody can initialise and own it directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Wires the adapter to the registry and names the currency the vault should hold
    /// @param _registry Registry contract address
    /// @param _settlementToken Token the vault is meant to end up holding, normally USDC
    /// @param _upgradeManager Address that owns this contract and authorises its upgrades
    function initialize(
        address _registry,
        address _settlementToken,
        address _upgradeManager
    ) external initializer {
        if(_registry == address(0)) revert Errors.ZeroAddress("_registry");
        if(_settlementToken == address(0)) revert Errors.ZeroAddress("_settlementToken");
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");

        registry = _registry;
        settlementToken = _settlementToken;

        __Ownable2Step_init();
        __Ownable_init(_upgradeManager);
        __ReentrancyGuard_init();

        emit PaymentAdapterInitialized(_registry, _settlementToken);
    }

    // ---------------------------------------------------------------------------------------------
    // The currency vocabulary
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds a currency the protocol will accept or record a payment in
    /// @dev Owner and not admin. The admin names the price on every purchase, so letting it add
    ///      currencies too would let it invent a token address to be paid into.
    /// @param _symbol Short ASCII symbol, "USDC" or "USD" or "TON"
    /// @param _asset The entry to write
    function registerAsset(bytes32 _symbol, Asset calldata _asset) external onlyOwner {
        if(assets[_symbol].decimals != 0) revert Errors.AssetAlreadyRegistered(_symbol);

        _writeAsset(_symbol, _asset);
    }

    /// @notice Changes an existing currency entry, including withdrawing it
    /// @dev Separate from `registerAsset` so a typo in a new symbol cannot silently overwrite a
    ///      currency already in use. Set `allowed` to false to withdraw one.
    /// @param _symbol Symbol of the currency being changed
    /// @param _asset The entry to write in its place
    function updateAsset(bytes32 _symbol, Asset calldata _asset) external onlyOwner {
        if(assets[_symbol].decimals == 0) revert Errors.AssetNotRegistered(_symbol);

        _writeAsset(_symbol, _asset);
    }

    // ---------------------------------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------------------------------

    /// @notice Turns a price in USD cents into an amount of one currency's smallest unit
    /// @dev The only place in the protocol that does this, so there is never a second figure to
    ///      check this one against. A currency not already in dollars needs a rate, and there are
    ///      no price feeds here, so it reverts instead of guessing.
    /// @param _symbol Currency the price is being expressed in
    /// @param _priceUSDCents Price in USD cents
    /// @return amountIn Amount in that currency's own smallest unit
    function quote(bytes32 _symbol, uint64 _priceUSDCents) external view returns (uint256 amountIn) {
        return _quote(_symbol, assets[_symbol], _priceUSDCents);
    }

    /// @notice Reads back a currency entry, reverting if it is not allowed
    /// @dev Callers read the token address and decimals from here rather than passing them in, so
    ///      they stay the same across every record.
    /// @param _symbol Currency to read
    /// @return The stored entry
    function resolveAsset(bytes32 _symbol) external view returns (Asset memory) {
        Asset memory asset = assets[_symbol];
        if(!asset.allowed) revert Errors.AssetNotAllowed(_symbol);

        return asset;
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------------

    /// @notice Pays the vault for one data bundle out of tokens the caller has already sent here
    /// @dev The caller funds this contract and calls settle in the same transaction, which leaves
    ///      the tokens here for a swap to be added later without changing this signature.
    ///
    ///      The refund is bounded by what the caller funded rather than by the balance, so a token
    ///      sent here by mistake is not swept out by the next purchase. A fee-on-transfer token
    ///      delivers less than declared and fails the funding check.
    /// @param _symbol Currency being paid in
    /// @param _priceUSDCents Price of the data bundle, in USD cents
    /// @param _amountIn Amount the caller has funded, and the most it is willing to spend
    /// @param _refundTo Address anything unspent goes back to
    /// @return spent Amount that reached the vault
    /// @return refunded Amount returned to `_refundTo`, always zero until a swap can overshoot
    function settle(
        bytes32 _symbol,
        uint64 _priceUSDCents,
        uint256 _amountIn,
        address _refundTo
    ) external nonReentrant onlyProtocolESIMWallet returns (uint256 spent, uint256 refunded) {
        if(_priceUSDCents == 0) revert Errors.ZeroDataBundlePrice();
        if(_refundTo == address(0)) revert Errors.ZeroAddress("_refundTo");

        Asset memory asset = assets[_symbol];
        if(asset.token == address(0)) revert Errors.AssetNotTransferable(_symbol);

        spent = _quote(_symbol, asset, _priceUSDCents);
        if(spent > _amountIn) revert Errors.SettlementAboveMax(spent, _amountIn);

        IERC20 token = IERC20(asset.token);
        uint256 held = token.balanceOf(address(this));
        if(held < _amountIn) revert Errors.SettlementNotFunded(_amountIn, held);

        refunded = _amountIn - spent;
        address vault = IPaymentRegistry(registry).vault();

        emit PaymentSettled(_symbol, msg.sender, vault, _priceUSDCents, spent, refunded);

        token.safeTransfer(vault, spent);
        if(refunded != 0) token.safeTransfer(_refundTo, refunded);
    }

    // ---------------------------------------------------------------------------------------------
    // Payment references
    // ---------------------------------------------------------------------------------------------

    /// @notice Spends a payment reference, refusing one already spent
    /// @dev Registry only, on both payment paths, so one reference cannot be spent once on each.
    /// @param _paymentReference Hash tying this purchase to the offchain payment behind it
    function consumePaymentReference(bytes32 _paymentReference) external onlyRegistry {
        if(_paymentReference == bytes32(0)) revert Errors.EmptyPaymentReference();
        if(usedReferences[_paymentReference]) revert Errors.PaymentReferenceAlreadyUsed(_paymentReference);

        usedReferences[_paymentReference] = true;

        emit PaymentReferenceConsumed(_paymentReference);
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only caller `_authorizeUpgrade` accepts and the only one that can
    ///      change the list of currencies. Renouncing would freeze both for good.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Restricts UUPS upgrades to the owner
    /// @param newImplementation Address of the implementation being moved to
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    /// @notice Address that can upgrade this contract
    /// @dev Reads through to the owner rather than holding a second copy that could disagree.
    function upgradeManager() public view returns (address) {
        return owner();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @notice The cents to smallest-unit conversion `quote` and `settle` both go through
    /// @dev One copy, so a settled amount can never disagree with the quoted one.
    /// @param _symbol Currency the price is being expressed in, carried only for the revert
    /// @param _asset The entry already read from storage
    /// @param _priceUSDCents Price in USD cents
    function _quote(bytes32 _symbol, Asset memory _asset, uint64 _priceUSDCents)
        private
        pure
        returns (uint256)
    {
        if(!_asset.allowed) revert Errors.AssetNotAllowed(_symbol);
        if(!_asset.isDollarUnit) revert Errors.AssetNeedsSwap(_symbol);

        return (uint256(_priceUSDCents) * 10 ** _asset.decimals) / CENTS_PER_DOLLAR;
    }

    /// @notice Validates and stores one currency entry
    /// @dev A non-zero `decimals` is what marks a symbol as registered, so withdrawing a currency
    ///      sets `allowed` to false instead of deleting the entry.
    function _writeAsset(bytes32 _symbol, Asset calldata _asset) private {
        if(_symbol == bytes32(0)) revert Errors.EmptyAssetSymbol();
        if(_asset.decimals < MIN_ASSET_DECIMALS) {
            revert Errors.AssetDecimalsTooLow(_symbol, _asset.decimals);
        }
        if(_asset.decimals > MAX_ASSET_DECIMALS) {
            revert Errors.AssetDecimalsTooHigh(_symbol, _asset.decimals);
        }

        assets[_symbol] = _asset;

        emit AssetUpdated(_symbol, _asset.allowed, _asset.isDollarUnit, _asset.decimals, _asset.token);
    }
}
