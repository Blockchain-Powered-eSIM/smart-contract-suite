pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ESIMWallet } from "./ESIMWallet.sol";
import { DeviceWalletFactory } from "../device-wallet/DeviceWalletFactory.sol";

error OnlyDeviceWalletFactory();

/// @notice Contract for deploying a new eSIM wallet
contract ESIMWalletFactory {

    /// @notice Emitted when a new eSIM wallet is deployed
    event ESIMWalletDeployed(address indexed _eSIMWalletAddress, string _dataBundleID, uint256 _dataBundlePrice, address indexed _deviceWalletAddress);

    /// @notice Address of the device wallet factory
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice Set to true if eSIM wallet address is deployed using the factory, false otherwise
    mapping(address => bool) public isESIMWalletDeployed;

    modifier onlyDeviceWalletFactory() {
        if(msg.sender != address(deviceWalletFactory)) revert OnlyDeviceWalletFactory();
        _;
    }

    /// @param _deviceWalletFactoryAddress Address of the device wallet factory address
    constructor(
        address _deviceWalletFactoryAddress
    ) {
        require(_deviceWalletFactoryAddress != address(0), "Address cannot be zero");

        deviceWalletFactory = DeviceWalletFactory(_deviceWalletFactoryAddress);
        // TODO: make the factory upgradable
        // beacon = address(new UpgradeableBeacon(_esimWalletImplementation, _upgradeManager));
    }

    /// Function to deploy an eSIM wallet
    /// @dev can only be called by the respective deviceWallet contract
    /// @param _owner Owner of the eSIM wallet
    /// @param _dataBundleID String ID of data bundle to buy for the new eSIM
    /// @param _dataBundlePrice uint256 USD price for data bundle
    /// @return Address of the newly deployed eSIM wallet
    function deployESIMWallet(
        address _owner,
        string calldata _dataBundleID,
        uint256 _dataBundlePrice,
        string calldata _eSIMUniqueIdentifier
    ) external payable returns (address) {
        require(deviceWalletFactory.isDeviceWalletValid(msg.sender), "Only device wallet can call this");

        // TODO: Correctly deploy ESIMWallet as a clone
        address eSIMWalletAddress = ESIMWallet.init{value: _dataBundlePrice}(
            address(this), 
            msg.sender, 
            _owner,
            _dataBundleID,
            _dataBundlePrice, 
            _eSIMUniqueIdentifier
        );
        isESIMWalletDeployed[eSIMWalletAddress] = true;

        emit ESIMWalletDeployed(eSIMWalletAddress, _dataBundleID, _dataBundlePrice, msg.sender);

        return eSIMWalletAddress;
    }
}