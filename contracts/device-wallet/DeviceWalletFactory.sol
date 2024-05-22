pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { DeviceWallet } from "./DeviceWallet.sol";
// TODO: Implement Beacon Proxy, as per need
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @notice Contract for deploying a new eSIM wallet
contract DeviceWalletFactory {

    /// @notice Emitted when the admin sets the eSIM wallet factory address
    event SetESIMWalletFactoryAddress(address indexed _eSIMWalletFactoryAddress);

    /// @notice Emitted when factory is deployed and admin is set
    event DeviceWalletFactoryDeployed(address indexed _factoryAddress, address indexed _admin);

    /// @notice Emitted when a new device wallet is deployed
    event DeviceWalletDeployed(address indexed _deviceWalletAddress, address[] indexed _eSIMUniqueIdentifiers);

    /// @notice Admin address of the eSIM wallet project
    address public eSIMWalletAdmin;

    /// @notice eSIM wallet factory contract address;
    address public eSIMWalletFactoryAddress;

    /// @notice deviceUniqueIdentifier <> deviceWalletAddress
    mapping(string => address) public walletAddressOfDeviceUniqueIdentifier;

    /// @notice Set to true if device wallet was deployed by the device wallet factory, false otherwise.
    mapping(address => bool) public isDeviceWalletValid;

    constructor(
        address _eSIMWalletAdmin
    ) {
        require(_eSIMWalletAdmin != address(0), "Admin cannot be zero address");

        eSIMWalletAdmin = _eSIMWalletAdmin;
        emit DeviceWalletFactoryDeployed(address(this), _eSIMWalletAdmin);
    }

    function setESIMWalletFactoryAddress(
        address _eSIMWalletFactoryAddress
    ) public {
        require(msg.sender == eSIMWalletAdmin, "Only eSIM wallet project admin can call");

        eSIMWalletFactoryAddress = _eSIMWalletFactoryAddress;

        emit SetESIMWalletFactoryAddress(eSIMWalletFactoryAddress);
    }

    /// @notice To deploy multiple device wallets at once
    /// @param _deviceUniqueIdentifiers Array of unique device identifiers for each device wallet
    /// @param _eSIMUniqueIdentifiers 2D array of unique eSIM identifiers for each device wallet
    /// @return Array of deployed device wallet address
    function deployMultipleDeviceWalletsWithESIMWallets(
        string[] calldata _deviceUniqueIdentifiers,
        string[][] calldata _eSIMUniqueIdentifiers
    ) public returns (address[]) {
        uint256 numberOfDeviceWallets = _deviceUniqueIdentifiers.length;
        require(numberOfDeviceWallets != 0, "Array cannot be empty");
        require(numberOfDeviceWallets == _eSIMUniqueIdentifiers.length, "Array mismatch");

        address[] memory deviceWalletsDeployed = new address[](numberOfDeviceWallets);

        for(uint256 i=0; i<numberOfDeviceWallets; ++i) {
            deviceWalletsDeployed[i] = _deployDeviceWalletWithESIMWallets(
                _deviceUniqueIdentifiers[i],
                _eSIMUniqueIdentifiers[i],
                msg.sender
            );
        }

        return deviceWalletsDeployed;
    }

    /// @dev To deploy a device wallet and eSIM wallets for given unique eSIM identifiers
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _eSIMUniqueIdentifiers Array of unique eSIM identifiers for the device wallet
    /// @return Deployed device wallet address
    function _deployDeviceWalletWithESIMWallets(
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers,
        address _owner
    ) internal returns (address) {
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be empty");
        require(eSIMWalletFactoryAddress != address(0), "eSIM wallet factory address not set or contract not deployed");
        
        require(
            walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifier] == address(0), 
            "Device wallet already exists"
        );

        // TODO: Correctly deploy Device wallet as clones
        address deviceWalletAddress = DeviceWallet.init(
            eSIMWalletAdmin,
            eSIMWalletFactoryAddress,
            _owner,
            _deviceUniqueIdentifier,
            _eSIMUniqueIdentifiers[i]
        );

        isDeviceWalletValid[deviceWalletAddress] = true;
        walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifier] = deviceWalletAddress;

        emit DeviceWalletDeployed(deviceWalletAddress, _eSIMUniqueIdentifiers[i]);

        return deviceWalletAddress;
    }

    /// @notice To deploy a device wallet and an uninitialised eSIM wallet
    /// @dev The eSIM wallet will have to be initialised with the eSIM unique identifier in a separate function call
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _owner User's address (Owner of device wallet and respective eSIM wallet)
    /// @param _dataBundleID String data bundle ID to be bought for eSIM
    /// @param _dataBundlePrice uint256 price of data bundle
    /// @return Deployed device wallet address
    function deployDeviceWallet(
        string calldata _deviceUniqueIdentifier,
        address _owner,
        string calldata _dataBundleID,
        uint256 _dataBundlePrice
    ) public payable returns (address) {
        require(eSIMWalletFactoryAddress != address(0), "eSIM wallet factory address not set or contract not deployed");
        require(
            walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifier] == address(0), 
            "Device wallet already exists"
        );

        // TODO: Correctly deploy Device wallet as clones
        address deviceWalletAddress = DeviceWallet.init{value: msg.value}(
            eSIMWalletAdmin,
            eSIMWalletFactoryAddress,
            _owner,
            _deviceUniqueIdentifier,
            [_dataBundleID],
            [_dataBundlePrice],
            []
        );

        isDeviceWalletValid[deviceWalletAddress] = true;
        walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifier] = deviceWalletAddress;

        emit DeviceWalletDeployed(deviceWalletAddress, "");

        return deviceWalletAddress;
    }
}