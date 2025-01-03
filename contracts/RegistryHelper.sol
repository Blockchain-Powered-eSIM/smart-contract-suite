pragma solidity ^0.8.18;

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
        address indexed _eSIMWalletFactory,
        address _verifier
    );

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

    /// @notice device unique identifier <> device wallet address
    ///         Mapping for all the device wallets deployed by the registry
    /// @dev Use this to check if a device identifier has already been used or not
    mapping(string => address) public uniqueIdentifierToDeviceWallet;

    /// @notice device wallet address <> owner P256 public key.
    mapping(address => bytes32[2]) public deviceWalletToOwner;

    /// @notice keccak256 hash to device wallet address
    /// @dev keccak256(abi.encode(X, Y)) <> device wallet address
    /// Used to maintain one-to-one relationship between P256 keys and device wallet
    mapping(bytes32 => address) public registeredP256Keys;

    /// @notice device wallet address <> boolean (true if deployed by the registry or device wallet factory)
    ///         Mapping of all the device wallets deployed by the registry (or the device wallet factory)
    ///         to their respective owner.
    mapping(address => bool) public isDeviceWalletValid;

    /// @notice eSIM wallet address <> device wallet address
    ///         All the eSIM wallets deployed using this registry are valid and set to true
    mapping(address => address) public isESIMWalletValid;

    /// @notice If an existing eSIM wallet is in the process of being transferred from one device wallet to another
    ///         If bool is `true`, it means that the eSIM wallet has no device wallet associated to it yet
    mapping(address => bool) public isESIMWalletOnStandby;

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
        string[] memory _eSIMUniqueIdentifiers,
        DataBundleDetails[][] memory _dataBundleDetails,
        uint256 _depositAmount
    ) external payable onlyLazyWalletRegistry returns (address, address[] memory) {
        require(_eSIMUniqueIdentifiers.length + _salt < type(uint256).max, "Salt value too high");
        require(
            uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] == address(0),
            "Device wallet already exists"
        );

        // Deploys device smart wallet
        // Updates device wallet info via Registry
        address deviceWallet = address(deviceWalletFactory.createAccount(_deviceUniqueIdentifier, _deviceWalletOwnerKey, _salt, _depositAmount));

        address[] memory eSIMWallets = new address[](_eSIMUniqueIdentifiers.length);

        for(uint256 i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
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
        uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] = _deviceWallet;
        isDeviceWalletValid[_deviceWallet] = true;
        deviceWalletToOwner[_deviceWallet] = _deviceWalletOwnerKey;
        
        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        registeredP256Keys[keyHash] = _deviceWallet;

        emit DeviceWalletInfoUpdated(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }
}
