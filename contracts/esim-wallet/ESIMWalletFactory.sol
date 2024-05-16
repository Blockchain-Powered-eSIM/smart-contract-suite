pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { ESIMWallet } from "./ESIMWallet.sol";
// TODO: Implement Beacon Proxy, as per need
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

error OnlyDeviceWalletFactory();

/// @notice Contract for deploying a new eSIM wallet
contract ESIMWalletFactory {

    /// @notice Emitted when a new eSIM wallet is deployed
    event ESIMWalletDeployed(address indexed eSIMWalletAddress);

    /// @notice Address of the device wallet factory
    address public deviceWalletFactoryAddress;

    /// @notice eSIMUniqueIdentifier <> eSIMWalletAddress
    mapping(string => address) public isESIMWalletDeployed;

    modifier onlyDeviceWalletFactory() {
        if(msg.sender != deviceWalletFactoryAddress) revert OnlyDeviceWalletFactory();
        _;
    }

    /// @param _deviceWalletFactoryAddress Address of the device wallet factory address
    constructor(
        address _deviceWalletFactoryAddress
    ) {
        require(_deviceWalletFactoryAddress != address(0), "Address cannot be zero");

        deviceWalletFactoryAddress = _deviceWalletFactoryAddress;
        // TODO: make the factory upgradable
        // beacon = address(new UpgradeableBeacon(_esimWalletImplementation, _upgradeManager));
    }

    /// Function to deploy an eSIM wallet
    /// @dev can only be called by the deviceWalletFactory contract
    /// @param _eSIMUniqueIdentifier eSIM's unique identifier
    /// @return Address of the newly eployed eSIM wallet
    function deployESIMWallet(
        string calldata _eSIMUniqueIdentifier
    ) onlyDeviceWalletFactory public returns (address) {
        require(bytes(_eSIMUniqueIdentifier).length != 0, "eSIMUniqueIdentifier cannot be zero");

        address eSIMWalletAddress = ESIMWallet.init(_eSIMUniqueIdentifier, address(this));
        isESIMWalletDeployed[_eSIMUniqueIdentifier] = eSIMWalletAddress;

        emit ESIMWalletDeployed(eSIMWalletAddress);

        return eSIMWalletAddress;
    }
}