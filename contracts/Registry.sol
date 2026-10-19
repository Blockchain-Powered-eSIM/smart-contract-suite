// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IPausable} from "./interfaces/IPausable.sol";
import {IRegistryAdmin} from "./interfaces/IRegistryAdmin.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {RegistryHelper} from "./RegistryHelper.sol";
import {LazyWalletRegistry} from "./LazyWalletRegistry.sol";
import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {PaymentAdapter, Asset} from "./payments/PaymentAdapter.sol";
import {Errors} from "./Errors.sol";

// Types
import {DataBundleDetails, Settlement} from "./CustomStructs.sol";

/// @notice Holds the protocol's roles and switches: admin, vault, pause flag and price ceiling
/// @dev Wallets are beacon proxies with no enumerable list, so one write here is the only way a
///      change reaches all of them in the same transaction.
///      `IPausable` and `IRegistryAdmin` let the compiler check what `ProtocolAdmin` calls, since a
///      mismatch would only show as a revert mid-incident. `enableAdmin` is left out on purpose,
///      so nothing invites a fast path for restoring a suspended key.
contract Registry is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    RegistryHelper,
    IPausable,
    IRegistryAdmin
{

    /// @notice Entry point contract address (one entryPoint per chain)
    IEntryPoint public entryPoint;

    /// @notice Address holding the admin role, whether or not its powers are currently live
    /// @dev The only copy, so a rotation reaches every reader at once and none keeps the old key.
    ///      Use `eSIMWalletAdmin()` to ask who may act: this keeps naming a suspended admin so the
    ///      suspension can be lifted without re-supplying the address.
    address public adminOfRecord;

    /// @notice Address of the vault that receives payments for the eSIM data bundles
    address public vault;

    /// @dev Retired copy of the upgrade authority, never read (`upgradeManager()` returns `owner()`).
    ///      Kept so the slots below do not shift on live proxies. Slither's `unused-state` and
    ///      `constable-states` are false here: deleting it or making it constant moves every slot.
    address private _retiredUpgradeManager;

    /// @notice Address of the admin to be appointed
    /// @dev Set by the owner, cleared on acceptance. While set the incumbent has no powers, so an
    ///      unaccepted handover leaves the role dormant rather than shared.
    address public newRequestedAdmin;

    /// @notice True while the protocol's guarded purchase and pull paths are stopped
    /// @dev Held here so one write reaches every wallet; they all read it on their guarded paths.
    bool public paused;

    /// @notice True while the admin's powers are suspended, leaving the address on the books
    /// @dev Packs beside `paused`. Suspending is instant through a guardian but lifting it is an
    ///      owner action that waits, so a compromised key cannot restore itself as fast.
    bool public adminDisabled;

    /// @notice Most an eSIM wallet may be charged for one data bundle, in USD cents, unless it sets
    ///         its own limit
    /// @dev Never zero, both setters refuse it: zero on a wallet means "follow the registry", so it
    ///      has no meaning here.
    uint64 public defaultPriceCapUSDCents;

    /// @notice Contract holding the accepted currencies
    address public paymentAdapter;

    /// @notice Payment references already spent, scoped per eSIM wallet
    /// @dev Held here so replay protection survives `setPaymentAdapter`. Keyed by
    ///      `keccak256(abi.encode(eSIMWallet, paymentReference))` so one wallet spending a reference
    ///      cannot burn it for another wallet's pending settlement.
    mapping(bytes32 scopedReference => bool used) public usedPaymentReferences;

    /// @notice What a new eSIM wallet lets the admin charge it in total, in USD cents
    /// @dev Copied into each wallet at deploy and handover, so a change here never moves an existing
    ///      wallet. Zero means new wallets take no admin charges.
    uint64 public defaultAdminAllowanceUSDCents;

    /// @notice Restricts a call to an eSIM wallet this registry has recorded
    modifier onlyESIMWallet() {
        if(isESIMWalletValid[msg.sender] == address(0)) {
            revert Errors.NotAProtocolESIMWallet(msg.sender);
        }
        _;
    }

    /// @notice Restricts a call to a device wallet this registry has recorded
    modifier onlyDeviceWallet() {
        if(!isDeviceWalletValid[msg.sender]) revert Errors.OnlyDeviceWallet();
        _;
    }

    /// @notice Restricts a call to the device wallet factory
    modifier onlyDeviceWalletFactory() {
        if(msg.sender != address(deviceWalletFactory)) revert Errors.OnlyDeviceWalletFactory();
        _;
    }

    /// @notice Restricts a call to the current eSIM wallet admin
    /// @dev Reads the accessor, not `adminOfRecord`, so a suspended admin is refused here too.
    modifier onlyESIMWalletAdmin() {
        if(msg.sender != eSIMWalletAdmin()) revert Errors.OnlyAdmin();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Disables initializers on the implementation contract
    /// @dev Otherwise anyone could initialize and own the implementation. The proxy is unaffected,
    ///      but an owned implementation is a trap for a later upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Wires the registry to the two factories and sets the protocol's addresses
    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    /// @param _deviceWalletFactory Factory that deploys device wallets
    /// @param _eSIMWalletFactory Factory that deploys eSIM wallets
    /// @param _entryPoint ERC-4337 EntryPoint singleton for this chain
    /// @param _defaultPriceCapUSDCents Starting price ceiling in USD cents. Non-zero, since zero
    ///        reads as "no ceiling" in `ESIMWallet._requirePriceWithinCap`.
    /// @param _defaultAdminAllowanceUSDCents Total the admin may charge each new eSIM wallet, in USD cents
    function initialize(
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager,
        address _deviceWalletFactory,
        address _eSIMWalletFactory,
        IEntryPoint _entryPoint,
        uint64 _defaultPriceCapUSDCents,
        uint64 _defaultAdminAllowanceUSDCents
    ) external initializer {
        if(_eSIMWalletAdmin == address(0)) revert Errors.ZeroAddress("_eSIMWalletAdmin");
        if(_vault == address(0)) revert Errors.ZeroAddress("_vault");
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");
        if(address(_entryPoint) == address(0)) revert Errors.ZeroAddress("_entryPoint");
        // Neither factory has a setter, so a zero here breaks lazy deploys and the factory caller
        // checks until an upgrade.
        if(_deviceWalletFactory == address(0)) revert Errors.ZeroAddress("_deviceWalletFactory");
        if(_eSIMWalletFactory == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactory");
        if(_defaultPriceCapUSDCents == 0) revert Errors.ZeroDataBundlePriceCap();

        adminOfRecord = _eSIMWalletAdmin;
        entryPoint = _entryPoint;
        vault = _vault;
        defaultPriceCapUSDCents = _defaultPriceCapUSDCents;
        defaultAdminAllowanceUSDCents = _defaultAdminAllowanceUSDCents;

        deviceWalletFactory = DeviceWalletFactory(_deviceWalletFactory);
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactory);

        __Ownable2Step_init();
        __Ownable_init(_upgradeManager);

        emit RegistryInitialized(
            _eSIMWalletAdmin,
            _vault,
            _upgradeManager,
            address(deviceWalletFactory),
            address(eSIMWalletFactory)
        );
        emit DefaultPriceCapUSDCentsUpdated(_defaultPriceCapUSDCents);
        emit DefaultAdminAllowanceUSDCentsUpdated(_defaultAdminAllowanceUSDCents);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin handover
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IRegistryAdmin
    /// @dev Owner, not admin: a compromised admin could never be replaced, and could hold the pause
    ///      on with no other key able to end it.
    ///      Nominating strips the incumbent at once (via `eSIMWalletAdmin()`), so the two never hold
    ///      the role together; keep nomination and acceptance close. Calling again overrides a
    ///      mistaken nomination, and naming the incumbent withdraws it and lifts a suspension.
    function requestAdminUpdate(address _newAdmin) external onlyOwner {
        if(_newAdmin == address(0)) revert Errors.ZeroAddress("_newAdmin");

        if(_newAdmin == adminOfRecord) {
            address revokedAddress = newRequestedAdmin;
            newRequestedAdmin = address(0);
            adminDisabled = false;
            emit AdminUpdateRevoked(msg.sender, revokedAddress);
        }
        else {
            newRequestedAdmin = _newAdmin;
            emit AdminUpdateRequested(adminOfRecord, _newAdmin);
        }
    }

    /// @notice Takes up the admin role, callable only by the nominated address
    /// @dev Clears the suspension too: it targets a key, not the role, so a fresh key accepting
    ///      ends the incident.
    /// @return Address of the new admin
    function acceptAdminUpdate() external returns (address) {
        if(msg.sender != newRequestedAdmin) revert Errors.OnlyRequestedAdmin(newRequestedAdmin);

        adminOfRecord = msg.sender;

        newRequestedAdmin = address(0);
        adminDisabled = false;

        emit AdminUpdated(msg.sender);

        return msg.sender;
    }

    /// @inheritdoc IRegistryAdmin
    /// @dev Every gate reads `eSIMWalletAdmin()`, which returns zero from here, so one write closes
    ///      them all. Owner gated so `ProtocolAdmin` can give a guardian an instant route. A repeat
    ///      reverts so a guardian mid-incident never believes it acted when it did not.
    function disableAdmin() external onlyOwner {
        if(adminDisabled) revert Errors.AdminAlreadyDisabled();

        adminDisabled = true;
        emit AdminDisabled(adminOfRecord, msg.sender);
    }

    /// @notice Hands a suspended admin its powers back
    /// @dev Owner only with no instant route, so a compromised key cannot undo its suspension as
    ///      fast as it is applied. An outstanding handover still keeps the incumbent powerless;
    ///      withdraw it with `requestAdminUpdate` naming the incumbent.
    function enableAdmin() external onlyOwner {
        if(!adminDisabled) revert Errors.AdminNotDisabled();

        adminDisabled = false;
        emit AdminEnabled(adminOfRecord, msg.sender);
    }

    /// @notice Admin address every gated call in the protocol is checked against
    /// @dev Zero while suspended or while a handover is outstanding. `msg.sender` is never zero, so
    ///      both states close every gate at once.
    /// @return The address that may act as admin right now, or zero if nobody may
    function eSIMWalletAdmin() public view returns (address) {
        if(adminDisabled || newRequestedAdmin != address(0)) return address(0);

        return adminOfRecord;
    }

    // ---------------------------------------------------------------------------------------------
    // Vault
    // ---------------------------------------------------------------------------------------------

    /// @notice Points every data bundle payment at a different vault
    /// @dev Owner, not admin: every payment lands here, so moving it belongs behind the upgrade
    ///      delay. Device wallets read `vault` on every purchase, so one write reaches all of them.
    /// @param _newVaultAddress Address that receives payments for the data bundles from now on
    /// @return The vault address now in force
    function updateVaultAddress(address _newVaultAddress) external onlyOwner returns (address) {
        if(_newVaultAddress == address(0)) revert Errors.ZeroAddress("_newVaultAddress");
        if(vault == _newVaultAddress) revert Errors.VaultUnchanged(vault);

        vault = _newVaultAddress;
        emit VaultAddressUpdated(vault);

        return vault;
    }

    // ---------------------------------------------------------------------------------------------
    // Pause and price ceiling
    // ---------------------------------------------------------------------------------------------

    /// @notice Stops the token purchase and pull paths on every device wallet and eSIM wallet
    /// @dev The admin trips it and the owner clears it: the hot key must act fast, but holding the
    ///      release too would let one key freeze user funds indefinitely. The owner can also trip
    ///      it, so a guardian can pause through `ProtocolAdmin` while the admin is suspended. A
    ///      pause never reaches a wallet owner's own `execute`, so users can still spend their ETH.
    /// @inheritdoc IPausable
    function pause() external {
        if(msg.sender != eSIMWalletAdmin() && msg.sender != owner()) revert Errors.OnlyAdmin();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IPausable
    /// @dev Owner only, see `pause`
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Reverts while the protocol is paused
    /// @dev Wallets call this instead of reading `paused`, so the revert reason is the same
    ///      everywhere.
    function requireNotPaused() external view {
        if(paused) revert Errors.ProtocolPaused();
    }

    /// @notice Sets the price ceiling eSIM wallets fall back to when they hold none of their own
    /// @dev Owner, not admin: the admin is the party this limits. Zero is refused because it reads
    ///      as "no ceiling" in `ESIMWallet._requirePriceWithinCap` for wallets without their own.
    /// @param _cap Maximum price in USD cents, non-zero
    function setDefaultPriceCapUSDCents(uint64 _cap) external onlyOwner {
        if(_cap == 0) revert Errors.ZeroDataBundlePriceCap();

        defaultPriceCapUSDCents = _cap;
        emit DefaultPriceCapUSDCentsUpdated(_cap);
    }

    /// @notice Sets the admin allowance new eSIM wallets start with
    /// @dev Owner, not admin: the admin is the party this limits. Existing wallets keep theirs.
    /// @param _allowance Total the admin may charge each new eSIM wallet, in USD cents
    function setDefaultAdminAllowanceUSDCents(uint64 _allowance) external onlyOwner {
        defaultAdminAllowanceUSDCents = _allowance;
        emit DefaultAdminAllowanceUSDCentsUpdated(_allowance);
    }

    /// @notice Points this registry at the payment adapter
    /// @dev Owner, not admin: the adapter decides where money goes. Spent payment references live
    ///      on this registry, so they survive a swap.
    /// @param _paymentAdapter Address of the payment adapter
    function setPaymentAdapter(address _paymentAdapter) external onlyOwner {
        if(_paymentAdapter == address(0)) revert Errors.ZeroAddress("_paymentAdapter");
        if(_paymentAdapter == paymentAdapter) revert Errors.PaymentAdapterUnchanged(_paymentAdapter);

        paymentAdapter = _paymentAdapter;
        emit PaymentAdapterUpdated(_paymentAdapter);
    }

    // ---------------------------------------------------------------------------------------------
    // Purchases paid for outside the protocol
    // ---------------------------------------------------------------------------------------------

    /// @notice Spends a payment reference for an eSIM wallet paying with an accepted ERC-20
    /// @dev Scoped to `msg.sender`, so this and `recordSettledPurchase` cannot spend the same
    ///      reference once on each for the same wallet.
    /// @param _paymentReference Hash tying the purchase to the offchain order behind it
    function consumePaymentReference(bytes32 _paymentReference) external onlyESIMWallet {
        _consumePaymentReference(msg.sender, _paymentReference);
    }

    /// @notice Records a data bundle paid for through an external wallet or a card
    /// @dev No money moves here. The admin's claim is bounded by the price cap, a once-only payment
    ///      reference, and a settlement other than `DeviceWallet`. Written here, not by the adapter,
    ///      because eSIM wallets accept history only from this address.
    /// @param _eSIMWallet Wallet the purchase belongs to
    /// @param _dataBundleDetail The purchase, priced in USD cents like everywhere else
    /// @param _asset Symbol of the currency the user paid in
    /// @param _tokenAmount What the user actually paid, in that currency's smallest unit. Recorded
    ///        for offchain matching, never checked: it and the price both come from the admin.
    /// @param _paymentReference Hash tying this purchase to its offchain payment intent
    function recordSettledPurchase(
        address _eSIMWallet,
        DataBundleDetails calldata _dataBundleDetail,
        bytes32 _asset,
        uint256 _tokenAmount,
        bytes32 _paymentReference
    ) external onlyESIMWalletAdmin {
        if(paused) revert Errors.ProtocolPaused();
        if(isESIMWalletValid[_eSIMWallet] == address(0)) {
            revert Errors.NotAProtocolESIMWallet(_eSIMWallet);
        }
        if(_dataBundleDetail.id == bytes32(0)) revert Errors.EmptyDataBundleID();
        if(_dataBundleDetail.priceUSDCents == 0) revert Errors.ZeroDataBundlePrice();

        // This contract never sees the money move, so it must not be able to say it did.
        if(_dataBundleDetail.settlement == Settlement.DeviceWallet) {
            revert Errors.SettlementNotAsserted();
        }

        _requireLazyHistoryCopied(_eSIMWallet);

        Asset memory asset = PaymentAdapter(_requirePaymentAdapter()).resolveAsset(_asset);
        _consumePaymentReference(_eSIMWallet, _paymentReference);

        ESIMWallet(payable(_eSIMWallet)).recordSettledPurchase(_dataBundleDetail);

        emit DataBundleSettled(
            _eSIMWallet,
            _dataBundleDetail.id,
            _dataBundleDetail.priceUSDCents,
            _dataBundleDetail.settlement,
            _asset,
            asset.token,
            _tokenAmount,
            _paymentReference
        );
    }

    /// @notice Refuses a new entry while older history is still waiting to be copied in
    /// @dev Otherwise the new entry lands before the older ones and the history is out of order.
    ///      Enforced here because the backend retries whole steps on failure. External so wallets
    ///      can run it on their own paths that see the money move.
    /// @param _eSIMWallet Wallet being appended to
    function requireLazyHistoryCopied(address _eSIMWallet) external view {
        _requireLazyHistoryCopied(_eSIMWallet);
    }

    /// @notice Refuses a new entry while older history is still waiting to be copied in
    /// @dev See `requireLazyHistoryCopied`.
    /// @param _eSIMWallet Wallet being appended to
    function _requireLazyHistoryCopied(address _eSIMWallet) private view {
        if(lazyWalletRegistry == address(0)) return;

        string memory eSIMIdentifier = ESIMWallet(payable(_eSIMWallet)).eSIMUniqueIdentifier();
        if(bytes(eSIMIdentifier).length == 0) return;

        uint256 outstanding = LazyWalletRegistry(lazyWalletRegistry).outstandingHistoryEntries(eSIMIdentifier);
        if(outstanding != 0) revert Errors.HistoryNotFullyCopied(eSIMIdentifier, outstanding);
    }

    /// @notice Spends a payment reference for one eSIM wallet, refusing one already spent by it
    /// @dev Here rather than on the adapter, for the reasons on `usedPaymentReferences`.
    /// @param _eSIMWallet Wallet the reference is being spent for
    /// @param _paymentReference Hash tying this purchase to the offchain payment behind it
    function _consumePaymentReference(address _eSIMWallet, bytes32 _paymentReference) private {
        if(_paymentReference == bytes32(0)) revert Errors.EmptyPaymentReference();

        bytes32 scopedReference = keccak256(abi.encode(_eSIMWallet, _paymentReference));
        if(usedPaymentReferences[scopedReference]) revert Errors.PaymentReferenceAlreadyUsed(_paymentReference);

        usedPaymentReferences[scopedReference] = true;
        emit PaymentReferenceConsumed(_eSIMWallet, _paymentReference);
    }

    /// @notice The payment adapter, or a revert if none is set yet
    function _requirePaymentAdapter() private view returns (address) {
        address adapter = paymentAdapter;
        if(adapter == address(0)) revert Errors.PaymentAdapterNotSet();

        return adapter;
    }

    // ---------------------------------------------------------------------------------------------
    // Device wallet registration
    // ---------------------------------------------------------------------------------------------

    /// @notice Records a device wallet the factory has just deployed
    /// @param _deviceWallet Address of the device wallet
    /// @param _deviceUniqueIdentifier String unique identifier associated with the device wallet
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning the wallet
    function updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) external onlyDeviceWalletFactory {
        _updateDeviceWalletInfo(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    /// @notice Called by a device wallet when the P256 key that owns it is replaced
    /// @dev Without this the registry keeps the retired key and the new one could be claimed by a
    ///      second wallet, breaking one key to one wallet. The key must be the one the wallet holds,
    ///      or a wallet could claim a stranger's key through `execute` and block them registering.
    /// @param _newOwnerKey X,Y co-ordinates of the P256 key taking over
    function updateDeviceWalletOwnerKey(bytes32[2] memory _newOwnerKey) external onlyDeviceWallet {
        DeviceWallet wallet = DeviceWallet(payable(msg.sender));
        if(wallet.owner(0) != _newOwnerKey[0] || wallet.owner(1) != _newOwnerKey[1]) {
            revert Errors.OwnerKeyNotHeldByWallet(msg.sender);
        }

        _updateDeviceWalletOwnerKey(msg.sender, _newOwnerKey);
    }

    /// @notice Refuses a device identifier a fiat user's eSIMs are already waiting on
    /// @dev Called by the ordinary deploy route. Taking such an identifier strands the lazy user:
    ///      history copy, wallet deploy and device switch all refuse an identifier with a wallet.
    ///      Passes while `lazyWalletRegistry` is unset, since nothing can be reserved before then.
    /// @param _deviceUniqueIdentifier Identifier the caller is about to take
    function requireDeviceIdentifierNotReserved(string calldata _deviceUniqueIdentifier) external view {
        if(lazyWalletRegistry == address(0)) return;

        if(LazyWalletRegistry(lazyWalletRegistry).isDeviceIdentifierReserved(_deviceUniqueIdentifier)) {
            revert Errors.DeviceIdentifierReservedForLazyWallet(_deviceUniqueIdentifier);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM wallet binding
    // ---------------------------------------------------------------------------------------------

    /// @notice Binds an eSIM wallet to the calling device wallet and settles any outstanding transfer
    /// @dev The only writer of the association, which once set always names a device wallet, so
    ///      zero is refused; a release raises standby via `toggleESIMWalletStandbyStatus` instead.
    ///      Authorization reads `ESIMWallet.owner()` because the association can lag behind an
    ///      accepted ownership transfer. Standby is cleared here since both facts change together.
    /// @param _eSIMWalletAddress Address of the eSIM wallet
    /// @param _deviceWalletAddress The device wallet taking it on, which must be the caller
    function bindESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) external onlyDeviceWallet {
        if(_deviceWalletAddress == address(0)) revert Errors.ZeroAddress("_deviceWalletAddress");

        // Any contract can fake the eSIM wallet's own answers below. Only the factory can vouch for
        // it, so without this a device wallet could register any address as an eSIM wallet.
        if(!eSIMWalletFactory.isESIMWalletDeployed(_eSIMWalletAddress)) {
            revert Errors.NotAProtocolESIMWallet(_eSIMWalletAddress);
        }

        if(ESIMWallet(payable(_eSIMWalletAddress)).owner() != msg.sender) {
            revert Errors.NotTheESIMWalletOwnerOrItsDeviceWallet(_eSIMWalletAddress);
        }

        // Naming any other address would move the wallet without an ownership transfer
        if(_deviceWalletAddress != msg.sender) {
            revert Errors.NotTheAssociatedDeviceWallet(_eSIMWalletAddress, _deviceWalletAddress);
        }

        // No rebinding while an ownership transfer is pending
        address pendingOwner = ESIMWallet(payable(_eSIMWalletAddress)).newRequestedOwner();
        if(pendingOwner != address(0)) {
            revert Errors.ESIMWalletOwnershipTransferPending(_eSIMWalletAddress, pendingOwner);
        }

        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
        emit UpdatedDeviceWalletAssociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);

        // Only written on a change, so a wallet that was never released emits nothing here
        if(isESIMWalletOnStandby[_eSIMWalletAddress]) {
            isESIMWalletOnStandby[_eSIMWalletAddress] = false;
            emit ESIMWalletSetOnStandby(_eSIMWalletAddress, false, msg.sender);
        }
    }

    /// @notice Binds an eSIM identifier to an eSIM wallet and writes it onto the wallet
    /// @dev Admin only: which identifier a wallet is owed is known offchain, and a device wallet
    ///      could fake any onchain proof through `execute`. Reserved identifiers are refused even on
    ///      their own device, because the lazy route assigns them and taking one strands that batch.
    /// @param _eSIMWalletAddress Wallet receiving the identifier
    /// @param _eSIMUniqueIdentifier Identifier being assigned
    /// @return The identifier now on the wallet
    function assignESIMIdentifier(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) external onlyESIMWalletAdmin returns (string memory) {
        address lazy = lazyWalletRegistry;
        if(lazy != address(0) && LazyWalletRegistry(lazy).isESIMIdentifierReserved(_eSIMUniqueIdentifier)) {
            revert Errors.ESIMIdentifierReservedForLazyWallet(_eSIMUniqueIdentifier);
        }

        return _assignESIMIdentifier(_eSIMWalletAddress, _eSIMUniqueIdentifier);
    }

    /// @notice Marks an eSIM wallet as being moved from one device wallet to another, or cancels that
    /// @dev Only the flag moves; the association keeps naming the last device wallet, so raising
    ///      standby on a wallet the caller still holds is normal. Authorization reads
    ///      `ESIMWallet.owner()` for the same reason as `bindESIMWallet`.
    /// @param _eSIMWalletAddress Address of the eSIM wallet
    /// @param _isOnStandby True while a transfer is outstanding, false once it is settled or revoked
    function toggleESIMWalletStandbyStatus(
        address _eSIMWalletAddress,
        bool _isOnStandby
    ) public onlyDeviceWallet {
        if(ESIMWallet(payable(_eSIMWalletAddress)).owner() != msg.sender) {
            revert Errors.NotTheESIMWalletOwnerOrItsDeviceWallet(_eSIMWalletAddress);
        }

        isESIMWalletOnStandby[_eSIMWalletAddress] = _isOnStandby;
        emit ESIMWalletSetOnStandby(_eSIMWalletAddress, _isOnStandby, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership, wiring and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Points the registry at the lazy wallet registry, which is deployed after it
    /// @param _lazyWalletRegistry Address of the lazy wallet registry
    /// @return The address now in force
    function addOrUpdateLazyWalletRegistryAddress(
        address _lazyWalletRegistry
    ) public onlyOwner returns (address) {
        if(_lazyWalletRegistry == address(0)) revert Errors.ZeroAddress("_lazyWalletRegistry");

        lazyWalletRegistry = _lazyWalletRegistry;

        emit UpdatedLazyWalletRegistryAddress(_lazyWalletRegistry);

        return lazyWalletRegistry;
    }

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only upgrade route, so renouncing would freeze this logic for good.
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

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    /// @dev Reads through to the owner, which `_authorizeUpgrade` checks, since a separate copy
    ///      could only disagree with it.
    /// @return The address that may upgrade this contract
    function upgradeManager() public view returns (address) {
        return owner();
    }
}
