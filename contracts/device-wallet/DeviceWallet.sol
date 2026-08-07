// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Errors} from "../Errors.sol";

// Interfaces
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
/// @dev A beacon proxy deployed by `DeviceWalletFactory`, owned by a P256 key the user holds. It
///      funds its eSIM wallets, decides which of them may pull ETH, and is the only party that can
///      move one to another device. Its own owner key rotates through `transferOwnership`, which
///      also tells the registry so the two records cannot drift apart.
contract DeviceWallet is Initializable, ReentrancyGuardUpgradeable, Account4337 {
    using Address for address;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM wallet factory address
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Set to true if the eSIM wallet belongs to this device wallet
    mapping(address eSIMWalletAddress => bool isValid) public isValidESIMWallet;

    /// @notice Tracks if an associated eSIM wallet can pull ETH or not
    mapping(address eSIMWalletAddress => bool isAllowedToPullETH) public canPullETH;

    /// @notice Emitted when the contract pays ETH for data bundle
    event ETHPaidForDataBundle(address indexed _vault, address indexed _eSIMWallet, uint256 indexed _amount);

    /// @notice Emitted when owner updates ETH access to a particular eSIM wallet
    event ETHAccessUpdated(address indexed _eSIMWalletAddress, bool _hasAccessToETH);

    /// @notice Emitted when ETH is sent out from the contract
    /// @dev mostly when an eSIM wallet pulls ETH from this contract
    event ETHSent(address indexed _eSIMWalletAddress, uint256 _amount);

    /// @notice Emitted when eSIM wallet is added to this Device Wallet
    event ESIMWalletAdded(address indexed _eSIMWalletAddress, bool _hasAccessToETH, address indexed _caller);

    /// @notice Emitted when the eSIM wallet is removed from this Device Wallet
    event ESIMWalletRemoved(address indexed _eSIMWalletAddress, address indexed _deviceWalletAddress, address indexed _caller);

    /// @notice Emitted when the eSIM wallet being removed has no ETH to call back
    event NoETHToCallback();

    /// @notice Emitted when the eSIM being removed sends back ETH to this device wallet
    event ETHCalledBack(uint256 _amount);

    /// @notice Reverts unless the caller is the registry, the device wallet factory or this wallet
    /// @dev Private rather than inline in the modifier, so the check is emitted once instead of at
    ///      every use site. Keep each of these next to the modifier that calls it.
    function _onlyRegistryOrDeviceWalletFactoryOrOwner() private view {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            msg.sender != address(this)
        ) {
            revert Errors.OnlyRegistryOrDeviceWalletFactoryOrOwner();
        }
    }

    /// @notice Restricts a call to the registry, the device wallet factory or this wallet itself
    modifier onlyRegistryOrDeviceWalletFactoryOrOwner() {
        _onlyRegistryOrDeviceWalletFactoryOrOwner();
        _;
    }

    /// @notice Reverts unless the caller is this wallet itself or the eSIM wallet being removed
    /// @dev An eSIM wallet may only name itself. Accepting any associated wallet let one of them
    ///      unbind a sibling, strip its ETH access, put it on standby and force its balance back to
    ///      the device wallet. Association of the named wallet is still established by the caller,
    ///      which requires isValidESIMWallet before doing anything.
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

    /// @notice Reverts unless the caller is the registry or the eSIM wallet admin
    /// @dev The registry is checked first because its address is already in a warm slot, while
    ///      reading the admin off it costs a cold proxy hop. The registry is also the caller that
    ///      reaches here most, through the lazy wallet deployment path, so short-circuiting on it
    ///      skips the hop entirely on the common case.
    function _onlyESIMWalletAdminOrRegistry() private view {
        if (
            msg.sender != address(registry) &&
            msg.sender != registry.eSIMWalletAdmin()
        ) {
            revert Errors.OnlyESIMWalletAdminOrRegistry();
        }
    }

    /// @notice Restricts a call to the registry or the eSIM wallet admin
    modifier onlyESIMWalletAdminOrRegistry() {
        _onlyESIMWalletAdminOrRegistry();
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

    /// @param anEntryPoint EntryPoint singleton this wallet validates against
    /// @param _verifier Contract used to verify WebAuthn assertions
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint anEntryPoint,
        P256Verifier _verifier
    ) Account4337(anEntryPoint, _verifier) {}

    /// @notice Wires the wallet to the registry and the factory, and sets its owner key
    /// @dev Called as the beacon proxy's constructor argument, so it always runs in the same
    ///      transaction as the deployment. `Account4337.initialize` is internal, and this is the
    ///      only path to it.
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
    /// @dev The new wallet has no eSIM identifier yet. That arrives through
    ///      `setESIMUniqueIdentifierForAnESIMWallet` once the eSIM itself has been created.
    /// @param _hasAccessToETH Set to true if the eSIM wallet is allowed to pull ETH from this wallet.
    /// @param _salt CREATE2 salt for the new eSIM wallet
    /// @return eSIM wallet address
    function deployESIMWallet(
        bool _hasAccessToETH,
        uint256 _salt
    ) external onlyESIMWalletAdmin returns (address) {
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(address(this), _salt);

        _addESIMWallet(eSIMWalletAddress, _hasAccessToETH);

        return eSIMWalletAddress;
    }

    // ---------------------------------------------------------------------------------------------
    // ETH movement
    // ---------------------------------------------------------------------------------------------

    /// @notice Allow the eSIM wallets associated with this device wallet to pay ETH for data bundles
    /// @dev Instead of pulling the ETH into the eSIM wallet and then sending to the vault,
    ///      the eSIM wallet can directly request the device wallet to pay ETH for the data bundles
    ///      Not called by the eSIM wallet today, and a candidate for removal if it stays unused.
    /// @param _amount Amount of ETH to pull
    /// @return The amount paid
    function payETHForDataBundles(uint256 _amount) external onlyAssociatedESIMWallets nonReentrant returns (uint256) {
        registry.requireNotPaused();
        if(_amount == 0) revert Errors.ZeroAmount();
        if(!canPullETH[msg.sender]) revert Errors.ETHAccessRevoked(msg.sender);

        address vault = getVaultAddress();
        _transferETH(vault, _amount);

        emit ETHPaidForDataBundle(vault, msg.sender, _amount);

        return _amount;
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pull ETH (for data bundles)
    /// @dev Refused while the protocol is paused, and refused for a wallet whose ETH access the
    ///      owner has revoked.
    /// @param _amount Amount of ETH to pull
    /// @return The amount pulled
    function pullETH(uint256 _amount) external onlyAssociatedESIMWallets nonReentrant returns (uint256) {
        registry.requireNotPaused();
        if(_amount == 0) revert Errors.ZeroAmount();
        if(!canPullETH[msg.sender]) revert Errors.ETHAccessRevoked(msg.sender);

        _transferETH(msg.sender, _amount);

        return _amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Owner key rotation
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc Account4337
    /// @dev The registry holds its own record of which key owns this wallet, and the deploy paths
    ///      keep one key to one wallet. Rotating without telling it leaves the retired key named
    ///      as the owner and leaves the key taking over unregistered, free for a second wallet to
    ///      claim. `super` runs after the key check because it carries the `onlySelf` guard and
    ///      because the registry call is an external one, so the local write has to land before it.
    ///
    ///      A key that cannot verify a signature bricks the wallet for good: this function is
    ///      reachable only through `execute`, which needs a signature, so there is no rotating
    ///      back and no reaching the balance. The deploy paths reject such a key and this path
    ///      writes the same storage, so it has to reject it too.
    function transferOwnership(
        bytes32[2] memory newOwner
    ) public override returns (bytes32[2] memory) {
        _requireValidOwnerKey(newOwner);

        bytes32[2] memory updatedOwner = super.transferOwnership(newOwner);
        registry.updateDeviceWalletOwnerKey(newOwner);

        return updatedOwner;
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM wallet management
    // ---------------------------------------------------------------------------------------------

    /// @notice Allow wallet owner or admin to set unique identifier for their eSIM wallet
    /// @dev The registry is also a caller, which is how a wallet deployed on the lazy path gets its
    ///      identifier in the same transaction as its deployment.
    /// @param _eSIMWalletAddress Address of the eSIM wallet smart contract
    /// @param _eSIMUniqueIdentifier String unique identifier for the eSIM wallet
    /// @return The identifier now written on the eSIM wallet
    function setESIMUniqueIdentifierForAnESIMWallet(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) public onlyESIMWalletAdminOrRegistry returns (string memory) {
        if(registry.isESIMWalletValid(_eSIMWalletAddress) == address(0)) {
            revert Errors.UnknownESIMWallet(_eSIMWalletAddress);
        }

        ESIMWallet eSIMWallet = ESIMWallet(payable(_eSIMWalletAddress));
        eSIMWallet.setESIMUniqueIdentifier(_eSIMUniqueIdentifier);

        return eSIMWallet.eSIMUniqueIdentifier();
    }

    /// @notice Allow owner to revoke or give access to any associated eSIM wallet for pulling ETH
    /// @param _eSIMWalletAddress Address of the eSIM wallet to toggle ETH access for
    /// @param _hasAccessToETH Set to true to give access, false to revoke access
    function toggleAccessToETH(address _eSIMWalletAddress, bool _hasAccessToETH) public onlySelf {
        if(!isValidESIMWallet[_eSIMWalletAddress]) revert Errors.UnknownESIMWallet(_eSIMWalletAddress);

        canPullETH[_eSIMWalletAddress] = _hasAccessToETH;

        emit ETHAccessUpdated(_eSIMWalletAddress, _hasAccessToETH);
    }

    /// @notice Allow the device wallet factory or the wallet owner to add new eSIM wallet to this device wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be added
    /// @param _hasAccessToETH `true` if the eSIM wallet is allowed to pull ETH from this device wallet, `false` otherwise
    function addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToETH
    ) public onlyRegistryOrDeviceWalletFactoryOrOwner {
        _addESIMWallet(_eSIMWalletAddress, _hasAccessToETH);
    }

    /// @notice Allow the device wallet owner or the eSIM wallet to remove any eSIM wallet bound with this device wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be removed
    /// @param _callBackETH `true` if any remaining ETH needs to be called back from the ESIM wallet to this device wallet, `false` otherwise
    function removeESIMWallet(
        address _eSIMWalletAddress,
        bool _callBackETH
    ) public onlySelfOrESIMWalletBeingRemoved(_eSIMWalletAddress) nonReentrant {
        if(!isValidESIMWallet[_eSIMWalletAddress]) revert Errors.UnknownESIMWallet(_eSIMWalletAddress);

        isValidESIMWallet[_eSIMWalletAddress] = false;
        canPullETH[_eSIMWalletAddress] = false;

        // Inform the registry that this eSIM wallet has been let go. Only the flag moves: the
        // registry keeps naming this device wallet as the last one to hold it, which is what tells
        // the protocol the wallet is still one of its own while the transfer is outstanding. The
        // authority this device wallet had over it is withdrawn by the two writes above, not by
        // anything in the registry.
        registry.toggleESIMWalletStandbyStatus(_eSIMWalletAddress, true);

        emit ESIMWalletRemoved(_eSIMWalletAddress, address(this), msg.sender);

        // The callback runs last. All eSIM wallets share one upgradeable beacon, so the logic
        // reached here is not fixed for the life of the protocol. By this point the wallet has
        // already lost canPullETH and its registry association, so a handler that re-enters
        // cannot use the rights it is in the middle of losing.
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
    /// @dev Refuses a wallet this device wallet does not already own, so binding cannot run ahead
    ///      of the ownership handover.
    /// @param _eSIMWalletAddress Address of the eSIM wallet to bind
    /// @param _hasAccessToETH True if it may pull ETH from this device wallet
    function _addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToETH
    ) internal {
        if(isValidESIMWallet[_eSIMWalletAddress]) revert Errors.ESIMWalletAlreadyAdded(_eSIMWalletAddress);
        // If the eSIM wallet is a newly deployed one, then the owner will definitely be set
        // during initialisation. This device wallet will be the owner.
        // If the eSIM wallet already existed, then the previous owner (device wallet)
        // must transfer the ownership to the eSIM wallet, and mark its status as standby.
        // And this device wallet must accept the ownership before calling the addESIMWallet function
        address eSIMWalletOwner = ESIMWallet(payable(_eSIMWalletAddress)).owner();
        if(eSIMWalletOwner != address(this)) {
            revert Errors.ESIMWalletNotOwnedByThisDeviceWallet(_eSIMWalletAddress, eSIMWalletOwner);
        }

        isValidESIMWallet[_eSIMWalletAddress] = true;
        canPullETH[_eSIMWalletAddress] = _hasAccessToETH;

        // Inform the registry that this device wallet now holds the eSIM wallet. The call writes the
        // association and, if a release was outstanding, lowers the transit marker. The two records
        // are independent and this is the only call that touches both.
        registry.bindESIMWallet(_eSIMWalletAddress, address(this));

        emit ESIMWalletAdded(_eSIMWalletAddress, _hasAccessToETH, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // ETH transfers and key checks
    // ---------------------------------------------------------------------------------------------

    /// @notice Sends ETH out of this wallet, reverting if the call fails
    /// @dev A zero amount is a no-op rather than a revert.
    /// @param _recipient Address receiving the ETH
    /// @param _amount Amount in wei
    function _transferETH(address _recipient, uint256 _amount) internal virtual {
        uint256 balance = address(this).balance;
        if(_amount > balance) revert Errors.InsufficientBalance(balance, _amount);
        if(_recipient == address(0)) revert Errors.ZeroAddress("_recipient");

        if (_amount > 0) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert Errors.FailedToTransfer();
            else emit ETHSent(_recipient, _amount);
        }
    }

    /// @notice Rejects a P256 public key that is not a point on the curve
    /// @dev Same predicate the three deploy paths apply, repeated here because the factory holds
    ///      its own copy privately and this contract is not in its inheritance chain. Sharing one
    ///      copy would mean an external call on a path that must stay self-contained. The
    ///      predicate also covers a key outside the field and the point at infinity.
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key to check
    function _requireValidOwnerKey(bytes32[2] memory _deviceWalletOwnerKey) private pure {
        if(
            !FCL_Elliptic_ZZ.ecAff_isOnCurve(
                uint256(_deviceWalletOwnerKey[0]),
                uint256(_deviceWalletOwnerKey[1])
            )
        ) revert Errors.InvalidDeviceWalletOwnerKey();
    }

    /// @notice Fetches the vault address (that receives payment for data bundles) from the device wallet factory
    /// @dev Read through to the registry rather than cached, so a vault change reaches every
    ///      wallet at once. The associated eSIM wallets call this before paying.
    /// @return The vault address
    function getVaultAddress() public view returns (address) {
        return registry.vault();
    }

    // ETH is received through the receive function Account4337 declares
}
