// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../Errors.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Types
import {DataBundleDetails, Settlement} from "../CustomStructs.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {DeviceWallet} from "../device-wallet/DeviceWallet.sol";
import {PaymentAdapter, Asset} from "../payments/PaymentAdapter.sol";
import {Registry} from "../Registry.sol";

/// @notice One eSIM, its purchase history and the ETH that pays for its data bundles
/// @dev A beacon proxy deployed by `ESIMWalletFactory`, always owned by a device wallet. The owner
///      is a contract rather than a key, so every call that moves ETH or ownership arrives through
///      a device wallet `execute` and has already been signed for. The admin can charge this wallet
///      for a data bundle but cannot raise the ceiling that limits what it may charge.
contract ESIMWallet is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @notice Device wallet contract instance associated with this eSIM wallet
    DeviceWallet public deviceWallet;

    /// @notice Array of all the data bundle purchase
    DataBundleDetails[] public transactionHistory;

    /// @notice Address of the owner (device wallet) that becomes the new owner
    address public newRequestedOwner;

    /// @notice Most this wallet may be charged for one data bundle, in USD cents, or zero to follow
    ///         the registry
    /// @dev Declared here so it shares a slot with `newRequestedOwner`. Solidity packs in
    ///      declaration order, so moving this line costs that slot. A handover clears both, which
    ///      is then one write instead of two. Zero means "follow the registry", not "no ceiling".
    uint64 public priceCapUSDCents;

    /// @notice Emitted when the eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress,
        address indexed _owner
    );

    /// @notice Emitted when the payment for a data bundle is made
    event DataBundleBought(
        bytes32 _dataBundleID,
        uint64 _priceUSDCents,
        uint256 _priceWei,
        uint256 _ethFromUser,
        bytes32 indexed _paymentReference
    );

    /// @notice Emitted when a data bundle is paid for in an ERC-20
    /// @dev The adapter emits the settlement. This one is for an indexer watching one wallet.
    event DataBundleBoughtWithToken(
        bytes32 _dataBundleID,
        uint64 _priceUSDCents,
        bytes32 indexed _asset,
        address indexed _token,
        uint256 _amountSpent,
        bytes32 indexed _paymentReference
    );

    /// @notice Emitted when an ERC-20 is returned to the owning device wallet
    event TokenSentToDeviceWallet(address indexed _token, address indexed _deviceWallet, uint256 _amount);

    /// @notice Emitted when a purchase paid for outside the protocol is recorded here
    /// @dev The registry emits the full record. This one is for an indexer watching one wallet.
    event DataBundleSettlementRecorded(
        bytes32 _dataBundleID,
        uint64 _priceUSDCents,
        Settlement _settlement
    );

    /// @notice Emitted when the eSIM unique identifier is initialised
    event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier);

    /// @notice Emitted for every batch of history the lazy wallet registry copies in after deployment.
    ///         `_totalEntries` is the transaction history length once the batch has landed, which is
    ///         what tells a partial copy apart from a finished one.
    event TransactionHistoryPopulated(DataBundleDetails[] _dataBundleDetails, uint256 _totalEntries);

    /// @notice Emitted when ETH moves out of this contract
    event ETHSent(address indexed _recipient, uint256 _amount);

    /// @notice Emitted when the current owner wants to transfer the ownership to a new device wallet
    event OwnershipTransferRequested(address indexed _currentOwner, address indexed _newOwner);

    /// @notice Emitted when the current owner revoked the ownership transfer request
    event OwnershipTransferRevoked(address indexed _currentOwner, address indexed _revokedOwner);

    /// @notice Emitted when the owner sets this wallet's own price ceiling
    event PriceCapUSDCentsUpdated(uint64 _cap);

    /// @notice Restricts a call to the device wallet that owns this eSIM wallet
    /// @dev Reaching this means the owner signed for it, since a device wallet only calls out
    ///      through `execute`.
    modifier onlyDeviceWallet() {
        if (msg.sender != address(deviceWallet)) revert Errors.OnlyDeviceWallet();
        _;
    }

    /// @notice Restricts a call to the registry
    modifier onlyRegistry() {
        if(msg.sender != address(deviceWallet.registry())) revert Errors.OnlyRegistry();
        _;
    }

    /// @notice Reverts unless the caller is the owning device wallet or the eSIM wallet admin
    /// @dev A private function rather than the modifier body, so the check is emitted once instead
    ///      of at every use site. Keep it next to the modifier that calls it.
    function _onlyDeviceWalletOrESIMWalletAdmin() private view {
        if(
            msg.sender != address(deviceWallet) &&
            msg.sender != deviceWallet.registry().eSIMWalletAdmin()
        ) {
            revert Errors.OnlyDeviceWalletOrESIMWalletAdmin();
        }
    }

    /// @notice Restricts a call to the owning device wallet or the eSIM wallet admin
    modifier onlyDeviceWalletOrESIMWalletAdmin() {
        _onlyDeviceWalletOrESIMWalletAdmin();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @dev `_disableInitializers` rather than an `initializer` modifier. The modifier leaves the
    ///      version at 1, which a later `reinitializer(2)` would still accept on the implementation
    ///      itself. This pins it at the maximum so no version can ever run there.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Binds a freshly deployed eSIM wallet to its factory and its owning device wallet
    /// @dev The eSIM identifier is not set here. It does not exist until the eSIM itself has been
    ///      bought, so it arrives later through `setESIMUniqueIdentifier`.
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory contract address
    /// @param _deviceWalletAddress Device wallet contract address (the contract that deploys this eSIM wallet)
    function initialize(
        address _eSIMWalletFactoryAddress,
        address _deviceWalletAddress
    ) external initializer {
        if(_eSIMWalletFactoryAddress == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactoryAddress");
        if(_deviceWalletAddress == address(0)) revert Errors.ZeroAddress("_deviceWalletAddress");

        eSIMWalletFactory = _eSIMWalletFactoryAddress;
        deviceWallet = DeviceWallet(payable(_deviceWalletAddress));

        __Ownable_init(_deviceWalletAddress);
        __ReentrancyGuard_init();

        emit ESIMWalletDeployed(address(this), _deviceWalletAddress, _deviceWalletAddress);
    }

    // ---------------------------------------------------------------------------------------------
    // Identifier, price ceiling and history
    // ---------------------------------------------------------------------------------------------

    /// @notice Since buying the eSIM (along with data bundle) happens before the identifier is generated,
    ///         the identifier is to be set separately after the wallet is deployed and eSIM is created
    /// @dev Set once, and only by the registry, which records the claim in the same call. The
    ///      owning device wallet used to be the caller, which let an owner write a string the
    ///      registry has no record of.
    /// @param _eSIMUniqueIdentifier String that uniquely identifies eSIM wallet
    function setESIMUniqueIdentifier(string calldata _eSIMUniqueIdentifier) external onlyRegistry {
        // Read the identifier itself only on the failing branch, so setting one for the first time
        // pays for the length slot alone
        if(bytes(eSIMUniqueIdentifier).length != 0) revert Errors.ESIMIdentifierAlreadySet(eSIMUniqueIdentifier);
        if(bytes(_eSIMUniqueIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();

        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;

        emit ESIMUniqueIdentifierInitialised(_eSIMUniqueIdentifier);
    }

    /// @notice Sets the most this wallet may be charged for one data bundle
    /// @dev Only the owning device wallet, which means the person holding its P256 key: reaching
    ///      this needs a device wallet `execute`, and that needs a signature. The admin names the
    ///      price on `buyDataBundle`, so it must not also be able to raise the ceiling on that
    ///      price. Setting zero hands the wallet back to the registry's ceiling. A handover clears
    ///      it, so an incoming owner starts on the registry ceiling.
    /// @param _cap Maximum price in USD cents, or zero to follow the registry
    function setPriceCapUSDCents(uint64 _cap) external onlyDeviceWallet {
        priceCapUSDCents = _cap;
        emit PriceCapUSDCentsUpdated(_cap);
    }

    /// @notice Appends pre-deployment purchase history, one batch at a time, on behalf of the lazy
    ///         wallet registry
    /// @dev The registry carries the cursor that says how much of an eSIM's history has already been
    ///      copied, so this function appends whatever it is handed and does not police repeats.
    /// @param _dataBundleDetails One batch of data bundle purchase details from before the wallet
    ///        was deployed
    /// @return True once the batch has been appended
    function populateHistory(DataBundleDetails[] calldata _dataBundleDetails) external onlyRegistry returns (bool) {
        // Assigning the whole calldata array at once is not supported for arrays of structs, so
        // each entry is pushed on its own. The batch lands after whatever the array already held.
        uint256 alreadyStored = transactionHistory.length;
        uint256 entries = _dataBundleDetails.length;
        for (uint256 i = 0; i < entries; ++i) {
            transactionHistory.push(_dataBundleDetails[i]);
        }

        emit TransactionHistoryPopulated(_dataBundleDetails, alreadyStored + entries);

        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership handover
    // ---------------------------------------------------------------------------------------------

    /// @notice Nominates a new device wallet to take this eSIM wallet over, in two steps
    /// @dev Any outstanding request is overwritten rather than refused, so an owner who nominated
    ///      the wrong address just calls this again. Nominating the current owner cancels the
    ///      request and re-binds the wallet to its device wallet in the same call, with ETH access
    ///      left off since the flag it had before the removal is not recorded anywhere.
    /// @param _newOwner Address of the new device wallet to transfer ownership of this wallet
    function requestTransferOwnership(address _newOwner) external onlyDeviceWallet nonReentrant {
        Registry registry = deviceWallet.registry();
        if(!registry.isDeviceWalletValid(_newOwner)) revert Errors.NotADeviceWallet(_newOwner);

        // If the owner wants to retain the ownership of the contract,
        // they simply revoke the request by requesting a transfer to themselves
        if(_newOwner == owner()) {
            address revokedAddress = newRequestedOwner;
            newRequestedOwner = address(0);
            emit OwnershipTransferRevoked(owner(), revokedAddress);

            // The request being cancelled took this wallet off its device wallet, if it was ever
            // sent. A request revoked before that removal landed leaves the wallet already bound.
            if(!deviceWallet.isValidESIMWallet(address(this))) {
                deviceWallet.addESIMWallet(address(this), false);
            }
            return;
        }

        // Remove this eSIMWallet from the device wallet and send all ETH to device wallet.
        // The transient window opens here rather than at acceptance, so a reader that sees the
        // standby flag raised also sees the request that caused it. Guarded because
        // removeESIMWallet refuses a wallet the device wallet no longer holds, which would
        // otherwise make re-targeting an outstanding request revert instead of overwriting it.
        if(deviceWallet.isValidESIMWallet(address(this))) {
            deviceWallet.removeESIMWallet(address(this), true);
        }

        newRequestedOwner = _newOwner;

        emit OwnershipTransferRequested(owner(), newRequestedOwner);
    }

    /// @notice Takes this eSIM wallet on, callable only by the nominated device wallet
    /// @dev The check compares the caller to `newRequestedOwner`, which both sides satisfy when
    ///      they are zero. No transaction can arrive from the zero address, so this holds onchain,
    ///      but any reasoning about this function has to exclude that caller explicitly.
    function acceptOwnershipTransfer() external {
        address requestedOwner = newRequestedOwner;
        if(msg.sender != requestedOwner) revert Errors.OnlyRequestedOwner(requestedOwner);

        _secureTransferOwnership();
    }

    // ---------------------------------------------------------------------------------------------
    // ETH and data bundle payments
    // ---------------------------------------------------------------------------------------------

    /// @notice Allow the owner device wallet to callback all the ETH from this eSIM wallet
    /// @dev This function is generally called before the owner device wallet removes this eSIM wallet
    /// @dev Deliberately not nonReentrant. removeESIMWallet calls this from inside a try/catch while
    ///      requestTransferOwnership already holds this contract's guard, so guarding here would
    ///      make the callback revert into that catch and strand the wallet's ETH with no error.
    ///      It writes no state of its own, and only the owner can call it to move ETH to itself,
    ///      so re-entering it gains nothing.
    /// @param _amount Amount of ETH to be sent
    function sendETHToDeviceWallet(
        uint256 _amount
    ) external onlyDeviceWallet returns (uint256) {
        if(owner() == address(0)) revert Errors.ZeroAddress("owner");

        _transferETH(owner(), _amount);

        return _amount;
    }

    /// @notice Pays the vault for one data bundle in ETH and records the purchase
    /// @dev Callable by the owning device wallet or by the admin, since the admin is the party that
    ///      knows the price. Any shortfall is pulled from the device wallet, which is why the price
    ///      is checked against a ceiling the admin cannot raise.
    ///
    ///      The ceiling is in cents and the ETH sent is in wei, and nothing onchain converts
    ///      between them. So the ceiling limits what gets recorded, not what gets sent, and
    ///      `_priceWei` is taken on trust. The token path closes that gap by working the amount
    ///      out from the price instead.
    /// @param _dataBundleDetail Data bundle being bought. Its settlement field is overwritten here.
    /// @param _priceWei ETH actually being sent to the vault
    /// @param _paymentReference The offchain order id. Spent once, so a retry of a call that
    ///        already landed cannot charge the user twice.
    /// @return True if the transaction is successful
    function buyDataBundle(
        DataBundleDetails memory _dataBundleDetail,
        uint256 _priceWei,
        bytes32 _paymentReference
    ) public payable onlyDeviceWalletOrESIMWalletAdmin nonReentrant returns (bool) {
        Registry registry = deviceWallet.registry();
        registry.requireNotPaused();
        if(_dataBundleDetail.id == bytes32(0)) revert Errors.EmptyDataBundleID();
        if(_dataBundleDetail.priceUSDCents == 0) revert Errors.ZeroDataBundlePrice();
        if(_priceWei == 0) revert Errors.ZeroDataBundlePrice();
        _requirePriceWithinCap(_dataBundleDetail.priceUSDCents, registry);

        // This is the only path that sees the money reach the vault, so it sets this itself.
        _dataBundleDetail.settlement = Settlement.DeviceWallet;

        registry.consumePaymentReference(_paymentReference);

        uint256 walletBalance = address(this).balance;

        if (walletBalance < _priceWei) {
            deviceWallet.pullETH(_priceWei - walletBalance);
        }

        address vault = deviceWallet.getVaultAddress();

        // Recorded before the transfer, so a vault that is a contract cannot observe a purchase
        // that is not yet in the history it would be reading.
        transactionHistory.push(_dataBundleDetail);

        _transferETH(vault, _priceWei);

        emit DataBundleBought(
            _dataBundleDetail.id,
            _dataBundleDetail.priceUSDCents,
            _priceWei,
            msg.value,
            _paymentReference
        );

        return true;
    }

    /// @notice Pays the vault for one data bundle in an ERC-20 and records the purchase
    /// @dev The adapter works the amount out from the price, so unlike the ETH path there is no
    ///      second figure to take on trust. Any shortfall is pulled from the device wallet.
    /// @param _dataBundleDetail Data bundle being bought. Its settlement field is overwritten here.
    /// @param _asset Symbol of the currency to pay in
    /// @param _maxAmountIn Most of that currency the buyer will spend, in its smallest unit
    /// @param _paymentReference The offchain order id. Spent once, so a retry of a call that
    ///        already landed cannot charge the user twice.
    /// @return True if the transaction is successful
    function buyDataBundleWithToken(
        DataBundleDetails memory _dataBundleDetail,
        bytes32 _asset,
        uint256 _maxAmountIn,
        bytes32 _paymentReference
    ) external nonReentrant onlyDeviceWalletOrESIMWalletAdmin returns (bool) {
        Registry registry = deviceWallet.registry();
        registry.requireNotPaused();
        if(_dataBundleDetail.id == bytes32(0)) revert Errors.EmptyDataBundleID();
        if(_dataBundleDetail.priceUSDCents == 0) revert Errors.ZeroDataBundlePrice();
        _requirePriceWithinCap(_dataBundleDetail.priceUSDCents, registry);

        // The money moves through this contract, so this path can say the protocol saw it.
        _dataBundleDetail.settlement = Settlement.DeviceWallet;

        registry.consumePaymentReference(_paymentReference);

        address adapterAddress = registry.paymentAdapter();
        if(adapterAddress == address(0)) revert Errors.PaymentAdapterNotSet();

        PaymentAdapter adapter = PaymentAdapter(adapterAddress);
        Asset memory asset = adapter.resolveAsset(_asset);
        if(asset.token == address(0)) revert Errors.AssetNotTransferable(_asset);

        uint256 amountIn = adapter.quote(_asset, _dataBundleDetail.priceUSDCents);
        if(amountIn > _maxAmountIn) revert Errors.SettlementAboveMax(amountIn, _maxAmountIn);

        // Recorded before any token moves, so nothing downstream reads a history missing this
        transactionHistory.push(_dataBundleDetail);

        IERC20 token = IERC20(asset.token);
        uint256 held = token.balanceOf(address(this));
        if(held < amountIn) deviceWallet.pullToken(asset.token, amountIn - held);

        // Funded first, then told to settle. That is what lets a swap be added there later
        // without changing anything here.
        token.safeTransfer(adapterAddress, amountIn);
        (uint256 spent,) = adapter.settle(_asset, _dataBundleDetail.priceUSDCents, amountIn, address(this));

        // The adapter's figure, not what this wallet sent. The two match today, and will not once
        // a swap can spend less than the ceiling it was funded to.
        emit DataBundleBoughtWithToken(
            _dataBundleDetail.id,
            _dataBundleDetail.priceUSDCents,
            _asset,
            asset.token,
            spent,
            _paymentReference
        );

        return true;
    }

    /// @notice Sends an ERC-20 held here back to the owning device wallet
    /// @dev The callback on `removeESIMWallet` moves ETH only, so without this a token balance
    ///      would be stranded when the wallet changes hands.
    /// @param _token ERC-20 to send back
    /// @param _amount Amount in that token's smallest unit
    /// @return The amount sent
    function sendTokenToDeviceWallet(
        address _token,
        uint256 _amount
    ) external onlyDeviceWallet returns (uint256) {
        if(_token == address(0)) revert Errors.ZeroAddress("_token");
        if(_amount == 0) revert Errors.ZeroAmount();

        address currentOwner = owner();
        if(currentOwner == address(0)) revert Errors.ZeroAddress("owner");

        IERC20(_token).safeTransfer(currentOwner, _amount);
        emit TokenSentToDeviceWallet(_token, currentOwner, _amount);

        return _amount;
    }

    /// @notice Appends a purchase paid for outside the protocol
    /// @dev No money moves here. Nothing onchain saw this payment, so the ceiling is the only
    ///      limit on what the admin can write into a user's history. Checked here and not on the
    ///      registry because the wallet's own ceiling lives here.
    /// @param _dataBundleDetail The purchase to record
    function recordSettledPurchase(DataBundleDetails calldata _dataBundleDetail) external onlyRegistry {
        // The modifier has already checked the caller is the registry
        _requirePriceWithinCap(_dataBundleDetail.priceUSDCents, Registry(msg.sender));

        transactionHistory.push(_dataBundleDetail);

        emit DataBundleSettlementRecorded(
            _dataBundleDetail.id,
            _dataBundleDetail.priceUSDCents,
            _dataBundleDetail.settlement
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Closed ownership routes
    // ---------------------------------------------------------------------------------------------

    /// @notice The inherited one-step transfer is closed
    /// @dev Ownership moves through `requestTransferOwnership` and `acceptOwnershipTransfer`, which
    ///      also keep `deviceWallet` in step with `owner()`. A one-step transfer would move only
    ///      the latter.
    function transferOwnership(address) public pure override {
        revert Errors.UseAcceptOwnershipTransfer();
    }

    /// @notice An eSIM wallet always belongs to a device wallet, so ownership is never renounced
    /// @dev Renouncing leaves owner() at zero while deviceWallet still points at the old device
    ///      wallet. sendETHToDeviceWallet then reverts on its own zero-owner check and
    ///      DeviceWallet._addESIMWallet can never accept this wallet again, so the ETH held here
    ///      is unreachable for the rest of the wallet's life.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Completes a handover, moving `deviceWallet`, `owner()` and the price ceiling together
    /// @dev Clears the request before it writes anything, so a second acceptance finds nothing.
    ///      The ceiling is the owner's own limit and only the owner can set it, so it goes with the
    ///      owner rather than binding the incoming one to a figure it never chose.
    function _secureTransferOwnership() internal {
        address newOwner = newRequestedOwner;
        // Reset ownership transfer address
        newRequestedOwner = address(0);
        deviceWallet = DeviceWallet(payable(newOwner));

        // Written only on a change, so a wallet that never set a ceiling emits nothing here
        if(priceCapUSDCents != 0) {
            priceCapUSDCents = 0;
            emit PriceCapUSDCentsUpdated(0);
        }

        // Transfer ownership to the request address
        // _transferOwnership emits OwnershipTransferred, so this function must not emit it again
        _transferOwnership(newOwner);
    }

    // ---------------------------------------------------------------------------------------------
    // ETH transfers and cap checks
    // ---------------------------------------------------------------------------------------------

    /// @notice Sends ETH out of this contract, reverting if the call fails
    /// @dev A zero amount is a no-op rather than a revert, so callers that may have nothing to send
    ///      do not need their own guard.
    /// @param _recipient Address receiving the ETH
    /// @param _amount Amount in wei
    function _transferETH(address _recipient, uint256 _amount) internal virtual {
        uint256 balance = address(this).balance;
        if(balance < _amount) revert Errors.InsufficientBalance(balance, _amount);
        if(_recipient == address(0)) revert Errors.ZeroAddress("_recipient");

        if (_amount > 0) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert Errors.FailedToTransfer();
            else emit ETHSent(_recipient, _amount);
        }
    }


    /// @notice Rejects a price above whichever ceiling applies to this wallet
    /// @dev The wallet's own ceiling wins when it has one. Zero here means "follow the registry",
    ///      not "no ceiling": the registry default is guaranteed non-zero by `Registry.initialize`
    ///      and `setDefaultPriceCapUSDCents`, so `cap` always resolves to a real ceiling.
    /// @param _priceUSDCents Price being charged, in USD cents
    /// @param _registry Registry holding the fallback ceiling
    function _requirePriceWithinCap(uint64 _priceUSDCents, Registry _registry) private view {
        uint64 cap = priceCapUSDCents;
        if (cap == 0) {
            cap = _registry.defaultPriceCapUSDCents();
        }

        if (cap != 0 && _priceUSDCents > cap) {
            revert Errors.DataBundlePriceAboveCap(_priceUSDCents, cap);
        }
    }

    /// @notice The device wallet that owns this eSIM wallet
    /// @dev Declared so subclasses and mocks have one place to override.
    function owner() public view override returns (address) {
        return OwnableUpgradeable.owner();
    }

    /// @notice Accepts plain ETH transfers, which is how the device wallet tops this wallet up
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}
