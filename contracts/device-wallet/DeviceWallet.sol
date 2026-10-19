// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../Errors.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Account4337} from "../aa-helper/Account4337.sol";
import {Registry} from "../Registry.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "../esim-wallet/ESIMWallet.sol";
import {P256Verifier} from "../P256Verifier.sol";

/// @notice A user's device: an ERC-4337 account that owns the eSIM wallets bought for that device
/// @dev Beacon proxy owned by the user's P256 key. Key rotation also updates the registry, so
///      the two records cannot drift apart.
contract DeviceWallet is Initializable, ReentrancyGuardUpgradeable, Account4337 {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM wallet factory address
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Set to true if the eSIM wallet belongs to this device wallet
    mapping(address eSIMWalletAddress => bool isValid) public isValidESIMWallet;

    /// @notice Tracks if an associated eSIM wallet may pull this wallet's tokens
    /// @dev One flag for all tokens: a wallet trusted with funds can drain them anyway, so
    ///      per-token flags would cost signatures and limit nothing.
    mapping(address eSIMWalletAddress => bool isAllowedToPullFunds) public canPullFunds;

    /// @notice Emitted when owner updates an eSIM wallet's access to this wallet's money
    event FundsAccessUpdated(address indexed _eSIMWalletAddress, bool _hasAccessToFunds);

    /// @notice Emitted when an associated eSIM wallet pulls an ERC-20 from this wallet
    event TokenSent(address indexed _token, address indexed _eSIMWalletAddress, uint256 _amount);

    /// @notice Emitted when eSIM wallet is added to this Device Wallet
    event ESIMWalletAdded(address indexed _eSIMWalletAddress, bool _hasAccessToFunds, address indexed _caller);

    /// @notice Emitted when the eSIM wallet is removed from this Device Wallet
    event ESIMWalletRemoved(address indexed _eSIMWalletAddress, address indexed _deviceWalletAddress, address indexed _caller);

    /// @notice Emitted when the eSIM wallet being removed has no ETH to call back
    event NoETHToCallback();

    /// @notice Emitted when the eSIM being removed sends back ETH to this device wallet
    event ETHCalledBack(uint256 _amount);

    /// @notice Reverts unless the caller is the registry, the device wallet factory, this wallet
    ///         itself, or a protocol eSIM wallet re-adding itself
    /// @dev The self-add branch trusts the eSIM wallet's `owner()` only because the factory
    ///      deployed it. The registry is not asked, since it lags behind a handover not yet bound.
    function _onlyRegistryOrDeviceWalletFactoryOrOwner(address _eSIMWalletAddress) private view {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            msg.sender != address(this) &&
            !(msg.sender == _eSIMWalletAddress && eSIMWalletFactory.isESIMWalletDeployed(_eSIMWalletAddress))
        ) {
            revert Errors.OnlyRegistryOrDeviceWalletFactoryOrOwner();
        }
    }

    /// @notice Restricts a call to the registry, the device wallet factory, this wallet itself, or
    ///         the named eSIM wallet re-adding itself
    modifier onlyRegistryOrDeviceWalletFactoryOrOwner(address _eSIMWalletAddress) {
        _onlyRegistryOrDeviceWalletFactoryOrOwner(_eSIMWalletAddress);
        _;
    }

    /// @notice Reverts unless the caller is this wallet itself or the eSIM wallet being removed
    /// @dev An eSIM wallet may only name itself, or it could unbind a sibling, put it on standby and
    ///      force its ETH back. `removeESIMWallet` still checks the named wallet is associated.
    function _onlySelfOrESIMWalletBeingRemoved(address _eSIMWalletAddress) private view {
        if(
            msg.sender != address(this) &&
            msg.sender != _eSIMWalletAddress
        ) {
            revert Errors.OnlySelfOrAssociatedESIMWallet();
        }
    }

    /// @notice Restricts a call to this wallet itself or to the eSIM wallet being removed
    modifier onlySelfOrESIMWalletBeingRemoved(address _eSIMWalletAddress) {
        _onlySelfOrESIMWalletBeingRemoved(_eSIMWalletAddress);
        _;
    }

    /// @notice Reverts unless the caller is an eSIM wallet this device wallet holds
    function _onlyAssociatedESIMWallets() private view {
        if (!isValidESIMWallet[msg.sender]) revert Errors.OnlyAssociatedESIMWallets();
    }

    /// @notice Restricts a call to an eSIM wallet this device wallet holds
    modifier onlyAssociatedESIMWallets() {
        _onlyAssociatedESIMWallets();
        _;
    }

    /// @notice Restricts a call to the eSIM wallet admin
    /// @dev Read from the registry on every call, so a rotation there takes effect immediately.
    modifier onlyESIMWalletAdmin() {
        if(msg.sender != registry.eSIMWalletAdmin()) {
            revert Errors.OnlyESIMWalletAdmin();
        }
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Wires the entry point and WebAuthn verifier used by this wallet
    /// @param anEntryPoint EntryPoint singleton this wallet validates against
    /// @param _verifier Contract used to verify WebAuthn assertions
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint anEntryPoint,
        P256Verifier _verifier
    ) Account4337(anEntryPoint, _verifier) {}

    /// @notice Wires the wallet to the registry and the factory, and sets its owner key
    /// @dev Runs from the beacon proxy's constructor, in the deployment transaction. It is the only
    ///      path to the internal `Account4337.initialize`.
    /// @param _registry Registry contract this wallet reads the admin, vault and pause flag from
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning this wallet
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _eSIMWalletFactory Factory this wallet deploys its eSIM wallets through
    function init(
        address _registry,
        bytes32[2] memory _deviceWalletOwnerKey,
        string memory _deviceUniqueIdentifier,
        address _eSIMWalletFactory
    ) external initializer {
        if(_registry == address(0)) revert Errors.ZeroAddress("_registry");
        if(_eSIMWalletFactory == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactory");
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();

        registry = Registry(_registry);
        deviceUniqueIdentifier = _deviceUniqueIdentifier;
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactory);

        initialize(_deviceWalletOwnerKey);
        __ReentrancyGuard_init();
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM wallet deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys an eSIM wallet for this device and binds it
    /// @dev Fund access is granted later by the owner with `toggleAccessToFunds`. The admin gate is
    ///      a convenience, not a boundary: the owner can call the factory directly via `execute`.
    /// @param _hasAccessToFunds Must be false
    /// @param _salt CREATE2 salt for the new eSIM wallet
    /// @return eSIM wallet address
    function deployESIMWallet(
        bool _hasAccessToFunds,
        uint256 _salt
    ) external onlyESIMWalletAdmin returns (address) {
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(address(this), _salt);

        _addESIMWallet(eSIMWalletAddress, _hasAccessToFunds);

        return eSIMWalletAddress;
    }

    // ---------------------------------------------------------------------------------------------
    // Money movement
    // ---------------------------------------------------------------------------------------------

    /// @notice Allow an associated eSIM wallet to pull an ERC-20 (for data bundles)
    /// @dev Lets the admin charge this wallet without an owner signature. An owner buying for
    ///      themselves can batch the transfer and purchase in `executeBatch` instead.
    /// @param _token ERC-20 being pulled
    /// @param _amount Amount in that token's smallest unit
    /// @return The amount pulled
    function pullToken(address _token, uint256 _amount)
        external
        nonReentrant
        onlyAssociatedESIMWallets
        returns (uint256)
    {
        registry.requireNotPaused();
        if(_token == address(0)) revert Errors.ZeroAddress("_token");
        if(_amount == 0) revert Errors.ZeroAmount();
        if(!canPullFunds[msg.sender]) revert Errors.FundsAccessRevoked(msg.sender);

        IERC20(_token).safeTransfer(msg.sender, _amount);
        emit TokenSent(_token, msg.sender, _amount);

        return _amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Owner key rotation
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc Account4337
    /// @dev The registry keeps one key to one wallet, so it must follow every rotation. It is told
    ///      after the local write because it reads the key back from this wallet.
    function _transferOwnership(bytes32[2] memory newOwner, bytes calldata newOwnerSignature) internal override {
        _requireValidOwnerKey(newOwner);

        super._transferOwnership(newOwner, newOwnerSignature);
        registry.updateDeviceWalletOwnerKey(newOwner);
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM wallet management
    // ---------------------------------------------------------------------------------------------

    /// @notice Allow owner to revoke or give an associated eSIM wallet access to this wallet's money
    /// @dev The only way that access is ever granted. Binding a wallet never carries it, so a
    ///      revocation stands until the owner signs a grant.
    /// @param _eSIMWalletAddress Address of the eSIM wallet to toggle access for
    /// @param _hasAccessToFunds Set to true to give access, false to revoke access
    function toggleAccessToFunds(address _eSIMWalletAddress, bool _hasAccessToFunds) public onlySelf {
        if(!isValidESIMWallet[_eSIMWalletAddress]) revert Errors.UnknownESIMWallet(_eSIMWalletAddress);

        canPullFunds[_eSIMWalletAddress] = _hasAccessToFunds;

        emit FundsAccessUpdated(_eSIMWalletAddress, _hasAccessToFunds);
    }

    /// @notice Binds an eSIM wallet; callable by the registry, the device wallet factory, this
    ///         wallet, or a factory-deployed eSIM wallet adding itself
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be added
    /// @param _hasAccessToFunds Must be false. Access is granted only through `toggleAccessToFunds`
    function addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToFunds
    ) public onlyRegistryOrDeviceWalletFactoryOrOwner(_eSIMWalletAddress) {
        _addESIMWallet(_eSIMWalletAddress, _hasAccessToFunds);
    }

    /// @notice Unbinds an eSIM wallet; callable by this wallet or by that eSIM wallet itself
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be removed
    /// @param _callBackETH Whether to pull the eSIM wallet's ETH back to this wallet
    function removeESIMWallet(
        address _eSIMWalletAddress,
        bool _callBackETH
    ) public onlySelfOrESIMWalletBeingRemoved(_eSIMWalletAddress) nonReentrant {
        if(!isValidESIMWallet[_eSIMWalletAddress]) revert Errors.UnknownESIMWallet(_eSIMWalletAddress);

        isValidESIMWallet[_eSIMWalletAddress] = false;
        canPullFunds[_eSIMWalletAddress] = false;

        // Only the standby flag moves. The registry keeps this device wallet as last holder, which
        // marks the wallet as the protocol's own during transfer. Authority goes with the writes above.
        registry.toggleESIMWalletStandbyStatus(_eSIMWalletAddress, true);

        emit ESIMWalletRemoved(_eSIMWalletAddress, address(this), msg.sender);

        // Callback last: eSIM wallet logic is upgradeable, so it may re-enter. By now the wallet
        // has lost canPullFunds and isValidESIMWallet, so it cannot use those rights.
        if(_callBackETH) {
            try ESIMWallet(payable(_eSIMWalletAddress)).sendETHToDeviceWallet(_eSIMWalletAddress.balance) returns (uint256 _amount) {
                emit ETHCalledBack(_amount);
            }
            catch {
                emit NoETHToCallback();
            }
        }
    }

    /// @notice Binds an eSIM wallet to this device wallet and records it with the registry
    /// @dev Refuses a wallet not yet owned by this one, so binding cannot run ahead of a handover.
    ///      Never grants fund access, so no bind can undo an owner's revocation. Asking for access
    ///      reverts rather than being silently dropped.
    /// @param _eSIMWalletAddress Address of the eSIM wallet to bind
    /// @param _hasAccessToFunds Must be false
    function _addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToFunds
    ) internal {
        if(_hasAccessToFunds) revert Errors.FundsAccessNotGrantableAtBind(_eSIMWalletAddress);
        if(isValidESIMWallet[_eSIMWalletAddress]) revert Errors.ESIMWalletAlreadyAdded(_eSIMWalletAddress);
        // New deployment: owner is set to this wallet at initialisation.
        // Existing wallet: the previous owner must transfer and this wallet must accept first.
        address eSIMWalletOwner = ESIMWallet(payable(_eSIMWalletAddress)).owner();
        if(eSIMWalletOwner != address(this)) {
            revert Errors.ESIMWalletNotOwnedByThisDeviceWallet(_eSIMWalletAddress, eSIMWalletOwner);
        }

        isValidESIMWallet[_eSIMWalletAddress] = true;
        // Already false via `removeESIMWallet`, written so the rule is visible here
        canPullFunds[_eSIMWalletAddress] = false;

        // Writes the association and clears any standby flag. The only call that touches both.
        registry.bindESIMWallet(_eSIMWalletAddress, address(this));

        emit ESIMWalletAdded(_eSIMWalletAddress, false, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Key checks
    // ---------------------------------------------------------------------------------------------

    /// @notice Rejects a P256 public key that is not a point on the curve
    /// @dev Duplicates the factory's private check, since sharing it would add an external call.
    ///      Also rejects keys outside the field and the point at infinity.
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key to check
    function _requireValidOwnerKey(bytes32[2] memory _deviceWalletOwnerKey) private pure {
        if(
            !FCL_Elliptic_ZZ.ecAff_isOnCurve(
                uint256(_deviceWalletOwnerKey[0]),
                uint256(_deviceWalletOwnerKey[1])
            )
        ) revert Errors.InvalidDeviceWalletOwnerKey();
    }

    /// @notice Fetches the vault address that receives payment for data bundles
    /// @dev Not cached, so a vault change in the registry reaches every wallet at once.
    /// @return The vault address
    function getVaultAddress() public view returns (address) {
        return registry.vault();
    }

    // ETH is received through the receive function Account4337 declares
}
