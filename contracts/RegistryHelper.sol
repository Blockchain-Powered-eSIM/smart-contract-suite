pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";

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
