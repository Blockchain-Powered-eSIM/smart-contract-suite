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

/// @notice Storage and the lazy deployment paths that `Registry` inherits
/// @dev Split out so `Registry` holds the admin and pause logic while the mappings and the calls
///      into the two factories live here. Only the lazy wallet registry reaches the functions in
///      this file; everything else goes through `Registry` itself.
contract RegistryHelper {

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
    mapping(address eSIMWalletAddress => address deviceWalletAddress) public isESIMWalletValid;

    /// @notice If an existing eSIM wallet is in the process of being transferred from one device wallet to another
    /// @dev If bool is `true`, the eSIM wallet is in a transient state. `isESIMWalletValid` still
    ///      points at the old device wallet. Do not use this mapping to check whether an eSIM
    ///      wallet belongs to the protocol; that is what `isESIMWalletValid` is for. Its job is to
    ///      hold transactions on this eSIM wallet until it reads false again, meaning the new
    ///      device wallet has accepted it.
    mapping(address eSIMWalletAddress => bool isOnStandby) public isESIMWalletOnStandby;

    /// @dev Registry inherits this contract and its own state begins directly after this gap, so
    ///      a new variable here has to consume gap slots rather than follow them. One appended
    ///      below moves every Registry variable on the deployed proxies.
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

    /// @notice Emitted when the current admin requests to transfer the admin role to a new address
    event AdminUpdateRequested(address indexed eSIMWalletAdmin, address indexed _newAdmin);

    /// @notice Emitted when the newly requested admin accepts the role
    event AdminUpdated(address indexed _newAdmin);

    /// @notice Emitted when the current admin revokes the transfer of the admin role
    event AdminUpdateRevoked(address indexed _currentAdmin, address indexed _revokedAddress);

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
        DeviceWallet(payable(deviceWallet)).setESIMUniqueIdentifierForAnESIMWallet(firstESIMWallet, _eSIMUniqueIdentifiers[i]);
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
        address eSIMWallet = eSIMWalletFactory.deployESIMWallet(_deviceWallet, _salt);

        // Updates the Device wallet storage variables as well as for the registry
        DeviceWallet(payable(_deviceWallet)).addESIMWallet(eSIMWallet, true);

        DeviceWallet(payable(_deviceWallet)).setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, _eSIMUniqueIdentifier);

        emit LazyWalletDeployed(_deviceWallet, _deviceUniqueIdentifier, eSIMWallet, _eSIMUniqueIdentifier);

        return eSIMWallet;
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
        // Both mappings are meant to be one-to-one. The deploy paths check that before they get
        // here, but postCreateAccount only checks that the wallet address is new, so without this
        // a second wallet can take over an identifier or a key that already belongs to another.
        // The overwrite is silent and unrecoverable: the identifier keeps resolving to the wrong
        // wallet and the original can never be redeployed against it.
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
}
