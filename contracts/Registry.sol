// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IPausable} from "./interfaces/IPausable.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {RegistryHelper} from "./RegistryHelper.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {Errors} from "./Errors.sol";

/// @notice Single source of truth for who is who in the protocol, and the switchboard the wallets
///         read on every guarded path
/// @dev Holds the admin address, the vault, the pause flag and the price ceiling in one place.
///      Device wallets and eSIM wallets are beacon proxies tracked by mappings with no enumerable
///      list, so there is no way to write a value into each of them: one write here is how a change
///      reaches all of them in the same transaction.
///
///      `IPausable` is declared so the compiler checks the one signature `ProtocolAdmin` calls
///      through it. A guardian releases a pause with no delay, so the two drifting apart would only
///      show as a revert during an incident. `pause()` stays outside the interface deliberately: it
///      is the hot admin key's lever, while releasing it is the timelock's.
contract Registry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RegistryHelper, IPausable {

    /// @notice Entry point contract address (one entryPoint per chain)
    IEntryPoint public entryPoint;

    /// @notice Admin address of the eSIM wallet project
    /// @dev The only copy in the protocol. `DeviceWalletFactory`, `DeviceWallet`, `ESIMWallet` and
    ///      `LazyWalletRegistry` all read it from here, so rotating it below reaches every one of
    ///      them in the same transaction. Holding it in more than one place is what previously let
    ///      a rotation update some readers and leave the rest authorising the retired key.
    address public eSIMWalletAdmin;

    /// @notice Address of the vault that receives payments for the eSIM data bundles
    address public vault;

    /// @dev Slot that used to hold a copy of the upgrade authority. It was written once in
    ///      `initialize` and had no setter, so it kept naming the deploy-time address once
    ///      ownership moved on. Kept so nothing below it shifts on the live proxies. Never read;
    ///      `upgradeManager()` returns `owner()` instead.
    ///
    ///      Slither raises `unused-state` and `constable-states` here. Both are false: occupying
    ///      the slot is the whole job, and either change takes it out of storage and moves every
    ///      variable below it.
    address private _retiredUpgradeManager;

    /// @notice Address of the admin to be appointed
    /// @dev Only the current admin can request the transfer. The nominated address has to accept
    ///      it, and this resets once they do.
    address public newRequestedAdmin;

    /// @notice True while the ETH-moving paths are stopped protocol-wide
    /// @dev Held here for the same reason the admin address is: device wallets and eSIM wallets are
    ///      beacon proxies tracked by a mapping with no enumerable list, so there is no way to
    ///      write a flag into each of them. Both already read this contract on their guarded paths,
    ///      so one write here reaches every wallet in the same transaction.
    bool public paused;

    /// @notice Most an eSIM wallet may be charged for one data bundle unless it sets its own limit
    /// @dev Held here rather than only on each wallet because a wallet deployed before this existed
    ///      reads zero, and there is no enumerable list to write a value into. Zero here means no
    ///      ceiling, which is what every wallet had before, so setting this once is what closes the
    ///      exposure for all of them at the same time.
    uint256 public defaultDataBundlePriceCap;

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
    /// @dev The hot key the backend signs with, not the owner. It can trip the pause but not
    ///      release it, and cannot upgrade anything.
    modifier onlyESIMWalletAdmin() {
        if(msg.sender != eSIMWalletAdmin) revert Errors.OnlyAdmin();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation and own it. The proxy is unaffected either way, but an
    ///      owned implementation is a trap for any later upgrade that adds an outward call.
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
    function initialize(
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager,
        address _deviceWalletFactory,
        address _eSIMWalletFactory,
        IEntryPoint _entryPoint
    ) external initializer {
        if(_eSIMWalletAdmin == address(0)) revert Errors.ZeroAddress("_eSIMWalletAdmin");
        if(_vault == address(0)) revert Errors.ZeroAddress("_vault");
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");
        if(address(_entryPoint) == address(0)) revert Errors.ZeroAddress("_entryPoint");
        // Neither factory has a setter anywhere in the protocol, so a zero here is permanent.
        // It would leave deployLazyWalletAndSetESIMIdentifier calling into address(0),
        // onlyDeviceWalletFactory unable to match any sender, and the factory branch of
        // ESIMWalletFactory's caller check dead, recoverable only by an upgrade.
        if(_deviceWalletFactory == address(0)) revert Errors.ZeroAddress("_deviceWalletFactory");
        if(_eSIMWalletFactory == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactory");

        eSIMWalletAdmin = _eSIMWalletAdmin;
        entryPoint = _entryPoint;
        vault = _vault;

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
    }

    // ---------------------------------------------------------------------------------------------
    // Admin handover
    // ---------------------------------------------------------------------------------------------

    /// @notice Nominates the next eSIM wallet admin, who then has to accept
    /// @dev Deliberately does not check for an existing request. If the current admin nominates an
    ///      unintended address, calling this again overrides it. Nominating the current admin
    ///      revokes any outstanding request.
    /// @param _newAdmin Address of the recipient to receive the admin role
    function requestAdminUpdate(address _newAdmin) external onlyESIMWalletAdmin {
        if(_newAdmin == address(0)) revert Errors.ZeroAddress("_newAdmin");

        if(_newAdmin == eSIMWalletAdmin) {
            address revokedAddress = newRequestedAdmin;
            newRequestedAdmin = address(0);
            emit AdminUpdateRevoked(msg.sender, revokedAddress);
        }
        else {
            newRequestedAdmin = _newAdmin;
            emit AdminUpdateRequested(eSIMWalletAdmin, _newAdmin);
        }
    }

    /// @notice Takes up the admin role, callable only by the nominated address
    /// @return Address of the new admin
    function acceptAdminUpdate() external returns (address) {
        if(msg.sender != newRequestedAdmin) revert Errors.OnlyRequestedAdmin(newRequestedAdmin);

        eSIMWalletAdmin = msg.sender;
        emit AdminUpdated(msg.sender);

        // Reset the requested admin to address(0) for further role transfer
        newRequestedAdmin = address(0);

        return eSIMWalletAdmin;
    }

    // ---------------------------------------------------------------------------------------------
    // Pause and price ceiling
    // ---------------------------------------------------------------------------------------------

    /// @notice Stops the ETH-moving paths on every device wallet and eSIM wallet
    /// @dev The admin trips this and the owner clears it. The admin key signs backend batches all
    ///      day and is the one watching, so it needs to act without waiting; giving it the release
    ///      as well would let a single hot key hold user funds indefinitely. Neither key can reach
    ///      an owner's own `execute`, so a pause never stops someone spending their own ETH.
    function pause() external onlyESIMWalletAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Releases the pause
    /// @dev Owner only, see `pause`
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Reverts while the protocol is paused
    /// @dev Device wallets and eSIM wallets call this rather than reading `paused` and reverting
    ///      themselves, so the revert reason is the same wherever it comes from.
    function requireNotPaused() external view {
        if(paused) revert Errors.ProtocolPaused();
    }

    /// @notice Sets the price ceiling eSIM wallets fall back to when they hold none of their own
    /// @dev Owner and not admin, deliberately. The admin is the party this ceiling constrains, so
    ///      letting it raise its own limit would leave the ceiling meaningless. Setting zero
    ///      restores the unlimited behaviour for every wallet that has not set its own.
    /// @param _cap Maximum price in wei, or zero for no ceiling
    function setDefaultDataBundlePriceCap(uint256 _cap) external onlyOwner {
        defaultDataBundlePriceCap = _cap;
        emit DefaultDataBundlePriceCapUpdated(_cap);
    }

    // ---------------------------------------------------------------------------------------------
    // Device wallet registration
    // ---------------------------------------------------------------------------------------------

    /// @notice Records a device wallet the factory has just deployed
    /// @dev Factory only. Writes the identifier, the address and the owner key together, so the
    ///      three stay consistent with each other.
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
    /// @dev Only the wallet itself can move its own bindings, so `msg.sender` is the subject
    ///      rather than a parameter. Without this the registry keeps naming the retired key after
    ///      a rotation, and the key taking over stays unregistered and can be claimed by a second
    ///      wallet, which breaks the one key to one wallet rule the deploy paths enforce.
    /// @param _newOwnerKey X,Y co-ordinates of the P256 key taking over
    function updateDeviceWalletOwnerKey(bytes32[2] memory _newOwnerKey) external onlyDeviceWallet {
        _updateDeviceWalletOwnerKey(msg.sender, _newOwnerKey);
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM wallet binding
    // ---------------------------------------------------------------------------------------------

    /// @notice Binds an eSIM wallet to the calling device wallet and settles any outstanding transfer
    /// @dev The association is a registration: once the registry has named a device wallet for an
    ///      eSIM wallet it always names one, and this is the only place it moves. Zero is refused
    ///      for that reason, so releasing an eSIM wallet raises the standby flag through
    ///      `toggleESIMWalletStandbyStatus` and leaves the association naming the last device
    ///      wallet that held it.
    ///
    ///      Taking a wallet on is the one moment both facts change together, which is why the flag
    ///      is cleared here rather than in a second call. Nothing else in this function reads it.
    /// @param _eSIMWalletAddress Address of the eSIM wallet
    /// @param _deviceWalletAddress The device wallet taking it on, which must be the caller
    function bindESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) external onlyDeviceWallet {
        if(_deviceWalletAddress == address(0)) revert Errors.ZeroAddress("_deviceWalletAddress");

        address associated = isESIMWalletValid[_eSIMWalletAddress];

        if(
            ESIMWallet(payable(_eSIMWalletAddress)).owner() != msg.sender &&
            associated != msg.sender
        ) {
            revert Errors.NotTheESIMWalletOwnerOrItsDeviceWallet(_eSIMWalletAddress);
        }

        // A device wallet can only bind an eSIM wallet to itself. Naming any other address is an
        // attempt to move it without going through the ownership transfer.
        if(_deviceWalletAddress != msg.sender) {
            revert Errors.NotTheAssociatedDeviceWallet(_eSIMWalletAddress, _deviceWalletAddress);
        }

        // Owner cannot change device wallet address in the middle of ownership transfer
        address pendingOwner = ESIMWallet(payable(_eSIMWalletAddress)).newRequestedOwner();
        if(pendingOwner != address(0)) {
            revert Errors.ESIMWalletOwnershipTransferPending(_eSIMWalletAddress, pendingOwner);
        }

        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
        emit UpdatedDeviceWalletassociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);

        // Only written on a change, so a wallet that was never released emits nothing here
        if(isESIMWalletOnStandby[_eSIMWalletAddress]) {
            isESIMWalletOnStandby[_eSIMWalletAddress] = false;
            emit ESIMWalletSetOnStandby(_eSIMWalletAddress, false, msg.sender);
        }
    }

    /// @notice Marks an eSIM wallet as being moved from one device wallet to another, or cancels that
    /// @dev Only the flag moves here. The association is a separate fact and keeps naming the device
    ///      wallet that last held the eSIM wallet, so raising standby on a wallet this caller still
    ///      holds is the ordinary case rather than a contradiction.
    /// @param _eSIMWalletAddress Address of the eSIM wallet
    /// @param _isOnStandby True while a transfer is outstanding, false once it is settled or revoked
    function toggleESIMWalletStandbyStatus(
        address _eSIMWalletAddress,
        bool _isOnStandby
    ) public onlyDeviceWallet {
        address associated = isESIMWalletValid[_eSIMWalletAddress];
        if(associated != msg.sender) {
            revert Errors.NotTheAssociatedDeviceWallet(_eSIMWalletAddress, associated);
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
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and there is no other route to
    ///      replace this implementation. Renouncing would freeze the contract on its current logic
    ///      permanently.
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
    /// @dev Reads through to the owner rather than holding its own copy. `_authorizeUpgrade` is
    ///      gated on `onlyOwner`, so the owner is the upgrade authority by definition and a second
    ///      copy could only ever disagree with it.
    function upgradeManager() public view returns (address) {
        return owner();
    }
}
