pragma solidity 0.8.25;

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

    // Reserved storage gap for future upgrades
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
        string[] memory _eSIMUniqueIdentifiers,
        DataBundleDetails[][] memory _dataBundleDetails,
        uint256 _depositAmount
    ) external payable onlyLazyWalletRegistry returns (address, address[] memory) {
        require(_eSIMUniqueIdentifiers.length + _salt < type(uint256).max, "Salt value too high");
        require(
            uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] == address(0),
            "Device wallet already exists"
        );

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
        uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] = _deviceWallet;
        isDeviceWalletValid[_deviceWallet] = true;
        deviceWalletToOwner[_deviceWallet] = _deviceWalletOwnerKey;
        
        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        registeredP256Keys[keyHash] = _deviceWallet;

        emit DeviceWalletInfoUpdated(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }
}
