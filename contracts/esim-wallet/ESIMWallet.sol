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
import {ESIMWalletFactory} from "./ESIMWalletFactory.sol";
import {PaymentAdapter, Asset} from "../payments/PaymentAdapter.sol";
import {Registry} from "../Registry.sol";

/// @notice One eSIM, its purchase history, and the funds that move through it while it buys data bundles
/// @dev Beacon proxy owned by a device wallet, so every owner call has been signed via `execute`.
///      The admin can charge for data bundles but cannot raise the ceiling on those charges.
contract ESIMWallet is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @notice Device wallet contract instance associated with this eSIM wallet
    DeviceWallet public deviceWallet;

    /// @notice Every data bundle purchase recorded for this wallet
    DataBundleDetails[] public transactionHistory;

    /// @notice Device wallet nominated to take this wallet over, or zero if none
    address public newRequestedOwner;

    /// @notice Most this wallet may be charged for one data bundle, in USD cents, or zero to follow
    ///         the registry
    /// @dev Shares a slot with `newRequestedOwner`, so do not move this line. A handover clears
    ///      both in one write.
    uint64 public priceCapUSDCents;

    /// @notice What the eSIM wallet admin may still charge this wallet in total, in USD cents
    /// @dev Starts at the registry default and resets to it on handover. Only admin charges spend
    ///      it and only the owner sets it.
    uint64 public adminAllowanceUSDCents;

    /// @notice Emitted when the eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress,
        address indexed _owner
    );

    /// @notice Emitted when a data bundle is paid for in USDC (or any other acceptable stablecoin/ERC20)
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

    /// @notice Emitted for each batch of history the lazy wallet registry copies in
    /// @dev `_totalEntries` is the history length after the batch, so a partial copy can be told apart.
    event TransactionHistoryPopulated(DataBundleDetails[] _dataBundleDetails, uint256 _totalEntries);

    /// @notice Emitted when ETH moves out of this contract
    event ETHSent(address indexed _recipient, uint256 _amount);

    /// @notice Emitted when the current owner wants to transfer the ownership to a new device wallet
    event OwnershipTransferRequested(address indexed _currentOwner, address indexed _newOwner);

    /// @notice Emitted when the current owner revoked the ownership transfer request
    event OwnershipTransferRevoked(address indexed _currentOwner, address indexed _revokedOwner);

    /// @notice Emitted when the owner sets this wallet's own price ceiling
    event PriceCapUSDCentsUpdated(uint64 _cap);

    /// @notice Emitted whenever what the admin may still charge changes: set, spent or reset
    event AdminAllowanceUSDCentsUpdated(uint64 _allowance);

    /// @notice Restricts a call to the device wallet that owns this eSIM wallet
    /// @dev A device wallet only calls out through `execute`, so this means the owner signed.
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
    /// @dev A function rather than the modifier body, so the check is compiled once, not per use.
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

    /// @notice Disables initializers on the implementation contract
    /// @dev Pins the version at max. An `initializer` modifier would leave it at 1, and a later
    ///      `reinitializer(2)` could then still run on the implementation.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Binds a freshly deployed eSIM wallet to its factory and its owning device wallet
    /// @dev The eSIM identifier does not exist until the eSIM is bought, so it is set later through
    ///      `setESIMUniqueIdentifier`.
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory contract address
    /// @param _deviceWalletAddress Device wallet that owns this eSIM wallet
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

        // Read through the factory, the caller here, which is always wired to the registry
        uint64 allowance = ESIMWalletFactory(_eSIMWalletFactoryAddress).registry().defaultAdminAllowanceUSDCents();
        adminAllowanceUSDCents = allowance;

        emit ESIMWalletDeployed(address(this), _deviceWalletAddress, _deviceWalletAddress);
        emit AdminAllowanceUSDCentsUpdated(allowance);
    }

    // ---------------------------------------------------------------------------------------------
    // Identifier, price ceiling and history
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the eSIM identifier once the eSIM exists, which is after this wallet is deployed
    /// @dev Set once, and only by the registry, which records the claim in the same call. Any
    ///      other caller could write an identifier the registry has no record of.
    /// @param _eSIMUniqueIdentifier String that uniquely identifies eSIM wallet
    function setESIMUniqueIdentifier(string calldata _eSIMUniqueIdentifier) external onlyRegistry {
        // The full string is read only on the failing branch, so a first set reads one slot
        if(bytes(eSIMUniqueIdentifier).length != 0) revert Errors.ESIMIdentifierAlreadySet(eSIMUniqueIdentifier);
        if(bytes(_eSIMUniqueIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();

        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;

        emit ESIMUniqueIdentifierInitialised(_eSIMUniqueIdentifier);
    }

    /// @notice Sets the most this wallet may be charged for one data bundle
    /// @dev Owner only: the admin names the price on a purchase, so it must not also set the
    ///      ceiling. Zero follows the registry ceiling. A handover resets it to zero.
    /// @param _cap Maximum price in USD cents, or zero to follow the registry
    function setPriceCapUSDCents(uint64 _cap) external onlyDeviceWallet {
        priceCapUSDCents = _cap;
        emit PriceCapUSDCentsUpdated(_cap);
    }

    /// @notice Sets what the eSIM wallet admin may still charge this wallet in total
    /// @dev Owner only, since it limits the admin. Zero stops admin charges; the owner can still buy.
    /// @param _allowance Total the admin may charge from now on, in USD cents
    function setAdminAllowanceUSDCents(uint64 _allowance) external onlyDeviceWallet {
        adminAllowanceUSDCents = _allowance;
        emit AdminAllowanceUSDCentsUpdated(_allowance);
    }

    /// @notice Appends pre-deployment purchase history, one batch at a time, on behalf of the lazy
    ///         wallet registry
    /// @dev The registry tracks how much has been copied, so repeats are not checked here. Not held
    ///      to the price ceiling: these are past payments, no charge happens, and refusing one
    ///      would only drop true history.
    /// @param _dataBundleDetails One batch of purchases from before the wallet was deployed
    /// @return True once the batch has been appended
    function populateHistory(DataBundleDetails[] calldata _dataBundleDetails) external onlyRegistry returns (bool) {
        // Copying a calldata struct array to storage in one assignment is not supported
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
    /// @dev A pending request is overwritten, so a wrong nominee is fixed by calling again.
    ///      Nominating the current owner cancels and re-binds, with fund access off since the old
    ///      flag is not recorded. Only ETH is swept back; ERC-20s go to whoever accepts, so sweep
    ///      them with `sendTokenToDeviceWallet` in the same `executeBatch`.
    /// @param _newOwner Address of the new device wallet to transfer ownership of this wallet
    function requestTransferOwnership(address _newOwner) external onlyDeviceWallet nonReentrant {
        Registry registry = deviceWallet.registry();
        if(!registry.isDeviceWalletValid(_newOwner)) revert Errors.NotADeviceWallet(_newOwner);

        if(_newOwner == owner()) {
            address revokedAddress = newRequestedOwner;
            newRequestedOwner = address(0);
            emit OwnershipTransferRevoked(owner(), revokedAddress);

            // Re-bind only if unbound, since addESIMWallet refuses a wallet already held
            if(!deviceWallet.isValidESIMWallet(address(this))) {
                deviceWallet.addESIMWallet(address(this), false);
            }
            return;
        }

        // Unbind and sweep ETH now, not at acceptance, so the standby flag and the request appear
        // together. Guarded because removeESIMWallet refuses an unbound wallet, which would make
        // re-targeting a pending request revert.
        if(deviceWallet.isValidESIMWallet(address(this))) {
            deviceWallet.removeESIMWallet(address(this), true);
        }

        newRequestedOwner = _newOwner;

        emit OwnershipTransferRequested(owner(), newRequestedOwner);
    }

    /// @notice Takes this eSIM wallet on, callable only by the nominated device wallet
    /// @dev With no request pending this only passes for the zero address, which cannot send a
    ///      transaction. Keep that in mind when reasoning about this check.
    function acceptOwnershipTransfer() external {
        address requestedOwner = newRequestedOwner;
        if(msg.sender != requestedOwner) revert Errors.OnlyRequestedOwner(requestedOwner);

        _secureTransferOwnership();
    }

    // ---------------------------------------------------------------------------------------------
    // ETH and data bundle payments
    // ---------------------------------------------------------------------------------------------

    /// @notice Sends ETH from this eSIM wallet back to the owning device wallet
    /// @dev Deliberately not nonReentrant. removeESIMWallet calls it in a try/catch while
    ///      requestTransferOwnership holds the guard, so a guard here would strand the ETH silently.
    ///      It writes no state and only pays the owner, so re-entering gains nothing.
    /// @param _amount Amount of ETH to be sent
    /// @return The amount sent
    function sendETHToDeviceWallet(
        uint256 _amount
    ) external onlyDeviceWallet returns (uint256) {
        if(owner() == address(0)) revert Errors.ZeroAddress("owner");

        _transferETH(owner(), _amount);

        return _amount;
    }

    /// @notice Pays the vault for one data bundle in USDC (or any other acceptable stablecoin/ERC20) and records the purchase
    /// @dev The adapter derives the amount from the price, so no caller figure is trusted. Any
    ///      shortfall is pulled from the device wallet. Forwarding the real balance makes a
    ///      fee-on-transfer token fail at `settle`'s funding check with a clear reason. Such tokens
    ///      are still unsupported, since `settle` needs the full price.
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
        if(msg.sender != address(deviceWallet)) _spendAdminAllowance(_dataBundleDetail.priceUSDCents);
        registry.requireLazyHistoryCopied(address(this));

        // The money moves through this contract, so the protocol saw this payment
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
        if(held < amountIn) {
            deviceWallet.pullToken(asset.token, amountIn - held);
            // A fee-on-transfer token can deliver less than asked, so re-read the balance
            held = token.balanceOf(address(this));
        }

        // settle() checks its own balance against the price and decides if the purchase is funded
        uint256 toForward = held < amountIn ? held : amountIn;

        // Fund first, then settle, so a swap can be added in the adapter without changes here
        token.safeTransfer(adapterAddress, toForward);
        (uint256 spent,) = adapter.settle(_asset, _dataBundleDetail.priceUSDCents, toForward, address(this));

        // The adapter's figure, since a future swap may spend less than it was funded with
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
    /// @dev The `removeESIMWallet` callback moves ETH only, so tokens would otherwise pass to the
    ///      next owner.
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
    /// @dev Nothing onchain saw this payment, so the ceiling is the only limit on what the admin
    ///      can write into history. Checked here because the wallet's own ceiling lives here.
    /// @param _dataBundleDetail The purchase to record
    function recordSettledPurchase(DataBundleDetails calldata _dataBundleDetail) external onlyRegistry {
        // onlyRegistry makes this cast safe
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
    /// @dev It would move `owner()` without `deviceWallet`. The two-step handover moves both.
    function transferOwnership(address) public pure override {
        revert Errors.UseAcceptOwnershipTransfer();
    }

    /// @notice An eSIM wallet always belongs to a device wallet, so ownership is never renounced
    /// @dev A zero owner makes sendETHToDeviceWallet revert and _addESIMWallet refuse this wallet
    ///      forever, so any ETH held here would be locked.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Completes a handover, moving `deviceWallet`, `owner()`, the price ceiling and the
    ///         admin allowance together
    /// @dev Clears the request first, so a second acceptance finds nothing. The ceiling and
    ///      allowance were the old owner's choices, so the new owner starts on the defaults.
    function _secureTransferOwnership() internal {
        address newOwner = newRequestedOwner;
        newRequestedOwner = address(0);
        deviceWallet = DeviceWallet(payable(newOwner));

        if(priceCapUSDCents != 0) {
            priceCapUSDCents = 0;
            emit PriceCapUSDCentsUpdated(0);
        }

        uint64 allowance = ESIMWalletFactory(eSIMWalletFactory).registry().defaultAdminAllowanceUSDCents();
        adminAllowanceUSDCents = allowance;
        emit AdminAllowanceUSDCentsUpdated(allowance);

        // Emits OwnershipTransferred, so do not emit it again here
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
    /// @dev A zero wallet ceiling means "follow the registry", not "no ceiling". The registry
    ///      default is kept non-zero by `Registry.initialize` and `setDefaultPriceCapUSDCents`.
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

    /// @notice Takes an admin charge out of what the admin may still charge this wallet
    /// @param _priceUSDCents Price being charged, in USD cents
    function _spendAdminAllowance(uint64 _priceUSDCents) private {
        uint64 remaining = adminAllowanceUSDCents;
        if(_priceUSDCents > remaining) revert Errors.AdminAllowanceExceeded(_priceUSDCents, remaining);

        unchecked {
            // checked just above: the price is at most what remains
            remaining -= _priceUSDCents;
        }
        adminAllowanceUSDCents = remaining;
        emit AdminAllowanceUSDCentsUpdated(remaining);
    }

    /// @notice The device wallet that owns this eSIM wallet
    /// @return The owning device wallet address
    function owner() public view override returns (address) {
        return OwnableUpgradeable.owner();
    }

    /// @notice Accepts plain ETH transfers, which is how the device wallet tops this wallet up
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}