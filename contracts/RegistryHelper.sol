pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";

error OnlyLazyWalletRegistry();

contract RegistryHelper {

    event WalletDeployed(
        string _deviceUniqueIdentifier,
        address indexed _deviceWallet,
        address indexed _eSIMWallet
    );

    event DeviceWalletInfoUpdated(
        address indexed _deviceWallet,
        string _deviceUniqueIdentifier,
        address indexed _deviceWalletOwner
    );

    event UpdatedDeviceWalletassociatedWithESIMWallet(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress
    );

    event UpdatedLazyWalletRegistryAddress(
        address indexed _lazyWalletRegistry
    );

    /// @notice Address of the Lazy wallet registry
    address public lazyWalletRegistry;

    /// @notice owner <> device wallet address
    /// @dev There can only be one device wallet per user (ETH address)
    mapping(address => address) public ownerToDeviceWallet;

    /// @notice device unique identifier <> device wallet address
    ///         Mapping for all the device wallets deployed by the registry
    /// @dev Use this to check if a device identifier has already been used or not
    mapping(string => address) public uniqueIdentifierToDeviceWallet;

    /// @notice device wallet address <> owner.
    ///         Mapping of all the devce wallets deployed by the registry (or the device wallet factory)
    ///         to their respecitve owner.
    ///         Mapping returns address(0) if device wallet doesn't exist or if not deployed by the said contracts
    mapping(address => address) public isDeviceWalletValid;

    /// @notice eSIM wallet address <> device wallet address
    ///         All the eSIM wallets deployed using this registry are valid and set to true
    mapping(address => address) public isESIMWalletValid;

    modifier onlyLazyWalletRegistry() {
        if(msg.sender != lazyWalletRegistry) revert OnlyLazyWalletRegistry();
        _;
    }

    /// @notice Function to add or update the lazy wallet registry address
    function addOrUpdateLazyWalletRegistryAddress(
        address _lazyWalletRegistry
    ) public onlyOwner returns (address) {
        require(_lazyWalletRegistry != address(0), "Cannot be zero address");

        lazyWalletRegistry = _lazyWalletRegistry;

        emit UpdatedLazyWalletRegistryAddress(_lazyWalletRegistry);
    }

    /// Allow LazyWalletRegistry  to deploy a device wallet and an eSIM wallet on behalf of a user
    /// @param _deviceOwner Address of the device owner
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and eSIM wallet address
    function deployLazyWallet(
        address _deviceOwner,
        string calldata _deviceUniqueIdentifier,
        string calldata _eSIMUniqueIdentifier,
        uint256 _salt
    ) external onlyLazyWalletRegistry returns (address, address) {
        require(bytes(_deviceUniqueIdentifier).length >= 1, "Device unique identifier cannot be empty");
        require(ownerToDeviceWallet[_deviceOwner] == address(0), "User is already an owner of a device wallet");
        require(
            uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] == address(0),
            "Device wallet already exists"
        );

        address deviceWallet = deviceWalletFactory.deployDeviceWallet(_deviceUniqueIdentifier, _deviceOwner, _salt);
        _updateDeviceWalletInfo(deviceWallet, _deviceUniqueIdentifier, _deviceOwner);

        address eSIMWallet = eSIMWalletFactory.deployESIMWallet(_deviceOwner, _salt);
        _updateESIMInfo(eSIMWallet, deviceWallet);

        emit WalletDeployed(_deviceUniqueIdentifier, deviceWallet, eSIMWallet);

        // Since the eSIM unique identifier is already known in this scenario
        // We can execute the setESIMUniqueIdentifierForAnESIMWallet function in same transaction as deploying the smart wallet
        DeviceWallet(deviceWallet).setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, _eSIMUniqueIdentifier);

        return (deviceWallet, eSIMWallet);
    }

    function _updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        address _deviceWalletOwner
    ) internal {
        ownerToDeviceWallet[_deviceWalletOwner] = _deviceWallet;
        uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] = _deviceWallet;
        isDeviceWalletValid[_deviceWallet] = _deviceWalletOwner;

        emit DeviceWalletInfoUpdated(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwner);
    }

    function _updateESIMInfo(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) internal {
        DeviceWallet(payable(_deviceWalletAddress)).updateESIMInfo(_eSIMWalletAddress, true, true);
        DeviceWallet(payable(_deviceWalletAddress)).updateDeviceWalletAssociatedWithESIMWallet(
            _eSIMWalletAddress,
            _deviceWalletAddress
        );

        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
    }
}
