// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Errors} from "./Errors.sol";

// Types
import {DataBundleDetails, Settlement, Wallets} from "./CustomStructs.sol";

// Contracts
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {LazyWalletRegistry} from "./LazyWalletRegistry.sol";

/// @notice Storage and the lazy deployment paths that `Registry` inherits
/// @dev Of the external functions here, the deploy and history ones are callable only by the lazy
///      wallet registry; the rest are public reads.
contract RegistryHelper {

    /// @notice Most alternative salts tried before a lazy deployment gives up
    /// @dev Bounded so an occupied range cannot make a batch's gas cost unbounded.
    uint256 private constant MAX_SALT_PROBES = 8;

    /// @notice Address of the Lazy wallet registry
    address public lazyWalletRegistry;

    /// @notice Device wallet factory instance
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice eSIM wallet factory instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice Device wallet recorded for each device identifier, zero if unused
    mapping(string deviceIdentifier => address deviceWalletAddress) public uniqueIdentifierToDeviceWallet;

    /// @notice X,Y co-ordinates of the P256 keys associated with the device wallet
    mapping(address deviceWalletAddress => bytes32[2] ownerP256Keys) public deviceWalletToOwner;

    /// @notice Device wallet registered under each owner key hash, `keccak256(abi.encode(X, Y))`
    /// @dev Keeps one P256 key to one device wallet.
    mapping(bytes32 hashOfOwnerP256Keys => address deviceWalletAddress) public registeredP256Keys;

    /// @notice True for every device wallet the registry has recorded
    mapping(address deviceWalletAddress => bool valid) public isDeviceWalletValid;

    /// @notice Device wallet each protocol eSIM wallet is bound to, zero if not a protocol wallet
    /// @dev Non-zero for the wallet's whole life; mid-transfer it names the last device wallet, never
    ///      zero for "released". `bindESIMWallet`, the only writer, checks the factory deployed it.
    mapping(address eSIMWalletAddress => address deviceWalletAddress) public isESIMWalletValid;

    /// @notice True while an eSIM wallet sits between device wallets, released by one and not yet
    ///         taken on by another
    /// @dev A marker for offchain readers, not a gate. Gating spend on it would brick a wallet its
    ///      device wallet just removed, since `removeESIMWallet` raises it whether or not a transfer
    ///      follows. Use `isESIMWalletValid` to ask whether a wallet belongs to the protocol.
    mapping(address eSIMWalletAddress => bool isOnStandby) public isESIMWalletOnStandby;

    /// @notice The eSIM wallet holding each eSIM identifier, protocol-wide
    /// @dev Stops two wallets, one per deploy route, taking the same identifier. Written once and
    ///      never cleared, even on ownership transfer, since the eSIM belongs to the wallet.
    mapping(bytes32 hashOfESIMIdentifier => address eSIMWallet) public claimedESIMIdentifiers;

    /// @dev Registry's own state starts right after this gap, so anything added above shifts every
    ///      Registry slot. New variables here must shrink the gap by the same number of slots.
    uint256[50] private __gap;

    /// @notice Emitted for each eSIM wallet deployed on behalf of the lazy wallet registry
    event LazyWalletDeployed(
        address indexed _deviceWallet,
        string _deviceUniqueIdentifier,
        address indexed _eSIMWallet,
        string _eSIMUniqueIdentifier
    );

    /// @notice Emitted when a device wallet is first recorded, with its identifier and owner key
    event DeviceWalletInfoUpdated(
        address indexed _deviceWallet,
        string _deviceUniqueIdentifier,
        bytes32[2] _deviceWalletOwnerKey
    );

    /// @notice Emitted when a device wallet rotates the P256 key that owns it
    event DeviceWalletOwnerKeyUpdated(
        address indexed _deviceWallet,
        bytes32[2] _oldOwnerKey,
        bytes32[2] _newOwnerKey
    );

    /// @notice Emitted the first and only time an eSIM identifier is bound to an eSIM wallet
    /// @dev The string is also carried unindexed, since an indexed string keeps only its hash.
    event ESIMIdentifierClaimed(
        bytes32 indexed _hashOfESIMIdentifier,
        string _eSIMUniqueIdentifier,
        address indexed _eSIMWallet
    );

    /// @notice Emitted when an eSIM wallet is bound to a device wallet
    event UpdatedDeviceWalletAssociatedWithESIMWallet(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress
    );

    /// @notice Emitted when the owner points the registry at the lazy wallet registry
    event UpdatedLazyWalletRegistryAddress(
        address indexed _lazyWalletRegistry
    );

    /// @notice Emitted once, when the registry is initialised
    event RegistryInitialized(
        address _eSIMWalletAdmin,
        address _vault,
        address indexed _upgradeManager,
        address indexed _deviceWalletFactory,
        address indexed _eSIMWalletFactory
    );

    /// @notice Emitted when the owner nominates a new address for the admin role
    /// @dev The role goes dormant here: the incumbent is powerless until the nominee accepts.
    event AdminUpdateRequested(address indexed eSIMWalletAdmin, address indexed _newAdmin);

    /// @notice Emitted when the newly requested admin accepts the role
    event AdminUpdated(address indexed _newAdmin);

    /// @notice Emitted when the owner withdraws an outstanding nomination
    event AdminUpdateRevoked(address indexed _caller, address indexed _revokedAddress);

    /// @notice Emitted when the admin's powers are suspended, naming the address left on the books
    event AdminDisabled(address indexed _adminOfRecord, address indexed _caller);

    /// @notice Emitted when a suspended admin is given its powers back
    event AdminEnabled(address indexed _adminOfRecord, address indexed _caller);

    /// @notice Emitted when the owner points data bundle payments at a different vault
    event VaultAddressUpdated(address indexed _updatedVaultAddress);

    /// @notice Emitted when the admin or owner stops the guarded purchase and pull paths
    event Paused(address indexed _admin);

    /// @notice Emitted when the owner releases the pause
    event Unpaused(address indexed _owner);

    /// @notice Emitted when the owner changes the price ceiling eSIM wallets fall back to
    event DefaultPriceCapUSDCentsUpdated(uint64 _cap);

    /// @notice Emitted when the admin allowance new eSIM wallets start with is set
    event DefaultAdminAllowanceUSDCentsUpdated(uint64 _allowance);

    /// @notice Emitted when the owner points the registry at a payment adapter
    event PaymentAdapterUpdated(address indexed _paymentAdapter);

    /// @notice Emitted when a payment reference is spent for an eSIM wallet
    event PaymentReferenceConsumed(address indexed _eSIMWallet, bytes32 indexed _paymentReference);

    /// @notice Emitted for a purchase paid for outside the protocol
    /// @dev On the registry so an indexer follows one address. `_tokenAmount` is unchecked: it and
    ///      the price both come from the admin.
    event DataBundleSettled(
        address indexed _eSIMWallet,
        bytes32 _dataBundleID,
        uint64 _priceUSDCents,
        Settlement _settlement,
        bytes32 indexed _asset,
        address _token,
        uint256 _tokenAmount,
        bytes32 indexed _paymentReference
    );

    /// @notice Emitted when an eSIM wallet's outstanding transfer is raised or settled
    event ESIMWalletSetOnStandby(
        address indexed _eSIMWalletAddress,
        bool _isOnStandby,
        address indexed _deviceWalletAddress
    );

    /// @notice Restricts a call to the lazy wallet registry
    modifier onlyLazyWalletRegistry() {
        if(msg.sender != lazyWalletRegistry) revert Errors.OnlyLazyWalletRegistry();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy wallet deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Allow LazyWalletRegistry to deploy a device wallet and its first eSIM wallets
    /// @dev History is copied later via `populateLazyHistory`, so gas here does not grow with both
    ///      eSIM count and history size. Later batches go through `deployMoreLazyESIMWallets`. The
    ///      lazy wallet registry reserves the whole salt range first, so no salt bound is needed.
    /// @param _deviceWalletOwnerKey P256 public key of user
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @param _salt CREATE2 salt the device wallet and its first eSIM wallet are deployed at
    /// @param _eSIMUniqueIdentifiers First batch of eSIM identifiers, in the order the full list holds them
    /// @param _depositAmount ETH forwarded to the new device wallet
    /// @return The device wallet address
    /// @return The eSIM wallet addresses this call deployed
    function deployLazyWallet(
        bytes32[2] memory _deviceWalletOwnerKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        string[] calldata _eSIMUniqueIdentifiers,
        uint256 _depositAmount
    ) external payable onlyLazyWalletRegistry returns (address, address[] memory) {
        address existing = uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier];
        if(existing != address(0)) {
            revert Errors.DeviceWalletAlreadyExists(_deviceUniqueIdentifier, existing);
        }

        string[] memory deviceUniqueIdentifier = new string[](1);
        bytes32[2][] memory deviceWalletOwnersKey = new bytes32[2][](1);
        uint256[] memory salt = new uint256[](1);
        uint256[] memory depositAmount = new uint256[](1);

        deviceUniqueIdentifier[0] = _deviceUniqueIdentifier;
        deviceWalletOwnersKey[0] = _deviceWalletOwnerKey;
        salt[0] = _salt;
        depositAmount[0] = _depositAmount;

        Wallets[] memory wallet = deviceWalletFactory.deployDeviceWalletForUsers{value: _depositAmount}(
            deviceUniqueIdentifier,
            deviceWalletOwnersKey,
            salt,
            depositAmount
        );

        address deviceWallet = wallet[0].deviceWallet;
        address firstESIMWallet = wallet[0].eSIMWallet;
        address[] memory eSIMWallets = new address[](_eSIMUniqueIdentifiers.length);

        uint256 i = 0;

        // The factory already deployed the first eSIM wallet; only its identifier is left to set
        eSIMWallets[i] = firstESIMWallet;
        _assignESIMIdentifier(firstESIMWallet, _eSIMUniqueIdentifiers[i]);
        i++;

        for(; i<_eSIMUniqueIdentifiers.length; ++i) {
            eSIMWallets[i] = _deployLazyESIMWallet(
                deviceWallet,
                _deviceUniqueIdentifier,
                _salt + i,
                _eSIMUniqueIdentifiers[i]
            );
        }

        return (deviceWallet, eSIMWallets);
    }

    /// @notice Deploys the next batch of eSIM wallets for a device the lazy registry already set up
    /// @dev Separate from `deployLazyWallet`, whose key, salt and deposit belong to the one-time
    ///      device deploy (the key may have rotated since). The salt continues from earlier batches,
    ///      since a repeat would land CREATE2 on an address that already holds a wallet.
    /// @param _deviceWallet Device wallet the new eSIM wallets are bound to
    /// @param _deviceUniqueIdentifier Device identifier the wallets belong to
    /// @param _baseSalt Salt the device's deployment started from
    /// @param _startIndex Position of this batch's first identifier in the device's full list
    /// @param _eSIMUniqueIdentifiers This batch's identifiers, in the order the full list holds them
    /// @return Addresses of the eSIM wallets this call deployed
    function deployMoreLazyESIMWallets(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        uint256 _baseSalt,
        uint256 _startIndex,
        string[] calldata _eSIMUniqueIdentifiers
    ) external onlyLazyWalletRegistry returns (address[] memory) {
        uint256 batchSize = _eSIMUniqueIdentifiers.length;
        address[] memory eSIMWallets = new address[](batchSize);

        for(uint256 i=0; i<batchSize; ++i) {
            eSIMWallets[i] = _deployLazyESIMWallet(
                _deviceWallet,
                _deviceUniqueIdentifier,
                _baseSalt + _startIndex + i,
                _eSIMUniqueIdentifiers[i]
            );
        }

        return eSIMWallets;
    }

    /// @notice Forwards one batch of pre-deployment purchase history to an eSIM wallet on behalf of
    ///         the lazy wallet registry
    /// @dev Routed through here because eSIM wallets accept history from this contract only. The
    ///      lazy wallet registry decides which entries each batch carries.
    /// @param _eSIMWallet Wallet receiving the batch
    /// @param _dataBundleDetails One batch of data bundle purchase details
    function populateLazyHistory(
        address _eSIMWallet,
        DataBundleDetails[] calldata _dataBundleDetails
    ) external onlyLazyWalletRegistry {
        // Enough on its own: even mid-transfer the association names the last device wallet
        if(isESIMWalletValid[_eSIMWallet] == address(0)) {
            revert Errors.NotAProtocolESIMWallet(_eSIMWallet);
        }

        ESIMWallet(payable(_eSIMWallet)).populateHistory(_dataBundleDetails);
    }

    /// @notice Deploys one eSIM wallet, binds it to the device wallet and sets its eSIM identifier
    /// @dev Shared by every batch so they cannot drift apart. The identifier is known up front on
    ///      this route, so setting it here saves the admin a transaction per wallet.
    /// @param _deviceWallet Device wallet the eSIM wallet is bound to
    /// @param _deviceUniqueIdentifier Device identifier the wallet belongs to
    /// @param _salt CREATE2 salt for this eSIM wallet
    /// @param _eSIMUniqueIdentifier Identifier written onto the new eSIM wallet
    /// @return Address of the eSIM wallet deployed
    function _deployLazyESIMWallet(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        string calldata _eSIMUniqueIdentifier
    ) internal returns (address) {
        uint256 salt = _salt;
        // The ordinary route shares this CREATE2 space, so a reserved salt may already be taken.
        // Probing into derived salts, not forward, never takes a later identifier's natural salt.
        for(uint256 probe = 0; probe < MAX_SALT_PROBES; ++probe) {
            if(eSIMWalletFactory.getCounterFactualAddress(_deviceWallet, salt).code.length == 0) break;
            salt = uint256(keccak256(abi.encode(_salt, probe)));
        }

        address eSIMWallet = eSIMWalletFactory.deployESIMWallet(_deviceWallet, salt);

        // No ETH access: only the owner grants that, with a signed `toggleAccessToFunds`
        DeviceWallet(payable(_deviceWallet)).addESIMWallet(eSIMWallet, false);

        _assignESIMIdentifier(eSIMWallet, _eSIMUniqueIdentifier);

        emit LazyWalletDeployed(_deviceWallet, _deviceUniqueIdentifier, eSIMWallet, _eSIMUniqueIdentifier);

        return eSIMWallet;
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM identifiers
    // ---------------------------------------------------------------------------------------------

    /// @notice Records an eSIM identifier against a wallet and writes it onto the wallet
    /// @dev Internal so a device wallet cannot claim through `execute` a string someone else bought;
    ///      `Registry.assignESIMIdentifier` is the admin's way in. Claims before writing the wallet,
    ///      whose slot is set once, so a failed claim never strands an identifier there.
    /// @param _eSIMWalletAddress Wallet receiving the identifier
    /// @param _eSIMUniqueIdentifier Identifier being assigned
    /// @return The identifier now on the wallet
    function _assignESIMIdentifier(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) internal returns (string memory) {
        if(isESIMWalletValid[_eSIMWalletAddress] == address(0)) {
            revert Errors.UnknownESIMWallet(_eSIMWalletAddress);
        }

        ESIMWallet eSIMWallet = ESIMWallet(payable(_eSIMWalletAddress));

        // Read off the wallet, not passed in, so a reservation check cannot name the wrong device
        address deviceWallet = address(eSIMWallet.deviceWallet());
        if(!isDeviceWalletValid[deviceWallet]) revert Errors.NotADeviceWallet(deviceWallet);

        _claimESIMIdentifier(_eSIMUniqueIdentifier, _eSIMWalletAddress, deviceWallet);

        eSIMWallet.setESIMUniqueIdentifier(_eSIMUniqueIdentifier);

        return eSIMWallet.eSIMUniqueIdentifier();
    }

    /// @notice Records the wallet holding an eSIM identifier, refusing a second holder
    /// @dev A reservation is compared against the device wallet's own identifier rather than
    ///      refused outright, since the lazy route claims against its own reservation.
    /// @param _eSIMUniqueIdentifier Identifier being claimed
    /// @param _eSIMWalletAddress Wallet claiming it
    /// @param _deviceWallet Device wallet holding that eSIM wallet
    function _claimESIMIdentifier(
        string calldata _eSIMUniqueIdentifier,
        address _eSIMWalletAddress,
        address _deviceWallet
    ) internal {
        if(bytes(_eSIMUniqueIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();

        bytes32 identifierHash = keccak256(bytes(_eSIMUniqueIdentifier));
        address holder = claimedESIMIdentifiers[identifierHash];
        if(holder != address(0)) {
            revert Errors.ESIMIdentifierAlreadyClaimed(_eSIMUniqueIdentifier, holder);
        }

        _requireESIMIdentifierNotReservedElsewhere(_eSIMUniqueIdentifier, _deviceWallet);

        claimedESIMIdentifiers[identifierHash] = _eSIMWalletAddress;

        emit ESIMIdentifierClaimed(identifierHash, _eSIMUniqueIdentifier, _eSIMWalletAddress);
    }

    /// @notice Refuses an identifier a fiat user reserved against a different device
    /// @dev Passes while `lazyWalletRegistry` is unset, since nothing can be reserved before then.
    /// @param _eSIMUniqueIdentifier Identifier about to be claimed
    /// @param _deviceWallet Device wallet the identifier is being claimed under
    function _requireESIMIdentifierNotReservedElsewhere(
        string calldata _eSIMUniqueIdentifier,
        address _deviceWallet
    ) private view {
        if(lazyWalletRegistry == address(0)) return;

        string memory reservedFor =
            LazyWalletRegistry(lazyWalletRegistry).eSIMIdentifierToDeviceIdentifier(_eSIMUniqueIdentifier);
        if(bytes(reservedFor).length == 0) return;

        string memory claimant = DeviceWallet(payable(_deviceWallet)).deviceUniqueIdentifier();
        if(keccak256(bytes(reservedFor)) != keccak256(bytes(claimant))) {
            revert Errors.ESIMIdentifierReservedForLazyWallet(_eSIMUniqueIdentifier);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Device wallet records
    // ---------------------------------------------------------------------------------------------

    /// @notice Records a device wallet against its identifier and its owner key
    /// @dev Writes all four mappings together, so a wallet is either fully recorded or not recorded.
    /// @param _deviceWallet Address of the device wallet
    /// @param _deviceUniqueIdentifier Identifier the wallet is reached by
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning the wallet
    function _updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) internal {
        // Callers only check the wallet being recorded. A second wallet with the same identifier or
        // key but another salt gets a new address and passes them, so without this it would
        // silently and permanently take over the first wallet's record.
        if(uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] != address(0)) {
            revert Errors.DeviceIdentifierAlreadyRegistered(_deviceUniqueIdentifier);
        }

        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        if(registeredP256Keys[keyHash] != address(0)) {
            revert Errors.OwnerKeyAlreadyRegistered(keyHash);
        }

        uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] = _deviceWallet;
        isDeviceWalletValid[_deviceWallet] = true;
        deviceWalletToOwner[_deviceWallet] = _deviceWalletOwnerKey;
        registeredP256Keys[keyHash] = _deviceWallet;

        emit DeviceWalletInfoUpdated(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    /// @notice Moves a device wallet's registry bindings from its current owner key to a new one
    /// @dev The old key comes from storage, not the caller, so a wallet cannot free someone else's
    ///      key. Clearing it before the check lets a wallet rotate onto the key it already holds.
    /// @param _deviceWallet Wallet whose owner key is rotating
    /// @param _newOwnerKey X,Y co-ordinates of the P256 key taking over
    function _updateDeviceWalletOwnerKey(
        address _deviceWallet,
        bytes32[2] memory _newOwnerKey
    ) internal {
        bytes32[2] memory oldOwnerKey = deviceWalletToOwner[_deviceWallet];
        delete registeredP256Keys[keccak256(abi.encode(oldOwnerKey[0], oldOwnerKey[1]))];

        // Keeps one key to one wallet: the mapping can only name one holder
        bytes32 newKeyHash = keccak256(abi.encode(_newOwnerKey[0], _newOwnerKey[1]));
        if(registeredP256Keys[newKeyHash] != address(0)) {
            revert Errors.OwnerKeyAlreadyRegistered(newKeyHash);
        }

        registeredP256Keys[newKeyHash] = _deviceWallet;
        deviceWalletToOwner[_deviceWallet] = _newOwnerKey;

        emit DeviceWalletOwnerKeyUpdated(_deviceWallet, oldOwnerKey, _newOwnerKey);
    }

    // ---------------------------------------------------------------------------------------------
    // Identifier records
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether a device identifier already has a wallet recorded against it
    /// @dev Covers both deploy routes, so each can refuse an identifier the other already used.
    /// @param _deviceUniqueIdentifier Device identifier being checked
    /// @return True if the identifier is taken
    function isDeviceIdentifierAlreadyUsed(string calldata _deviceUniqueIdentifier) public view returns (bool) {
        return uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] != address(0);
    }

    /// @notice The eSIM wallet holding an eSIM identifier, or zero if nobody holds it
    /// @param _eSIMUniqueIdentifier eSIM identifier being looked up
    /// @return The wallet that claimed it
    function eSIMWalletForIdentifier(string calldata _eSIMUniqueIdentifier) public view returns (address) {
        return claimedESIMIdentifiers[keccak256(bytes(_eSIMUniqueIdentifier))];
    }

    /// @notice Whether an eSIM identifier is already held by a wallet
    /// @param _eSIMUniqueIdentifier eSIM identifier being checked
    /// @return True if the identifier is taken
    function isESIMIdentifierClaimed(string calldata _eSIMUniqueIdentifier) public view returns (bool) {
        return claimedESIMIdentifiers[keccak256(bytes(_eSIMUniqueIdentifier))] != address(0);
    }
}
