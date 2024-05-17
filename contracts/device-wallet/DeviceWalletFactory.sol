pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { DeviceWallet } from "./DeviceWallet.sol";
// TODO: Implement Beacon Proxy, as per need
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @notice Contract for deploying a new eSIM wallet
contract DeviceWalletFactory {

    /// @notice Emitted when factory is deployed and admin is set
    event DeviceWalletFactoryDeployed(address indexed _factoryAddress, address indexed _admin);

    /// @notice Emitted when a new device wallet is deployed
    event DeviceWalletDeployed(address indexed _deviceWalletAddress, address[] indexed _eSIMUniqueIdentifiers);

    /// @notice Admin address of the eSIM wallet project
    address public esimWalletAdmin;

    /// @notice deviceUniqueIdentifier <> deviceWalletAddress
    mapping(string => address) public walletAddressOfDeviceUniqueIdentifier;

    /// @notice Set to true if device wallet was deployed by the device wallet factory, false otherwise.
    mapping(address => bool) public isDeviceWalletValid;

    constructor(
        address _esimWalletAdmin
    ) {
        require(_esimWalletAdmin != address(0), "Admin cannot be zero address");

        esimWalletAdmin = _esimWalletAdmin;
        emit DeviceWalletFactoryDeployed(address(this), _esimWalletAdmin);
    }

    /// @notice To deploy multiple device wallets at once
    /// @param _deviceUniqueIdentifiers Array of unique device identifiers for each device wallet
    /// @param _eSIMUniqueIdentifiers 2D array of unique eSIM identifiers for each device wallet
    /// @return Array of deployed device wallet address
    function deployMultipleDeviceWalletWithESIMWallets(
        string[] calldata _deviceUniqueIdentifiers,
        string[][] calldata _eSIMUniqueIdentifiers
    ) public returns (address[]) {
        uint256 numberOfDeviceWallets = _deviceUniqueIdentifiers.length;
        require(numberOfDeviceWallets != 0, "Array cannot be empty");
        require(numberOfDeviceWallets == _eSIMUniqueIdentifiers.length, "Array mismatch");

        address[] memory deviceWalletsDeployed = new address[](numberOfDeviceWallets);

        for(uint256 i=0; i<numberOfDeviceWallets; ++i) {
            require(
                walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifiers[i]] == address(0), 
                "Device wallet already exists"
            );

            // TODO: Correctly deploy Device wallet as clones
            address deviceWalletAddress = DeviceWallet.init(
                esimWalletAdmin,
                msg.sender,
                _deviceUniqueIdentifiers[i],
                _eSIMUniqueIdentifiers[i]
            );

            isDeviceWalletValid[deviceWalletAddress] = true;
            walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifiers[i]] = deviceWalletAddress;
            deviceWalletsDeployed[i] = deviceWalletAddress;

            emit DeviceWalletDeployed(deviceWalletAddress, _eSIMUniqueIdentifiers[i]);
        }

        return deviceWalletsDeployed;
    }

    function deployDeviceWalletWithESIMWallets(
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers
    ) public returns (address) {
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be empty");
        require();
    }
}