// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Errors} from "../Errors.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @notice One currency the protocol will price a data bundle in
/// @dev 23 bytes, so the whole struct is one slot with nine to spare. Fields may be added inside
///      those nine bytes. Growing past one slot changes the slot stride of every entry in the
///      mapping, and a live table has no migration path for that.
struct Asset {
    bool allowed;
    bool isDollarUnit;   // USDC, USDT, DAI and USD are true. ETH, TON and ZEC are not
    uint8 decimals;      // USDC 6, ETH 18, TON 9, ZEC 8, USD 2
    address token;       // ERC-20 address, or zero for fiat and non-EVM assets
}

/// @notice The protocol's authority on how a data bundle was paid for
/// @dev Holds the currency vocabulary, turns a cent price into a token amount, and spends the
///      payment references that make a purchase impossible to record twice. It holds no purchase
///      records: those stay on the eSIM wallet that made them.
///
///      Prices cross every contract boundary in USD cents and nowhere else. This contract is the
///      only place a cent figure becomes a token amount, which is what makes a decimal mismatch
///      impossible rather than merely something to check for. There are no price feeds anywhere in
///      the protocol, so an asset that is not already denominated in dollars has no answer here.
///
///      UUPS rather than a contract the registry can be re-pointed at. `usedReferences` is replay
///      protection, and swapping it out for an empty one re-opens every reference already spent.
contract PaymentAdapter is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Cents per dollar, the divisor that takes a cent price down to whole units
    uint256 private constant CENTS_PER_DOLLAR = 100;

    /// @notice Fewest decimals an asset may have before `quote` starts truncating
    /// @dev The scale is `10 ** decimals / 100`, so anything under two decimals loses the cents.
    uint8 private constant MIN_ASSET_DECIMALS = 2;

    /// @notice Registry contract address, the only caller allowed to spend a payment reference
    address public registry;

    /// @notice Currency the vault is meant to end up holding
    /// @dev Read by nothing today. It is set at initialisation anyway so that adding the swap path
    ///      later is an implementation change rather than a migration transaction on every chain.
    address public settlementToken;

    /// @notice Every currency the protocol will accept or record a payment in
    mapping(bytes32 symbol => Asset asset) public assets;

    /// @notice Payment references already spent, protocol-wide
    /// @dev One reference is one offchain payment. Spending it is what makes recording a purchase
    ///      safe to retry: the backend retries the whole onchain step on any failure, so without
    ///      this a retry of a call that already landed writes the purchase a second time.
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

    /// @notice Restricts a call to the registry
    modifier onlyRegistry() {
        if(msg.sender != registry) revert Errors.OnlyRegistry();
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

        emit PaymentAdapterInitialized(_registry, _settlementToken);
    }

    // ---------------------------------------------------------------------------------------------
    // The currency vocabulary
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds a currency the protocol will accept or record a payment in
    /// @dev Owner and not admin. The admin names the price on every purchase, so letting it also
    ///      name the currencies would let it invent a token address to be paid in.
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

    /// @notice Turns a price in USD cents into an amount of one currency's own smallest unit
    /// @dev The only place in the protocol that does this. No caller ever states a token amount as
    ///      an authoritative figure, so there is no second number anywhere to reconcile this one
    ///      against, and no tolerance band to check it inside.
    ///
    ///      An asset that is not denominated in dollars has no answer without a rate, and there is
    ///      no oracle here, so it reverts rather than guessing.
    /// @param _symbol Currency the price is being expressed in
    /// @param _priceUSDCents Price in USD cents
    /// @return amountIn Amount in that currency's own smallest unit
    function quote(bytes32 _symbol, uint64 _priceUSDCents) public view returns (uint256 amountIn) {
        Asset memory asset = assets[_symbol];

        if(!asset.allowed) revert Errors.AssetNotAllowed(_symbol);
        if(!asset.isDollarUnit) revert Errors.AssetNeedsSwap(_symbol);

        return (uint256(_priceUSDCents) * 10 ** asset.decimals) / CENTS_PER_DOLLAR;
    }

    /// @notice Reads back a currency entry, reverting if it was never registered
    /// @dev Callers resolve the token address and the decimals through here rather than stating
    ///      them, which is what keeps them consistent across every record the protocol writes.
    /// @param _symbol Currency to read
    /// @return The stored entry
    function resolveAsset(bytes32 _symbol) external view returns (Asset memory) {
        Asset memory asset = assets[_symbol];
        if(!asset.allowed) revert Errors.AssetNotAllowed(_symbol);

        return asset;
    }

    // ---------------------------------------------------------------------------------------------
    // Payment references
    // ---------------------------------------------------------------------------------------------

    /// @notice Spends a payment reference, refusing one already spent
    /// @dev Registry only, on both the witnessed and the asserted path, so one reference cannot be
    ///      spent once on each.
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
    ///      change the currency vocabulary. Renouncing would freeze both for good.
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

    /// @notice Validates and stores one currency entry
    /// @dev `decimals` doubles as the "was this ever registered" marker, so it is non-zero on every
    ///      entry including a withdrawn one. That is why a withdrawal sets `allowed` to false
    ///      rather than deleting the row.
    function _writeAsset(bytes32 _symbol, Asset calldata _asset) private {
        if(_symbol == bytes32(0)) revert Errors.EmptyAssetSymbol();
        if(_asset.decimals < MIN_ASSET_DECIMALS) {
            revert Errors.AssetDecimalsTooLow(_symbol, _asset.decimals);
        }

        assets[_symbol] = _asset;

        emit AssetUpdated(_symbol, _asset.allowed, _asset.isDollarUnit, _asset.decimals, _asset.token);
    }
}
