pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { ESIMWallet } from "./ESIMWallet.sol";
import { DeviceWalletFactory } from "../device-wallet/DeviceWalletFactory.sol";
import { UpgradeableBeacon } from "../UpgradableBeacon.sol";

error OnlyDeviceWalletFactory();

/// @notice Contract for deploying a new eSIM wallet
contract ESIMWalletFactory {

    /// @notice Emitted when the eSIM wallet factory is deployed
    event ESIMWalletFactorydeployed(
        address indexed _eSIMWalletFactory, 
        address indexed _deviceWalletFactory, 
        address indexed _upgradeManager, 
        address indexed _eSIMWalletImplementation, 
        address indexed beacon
    );

    /// @notice Emitted when a new eSIM wallet is deployed
    event ESIMWalletDeployed(address indexed _eSIMWalletAddress, string _dataBundleID, uint256 _dataBundlePrice, address indexed _deviceWalletAddress);

    /// @notice Address of the device wallet factory
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice Implementation at the time of deployment
    address public eSIMWalletImplementation;

    /// @notice Beacon referenced by each deployment of a savETH vault
    address public beacon;

    /// @notice Set to true if eSIM wallet address is deployed using the factory, false otherwise
    mapping(address => bool) public isESIMWalletDeployed;

    modifier onlyDeviceWalletFactory() {
        if(msg.sender != address(deviceWalletFactory)) revert OnlyDeviceWalletFactory();
        _;
    }

    /// @param _deviceWalletFactoryAddress Address of the device wallet factory address
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    constructor(
        address _deviceWalletFactoryAddress,
        address _upgradeManager
    ) {
        require(_deviceWalletFactoryAddress != address(0), "Address cannot be zero");
        require(_upgradeManager != address(0), "Address cannot be zero");

        deviceWalletFactory = DeviceWalletFactory(_deviceWalletFactoryAddress);
        
        // eSIM wallet implementation (logic) contract
        eSIMWalletImplementation = address(new ESIMWallet());
        // Upgradable beacon for eSIM wallet implementation contract
        beacon = address(new UpgradeableBeacon(eSIMWalletImplementation, _upgradeManager));

        emit ESIMWalletFactorydeployed(address(this), address(deviceWalletFactory), _upgradeManager, eSIMWalletImplementation, beacon);
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

        // msg.value will be sent along with the abi.encodeCall
        address eSIMWalletAddress = address(new BeaconProxy(
            beacon,
            abi.encodeCall(
                ESIMWallet(payable(eSIMWalletImplementation)).init,
                (
                    address(this), 
                    msg.sender, 
                    _owner,
                    _dataBundleID,
                    _dataBundlePrice, 
                    _eSIMUniqueIdentifier
                )
            )
        ));
        isESIMWalletDeployed[eSIMWalletAddress] = true;

        emit ESIMWalletDeployed(eSIMWalletImplementation, eSIMWalletAddress, _dataBundleID, _dataBundlePrice, msg.sender);

        return eSIMWalletAddress;
    }
}