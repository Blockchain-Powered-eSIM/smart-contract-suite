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
/// @dev A beacon proxy deployed by `DeviceWalletFactory`, owned by a P256 key the user holds. It
///      funds its eSIM wallets, decides which of them may spend its money, and is the only party that can
///      move one to another device. Its own owner key rotates through `transferOwnership`, which
///      also tells the registry so the two records cannot drift apart.
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

    /// @notice Tracks if an associated eSIM wallet may pull this wallet's ETH and tokens
    /// @dev One flag for both. A wallet trusted with the ETH can already drain the owner, so a
    ///      second flag per asset would cost another signature and limit nothing.
    mapping(address eSIMWalletAddress => bool isAllowedToPullFunds) public canPullFunds;

    /// @notice Emitted when owner updates an eSIM wallet's access to this wallet's money
    event FundsAccessUpdated(address indexed _eSIMWalletAddress, bool _hasAccessToFunds);

    /// @notice Emitted when ETH is sent out from the contract
    /// @dev mostly when an eSIM wallet pulls ETH from this contract
    event ETHSent(address indexed _eSIMWalletAddress, uint256 _amount);

    /// @notice Emitted when an ERC-20 leaves this contract
    /// @dev mostly when an eSIM wallet pulls tokens to pay for a data bundle
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
    ///         itself, or the eSIM wallet the registry still names this device wallet as holding
    /// @dev Private rather than inline in the modifier, so the check is emitted once instead of at
    ///      every use site. Keep each of these next to the modifier that calls it.
    ///
    ///      The eSIM wallet branch is checked against the registry's own association rather than
    ///      the caller's own owner(), because a caller naming itself as `_eSIMWalletAddress`
    ///      controls what its own owner() returns. The registry association can only reach this
    ///      device wallet's address through a prior bindESIMWallet call, which already required
    ///      real ownership at that time and is not something a caller can forge.
    function _onlyRegistryOrDeviceWalletFactoryOrOwner(address _eSIMWalletAddress) private view {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            msg.sender != address(this) &&
            !(msg.sender == _eSIMWalletAddress && registry.isESIMWalletValid(_eSIMWalletAddress) == address(this))
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
    /// @dev An eSIM wallet may only name itself. Accepting any associated wallet let one of them
    ///      unbind a sibling, strip its access, put it on standby and force its balance back to
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
    ///
    ///      Access to this wallet's money is granted only afterwards, by the owner, with
    ///      `toggleAccessToFunds`.
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

    /// @notice Allow the eSIM wallets associated with this device wallet to pull ETH (for data bundles)
    /// @dev Refused while the protocol is paused, and refused for a wallet whose access the owner
    ///      has revoked.
    /// @param _amount Amount of ETH to pull
    /// @return The amount pulled
    function pullETH(uint256 _amount) external onlyAssociatedESIMWallets nonReentrant returns (uint256) {
        registry.requireNotPaused();
        if(_amount == 0) revert Errors.ZeroAmount();
        if(!canPullFunds[msg.sender]) revert Errors.FundsAccessRevoked(msg.sender);

        _transferETH(msg.sender, _amount);

        return _amount;
    }

    /// @notice Allow an associated eSIM wallet to pull an ERC-20 (for data bundles)
    /// @dev Same gate and pause check as `pullETH`. It exists so the admin can charge this wallet
    ///      without an owner signature in that transaction; an owner buying for themselves can
    ///      batch the transfer and the purchase through `executeBatch` instead.
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

    /// @notice Allow the device wallet factory or the wallet owner to add new eSIM wallet to this device wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be added
    /// @param _hasAccessToFunds Must be false. Access is granted only through `toggleAccessToFunds`
    function addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToFunds
    ) public onlyRegistryOrDeviceWalletFactoryOrOwner(_eSIMWalletAddress) {
        _addESIMWallet(_eSIMWalletAddress, _hasAccessToFunds);
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
        canPullFunds[_eSIMWalletAddress] = false;

        // Inform the registry that this eSIM wallet has been let go. Only the flag moves: the
        // registry keeps naming this device wallet as the last one to hold it, which is what tells
        // the protocol the wallet is still one of its own while the transfer is outstanding. The
        // authority this device wallet had over it is withdrawn by the two writes above, not by
        // anything in the registry.
        registry.toggleESIMWalletStandbyStatus(_eSIMWalletAddress, true);

        emit ESIMWalletRemoved(_eSIMWalletAddress, address(this), msg.sender);

        // The callback runs last. All eSIM wallets share one upgradeable beacon, so the logic
        // reached here is not fixed for the life of the protocol. By this point the wallet has
        // already lost canPullFunds and its registry association, so a handler that re-enters
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
    ///
    ///      A bind never carries access to this wallet's money. `toggleAccessToFunds` is `onlySelf` and the only writer
    ///      of a `true`, so no bind can undo the owner's revocation. Asking for access here reverts
    ///      rather than being downgraded in silence.
    /// @param _eSIMWalletAddress Address of the eSIM wallet to bind
    /// @param _hasAccessToFunds Must be false
    function _addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToFunds
    ) internal {
        if(_hasAccessToFunds) revert Errors.FundsAccessNotGrantableAtBind(_eSIMWalletAddress);
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
        // Already false on arrival, since `removeESIMWallet` zeroes it. Written anyway so the
        // property is readable here.
        canPullFunds[_eSIMWalletAddress] = false;

        // Inform the registry that this device wallet now holds the eSIM wallet. The call writes the
        // association and, if a release was outstanding, lowers the transit marker. The two records
        // are independent and this is the only call that touches both.
        registry.bindESIMWallet(_eSIMWalletAddress, address(this));

        emit ESIMWalletAdded(_eSIMWalletAddress, false, msg.sender);
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

    /// @notice Fetches the vault address that receives payment for data bundles
    /// @dev Read through to the registry rather than cached, so a vault change reaches every
    ///      wallet at once. The associated eSIM wallets call this before paying.
    /// @return The vault address
    function getVaultAddress() public view returns (address) {
        return registry.vault();
    }

    // ETH is received through the receive function Account4337 declares
}
