pragma solidity 0.8.36;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {RegistryHelper} from "./RegistryHelper.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {Errors} from "./Errors.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract Registry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, RegistryHelper {

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

    modifier onlyDeviceWallet() {
        if(isDeviceWalletValid[msg.sender] != true) revert Errors.OnlyDeviceWallet();
        _;
    }

    modifier onlyDeviceWalletFactory() {
        if(msg.sender != address(deviceWalletFactory)) revert Errors.OnlyDeviceWalletFactory();
        _;
    }

    modifier onlyESIMWalletAdmin() {
        if(msg.sender != eSIMWalletAdmin) revert Errors.OnlyAdmin();
        _;
    }

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation and own it. The proxy is unaffected either way, but an
    ///      owned implementation is a trap for any later upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and there is no other route to
    ///      replace this implementation. Renouncing would freeze the contract on its current logic
    ///      permanently.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    /// @dev Reads through to the owner rather than holding its own copy. `_authorizeUpgrade` is
    ///      gated on `onlyOwner`, so the owner is the upgrade authority by definition and a second
    ///      copy could only ever disagree with it.
    function upgradeManager() public view returns (address) {
        return owner();
    }

    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize(
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager,
        address _deviceWalletFactory,
        address _eSIMWalletFactory,
        IEntryPoint _entryPoint
    ) external initializer {
        require(_eSIMWalletAdmin != address(0), "_eSIMWalletAdmin 0");
        require(_vault != address(0), "_vault 0");
        require(_upgradeManager != address(0), "_upgradeManager 0");
        require(address(_entryPoint) != address(0), "_entryPoint 0");
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

    /// @notice 2-step admin update. The current admin nominates, the nominee accepts.
    /// @dev Deliberately does not check for an existing request. If the current admin nominates an
    ///      unintended address, calling this again overrides it. Nominating the current admin
    ///      revokes any outstanding request.
    /// @param _newAdmin Address of the recipient to receive the admin role
    function requestAdminUpdate(address _newAdmin) external onlyESIMWalletAdmin {
        require(_newAdmin != address(0), "Admin address cannot be zero");

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

    /// @notice Function to update the admin address
    /// @return Address of the new admin
    function acceptAdminUpdate() external returns (address) {
        require(msg.sender == newRequestedAdmin, "Unauthorised");

        eSIMWalletAdmin = msg.sender;
        emit AdminUpdated(msg.sender);

        // Reset the requested admin to address(0) for further role transfer
        newRequestedAdmin = address(0);

        return eSIMWalletAdmin;
    }

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

    /// @notice Function to add or update the lazy wallet registry address
    function addOrUpdateLazyWalletRegistryAddress(
        address _lazyWalletRegistry
    ) public onlyOwner returns (address) {
        require(_lazyWalletRegistry != address(0), "_lazyWalletRegistry 0");

        lazyWalletRegistry = _lazyWalletRegistry;

        emit UpdatedLazyWalletRegistryAddress(_lazyWalletRegistry);

        return lazyWalletRegistry;
    }

    function updateDeviceWalletAssociatedWithESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) external onlyDeviceWallet {
        require(
            ESIMWallet(payable(_eSIMWalletAddress)).owner() == msg.sender ||
            isESIMWalletValid[_eSIMWalletAddress] == msg.sender,
            "Unauthorise caller or already assigned"
        );
        // address(0) => owner removed eSIM wallet from device wallet
        // msg.sender => new device wallet added the eSIM wallet
        // any other address => Unauthorised: user is trying to change owner without initiating transfer of ownership
        require(
            _deviceWalletAddress == address(0) || _deviceWalletAddress == msg.sender,
            "Transfer ownership first"
        );
        // Owner cannot change device wallet address in the middle of ownership transfer
        require(
            ESIMWallet(payable(_eSIMWalletAddress)).newRequestedOwner() == address(0),
            "Unauthorised action"
        );

        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
        emit UpdatedDeviceWalletassociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);
    }

    /// @dev For all the device wallets deployed by the esim wallet admin using the device wallet factory,
    ///      update the mappings
    /// @param _deviceWallet Address of the device wallet
    /// @param _deviceUniqueIdentifier String unique identifier associated with the device wallet
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

    /// @notice Update eSIM standby status when being moved from one device wallet to another
    /// @param _eSIMWalletAddress Address of the eSIM wallet
    /// @param _isOnStandby Set to true when no device wallet is associated, false otherwise
    function toggleESIMWalletStandbyStatus(
        address _eSIMWalletAddress,
        bool _isOnStandby
    ) public onlyDeviceWallet {
        require(isESIMWalletValid[_eSIMWalletAddress] == msg.sender, "Unauthorised caller");

        isESIMWalletOnStandby[_eSIMWalletAddress] = _isOnStandby;
        emit ESIMWalletSetOnStandby(_eSIMWalletAddress, _isOnStandby, msg.sender);
    }
}
