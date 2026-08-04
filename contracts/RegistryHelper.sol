pragma solidity 0.8.36;

// SPDX-License-Identifier: MIT

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {P256Verifier} from "./P256Verifier.sol";
import {Errors} from "./Errors.sol";
import "./CustomStructs.sol";

contract RegistryHelper {

    event LazyWalletDeployed(
        address indexed _deviceWallet, 
        string _deviceUniqueIdentifier, 
        address indexed _eSIMWallet, 
        string _eSIMUniqueIdentifier
    );

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

    event UpdatedDeviceWalletassociatedWithESIMWallet(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress
    );

    event UpdatedLazyWalletRegistryAddress(
        address indexed _lazyWalletRegistry
    );

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

    event ESIMWalletSetOnStandby(
        address indexed _eSIMWalletAddress,
        bool _isOnStandby,
        address indexed _deviceWalletAddress
    );

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
    mapping(address eSIMWalletAddress => address deviceWalletAddress) public isESIMWalletValid;

    /// @notice If an existing eSIM wallet is in the process of being transferred from one device wallet to another
    ///         If bool is `true`, it means that the eSIM wallet has no device wallet associated to it yet
    mapping(address eSIMWalletAddress => bool isOnStandby) public isESIMWalletOnStandby;

    /// @dev Registry inherits this contract and its own state begins directly after this gap, so
    ///      a new variable here has to consume gap slots rather than follow them. One appended
    ///      below moves every Registry variable on the deployed proxies.
    uint256[50] private __gap;

    modifier onlyLazyWalletRegistry() {
        if(msg.sender != lazyWalletRegistry) revert Errors.OnlyLazyWalletRegistry();
        _;
    }

    /// @notice Allow LazyWalletRegistry to deploy a device wallet and an eSIM wallet on behalf of a user
    /// @param _deviceWalletOwnerKey P256 public key of user
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and list of addresses of all the eSIM wallets
    function deployLazyWallet(
        bytes32[2] memory _deviceWalletOwnerKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        string[] calldata _eSIMUniqueIdentifiers,
        DataBundleDetails[][] calldata _dataBundleDetails,
        uint256 _depositAmount
    ) external payable onlyLazyWalletRegistry returns (address, address[] memory) {
        if(_eSIMUniqueIdentifiers.length + _salt >= type(uint256).max) {
            revert Errors.SaltTooHigh(_salt, _eSIMUniqueIdentifiers.length);
        }

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
        // Populate data bundle purchase details for the eSIM wallet
        ESIMWallet(payable(firstESIMWallet)).populateHistory(_dataBundleDetails[i]);
        // Increase the index to deploy, set identifier and populate history for the remaining _eSIMUniqueIdentifiers
        i++;

        for(; i<_eSIMUniqueIdentifiers.length; ++i) {
            // increase salt for subsequent eSIM wallet deployments
            address eSIMWallet = eSIMWalletFactory.deployESIMWallet(deviceWallet, (_salt + i));

            // Updates the Device wallet storage variables as well as for the registry
            DeviceWallet(payable(deviceWallet)).addESIMWallet(eSIMWallet, true);

            // Since the eSIM unique identifier is already known in this scenario
            // We can execute the setESIMUniqueIdentifierForAnESIMWallet function in same transaction as deploying the smart wallet
            DeviceWallet(payable(deviceWallet)).setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, _eSIMUniqueIdentifiers[i]);

            // Populate data bundle purchase details for the eSIM wallet
            ESIMWallet(payable(eSIMWallet)).populateHistory(_dataBundleDetails[i]);

            eSIMWallets[i] = eSIMWallet;

            emit LazyWalletDeployed(deviceWallet, _deviceUniqueIdentifier, eSIMWallet, _eSIMUniqueIdentifiers[i]);
        }

        return (deviceWallet, eSIMWallets);
    }

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
