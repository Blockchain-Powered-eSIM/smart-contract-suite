// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Errors} from "./Errors.sol";

// Types
import {DataBundleDetails, Wallets} from "./CustomStructs.sol";

// Contracts
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {LazyWalletRegistry} from "./LazyWalletRegistry.sol";

/// @notice Storage and the lazy deployment paths that `Registry` inherits
/// @dev Split out so `Registry` holds the admin and pause logic while the mappings and the calls
///      into the two factories live here. Only the lazy wallet registry reaches the functions in
///      this file; everything else goes through `Registry` itself.
contract RegistryHelper {

    /// @notice Most alternative salts tried before a lazy deployment gives up
    /// @dev Each attempt costs one address derivation and no storage. Bounded because an unbounded
    ///      loop would let one occupied range make the whole batch unpriceable.
    uint256 private constant MAX_SALT_PROBES = 8;

    /// @notice Address of the Lazy wallet registry
    address public lazyWalletRegistry;

    /// @notice Device wallet factory instance
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice eSIM wallet factory instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice Mapping for all the device wallets deployed by the registry
    /// @dev Use this to check if a device identifier has already been used or not
    mapping(string deviceIdentifier => address deviceWalletAddress) public uniqueIdentifierToDeviceWallet;

    /// @notice X,Y co-ordinates of the P256 keys associated with the device wallet
    mapping(address deviceWalletAddress => bytes32[2] ownerP256Keys) public deviceWalletToOwner;

    /// @notice keccak256 hash to device wallet address
    /// @dev keccak256(abi.encode(X, Y)) <> device wallet address
    /// Used to maintain one-to-one relationship between P256 keys and device wallet
    mapping(bytes32 hashOfOwnerP256Keys => address deviceWalletAddress) public registeredP256Keys;

    /// @notice true if deployed by the registry or device wallet factory
    ///         Mapping of all the device wallets deployed by the registry (or the device wallet factory) are set to true
    mapping(address deviceWalletAddress => bool valid) public isDeviceWalletValid;

    /// @notice All the eSIM wallets deployed using this registry are valid and mapped to their owner device wallet
    /// @dev This is the registration record. A non-zero entry means the protocol deployed this eSIM
    ///      wallet, and it stays non-zero for the rest of the wallet's life. Mid-transfer it names
    ///      the device wallet that last held it, so it is never zero to mean "released".
    ///      `bindESIMWallet` is the only writer and it checks the deployment with the factory, which
    ///      is what makes the first sentence true rather than assumed.
    mapping(address eSIMWalletAddress => address deviceWalletAddress) public isESIMWalletValid;

    /// @notice If an existing eSIM wallet is in the process of being transferred from one device wallet to another
    /// @dev If bool is `true`, the eSIM wallet is in a transient state. `isESIMWalletValid` still
    ///      points at the old device wallet. Do not use this mapping to check whether an eSIM
    ///      wallet belongs to the protocol; that is what `isESIMWalletValid` is for. Its job is to
    ///      hold transactions on this eSIM wallet until it reads false again, meaning the new
    ///      device wallet has accepted it.
    mapping(address eSIMWalletAddress => bool isOnStandby) public isESIMWalletOnStandby;

    /// @notice The eSIM wallet holding each eSIM identifier, protocol-wide
    /// @dev An eSIM wallet's own identifier slot is set once, but nothing stopped two wallets from
    ///      being set to the same identifier, one per deployment route. This is what makes the
    ///      identifier answer with a single wallet. Keyed by hash for the same reason
    ///      `registeredP256Keys` is: `eSIMWalletForIdentifier` takes the string.
    ///
    ///      Written once and never cleared, including through an ownership transfer, because the
    ///      eSIM belongs to the wallet rather than to whichever device is holding it.
    mapping(bytes32 hashOfESIMIdentifier => address eSIMWallet) public claimedESIMIdentifiers;

    /// @dev Registry inherits this contract and its own state begins directly after this gap, so
    ///      anything added above shifts every Registry variable. That is why the gap is here and
    ///      not at the end of `Registry` itself.
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
    /// @dev The identifier is carried unindexed as well as hashed, because indexing a dynamic type
    ///      stores its hash and no consumer can read the value back out of that.
    event ESIMIdentifierClaimed(
        bytes32 indexed _hashOfESIMIdentifier,
        string _eSIMUniqueIdentifier,
        address indexed _eSIMWallet
    );

    /// @notice Emitted when an eSIM wallet is bound to a device wallet
    event UpdatedDeviceWalletassociatedWithESIMWallet(
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
    /// @dev The incumbent is powerless from here until the nominee accepts, so a reader following
    ///      the admin has to treat this as the moment the role went dormant.
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

    /// @notice Emitted when the admin stops the ETH-moving paths protocol-wide
    event Paused(address indexed _admin);

    /// @notice Emitted when the owner releases the pause
    event Unpaused(address indexed _owner);

    /// @notice Emitted when the owner changes the price ceiling eSIM wallets fall back to
    event DefaultDataBundlePriceCapUpdated(uint256 _cap);

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
    /// @dev Deploys the wallets and sets their identifiers only. Purchase history is copied in
    ///      afterwards through `populateLazyHistory`, because carrying it here made one transaction
    ///      grow with the eSIM count and each eSIM's history at the same time.
    ///
    ///      `_eSIMUniqueIdentifiers` is the first batch rather than the device's whole list, and any
    ///      identifier past it reaches `deployMoreLazyESIMWallets`. The lazy wallet registry owns
    ///      the cursor deciding where one batch ends and the next begins, and it reserves the whole
    ///      salt range before this runs, so no bound on the salt is needed here.
    /// @param _deviceWalletOwnerKey P256 public key of user
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @param _salt CREATE2 salt the device wallet and its first eSIM wallet are deployed at
    /// @param _eSIMUniqueIdentifiers First batch of eSIM identifiers, in the order the full list holds them
    /// @param _depositAmount ETH forwarded to the new device wallet
    /// @return Return device wallet address and the eSIM wallet addresses this call deployed
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

        // Deploys device smart wallet
        // Updates device wallet info via Registry
        Wallets[] memory wallet = deviceWalletFactory.deployDeviceWalletForUsers{value: _depositAmount}(
            deviceUniqueIdentifier,
            deviceWalletOwnersKey,
            salt,
            depositAmount
        );

        address deviceWallet = wallet[0].deviceWallet;
        address firstESIMWallet = wallet[0].eSIMWallet;
        address[] memory eSIMWallets = new address[](_eSIMUniqueIdentifiers.length);

        // Tracks the eSIMWallets array index
        uint256 i = 0;

        // 1st eSIM wallet will already be deployed by the deployDeviceWalletForUsers function
        eSIMWallets[i] = firstESIMWallet;
        // deployDeviceWalletForUsers doesn't set the eSIM identifer, hence updating it here for the 1st eSIM wallet
        _assignESIMIdentifier(firstESIMWallet, _eSIMUniqueIdentifiers[i]);
        // Increase the index to deploy and set the identifier for the remaining _eSIMUniqueIdentifiers
        i++;

        for(; i<_eSIMUniqueIdentifiers.length; ++i) {
            // increase salt for subsequent eSIM wallet deployments
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
    /// @dev Separate from `deployLazyWallet` because that call deploys the device wallet itself, and
    ///      the owner key, salt and deposit it takes describe a one-time act. Reaching a device this
    ///      way needs none of them, and repeating them would either be ignored or checked against a
    ///      key the owner is free to rotate between batches.
    ///
    ///      The salt continues from where the first batch stopped rather than starting over, because
    ///      the eSIM wallet factory salts CREATE2 with it and a repeat would land on an address that
    ///      already holds a wallet.
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
    /// @dev eSIM wallets accept history from this contract and nothing else, so the copy is routed
    ///      through here rather than giving them a second address to trust. The lazy wallet
    ///      registry owns the cursor that decides which entries a batch carries.
    /// @param _eSIMWallet Wallet receiving the batch
    /// @param _dataBundleDetails One batch of data bundle purchase details
    function populateLazyHistory(
        address _eSIMWallet,
        DataBundleDetails[] calldata _dataBundleDetails
    ) external onlyLazyWalletRegistry {
        // A wallet the registry does not know is invalid to the protocol. Even mid-transfer the
        // association still points at the last known device wallet, so this is the whole check.
        if(isESIMWalletValid[_eSIMWallet] == address(0)) {
            revert Errors.NotAProtocolESIMWallet(_eSIMWallet);
        }

        ESIMWallet(payable(_eSIMWallet)).populateHistory(_dataBundleDetails);
    }

    /// @notice Deploys one eSIM wallet, binds it to the device wallet and sets its eSIM identifier
    /// @dev Shared by the first batch and every batch after it so the two cannot drift apart. The
    ///      identifier is known up front on this route, unlike the ordinary one, so setting it here
    ///      saves the admin a second transaction per wallet.
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
        // A salt inside a device's reserved range can already be taken, because an eSIM wallet
        // deployed through the ordinary route shares this CREATE2 address space and nothing
        // coordinates the two. Probing into a derived space rather than forward along the range
        // means a probe can never take the natural salt of a later identifier in the same
        // reservation.
        for(uint256 probe = 0; probe < MAX_SALT_PROBES; ++probe) {
            if(eSIMWalletFactory.getCounterFactualAddress(_deviceWallet, salt).code.length == 0) break;
            salt = uint256(keccak256(abi.encode(_salt, probe)));
        }

        address eSIMWallet = eSIMWalletFactory.deployESIMWallet(_deviceWallet, salt);

        // Updates the Device wallet storage variables as well as for the registry. No ETH access:
        // only the owner grants that, with a signed `toggleAccessToETH`.
        DeviceWallet(payable(_deviceWallet)).addESIMWallet(eSIMWallet, false);

        _assignESIMIdentifier(eSIMWallet, _eSIMUniqueIdentifier);

        emit LazyWalletDeployed(_deviceWallet, _deviceUniqueIdentifier, eSIMWallet, _eSIMUniqueIdentifier);

        return eSIMWallet;
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM identifiers
    // ---------------------------------------------------------------------------------------------

    /// @notice Records an eSIM identifier against a wallet and writes it onto the wallet
    /// @dev Internal on purpose. Only the admin knows which identifier a wallet is owed, and a
    ///      device wallet can call anything through `execute`, so an external claim let any owner
    ///      take a string bought by someone else. `Registry.assignESIMIdentifier` is the way in.
    ///
    ///      Both slots are written here so they cannot disagree. Claim first: the wallet's slot is
    ///      set once, so a claim failing after it would strand an identifier the registry never saw.
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

        // Read off the wallet rather than passed in, so no caller names a device it does not own.
        // Needed because a reservation is checked against the device it was made for.
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
    /// @dev The device identifier is read only once the string turns out to be reserved, so an
    ///      ordinary claim pays for one call returning empty. Passes while `lazyWalletRegistry` is
    ///      unset, since nothing can be reserved before that contract exists.
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
        // Both mappings are meant to be one-to-one. The callers check that against the wallet they
        // are recording, but a second wallet under the same identifier or key with a different salt
        // reaches a different address and passes those checks, so without this it can take over a
        // record belonging to another. The overwrite is silent and unrecoverable: the identifier
        // keeps resolving to the wrong wallet and the original can never be redeployed against it.
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
    /// @dev The retired key comes from `deviceWalletToOwner` rather than from the caller, so a
    ///      wallet cannot name a key it never held and free someone else's reservation. Clearing
    ///      the old hash before checking the new one is what lets a wallet rotate onto the key it
    ///      already holds: the clear removes its own reservation, so the check sees a free slot.
    /// @param _deviceWallet Wallet whose owner key is rotating
    /// @param _newOwnerKey X,Y co-ordinates of the P256 key taking over
    function _updateDeviceWalletOwnerKey(
        address _deviceWallet,
        bytes32[2] memory _newOwnerKey
    ) internal {
        bytes32[2] memory oldOwnerKey = deviceWalletToOwner[_deviceWallet];
        delete registeredP256Keys[keccak256(abi.encode(oldOwnerKey[0], oldOwnerKey[1]))];

        // The deploy paths keep one key to one wallet. Leaving the rotation unchecked would let a
        // wallet take a key another wallet is already registered under, and the mapping can only
        // name one of the two from then on.
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
    /// @dev True whichever route deployed it. Both routes have to refuse an identifier the other
    ///      already used, and this contract is the only place that knows about both.
    /// @param _deviceUniqueIdentifier Device identifier being checked
    /// @return True if the identifier is taken
    function isDeviceIdentifierAlreadyUsed(string calldata _deviceUniqueIdentifier) public view returns (bool) {
        return uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] != address(0);
    }

    /// @notice The eSIM wallet holding an eSIM identifier, or zero if nobody holds it
    /// @dev Takes the string so callers do not have to hash it themselves, which is the only
    ///      difference from reading `claimedESIMIdentifiers` directly.
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
