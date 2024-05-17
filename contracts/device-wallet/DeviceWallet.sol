pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// TODO: Make the contract upgradable
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
// import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// TODO: Add UpgradeableBeacon contract based on https://github.com/OpenZeppelin/openzeppelin-contracts/blob/0db76e98f90550f1ebbb3dea71c7d12d5c533b5c/contracts/proxy/UpgradeableBeacon.sol
// import { UpgradeableBeacon } from "../proxy/UpgradeableBeacon.sol";

error OnlyESIMWalletAdmin();
error OnlyESIMWalletAdminOrDeviceWallet();

// TODO: Add ReentrancyGuard
contract DeviceWallet is Initializable {

    using Address for address;

    /// @notice eSIM wallet project's admin wallet address
    address public eSIMWalletAdmin;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Mapping from eSIMUniqueIdentifier to the respective eSIM wallet address
    mapping(string => address) public eSIMUniqueIdentifierToESIMWalletAddress;

    modifier onlyESIMWalletAdmin() {
        if(msg.sender != eSIMWalletAdmin) revert OnlyESIMWalletAdmin();
        _;
    }

    modifier onlyESIMWalletAdminOrDeviceWallet() {
        if(msg.sender != eSIMWalletAdmin || msg.sender != address(this)) revert OnlyESIMWalletAdminOrDeviceWallet();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// TOOD: Create a mapping of all the device wallets in the device wallet factory to make sure 
    /// only the device wallets deployed by the factory contract are recognised
    /// Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs
    /// @param _deviceUniqueIdentifier String to uniquely identify the device wallet
    /// @param _eSIMUniqueIdentifiers Unique identifiers for already existing eSIMs
    function init(
        address _eSIMWalletAdmin,
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers
    ) external returns (address) {
        require(_eSIMWalletAdmin != address (0), "eSIM wallet admin cannot be zero address");
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be zero");
        
        eSIMWalletAdmin = _eSIMWalletAdmin;
        deviceUniqueIdentifier = _deviceUniqueIdentifier;

        if(_eSIMUniqueIdentifiers.length != 0) {
            for(uint256 i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
                address eSIMWalletAddress = eSIMUniqueIdentifierToESIMWalletAddress[_eSIMUniqueIdentifiers[i]];
                require(eSIMWalletAddress == address(0), "eSIM wallet already exists");
                
                // TODO: deploy esim wallets

                setESIMUniqueIdentifierForAnESIMWallet(eSIMWalletAddress, _eSIMUniqueIdentifiers[i]);
            }
        }

        return address(this);
    }

    function setESIMUniqueIdentifierForAnESIMWallet(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) onlyESIMWalletAdminOrDeviceWallet public {
        // TODO: import esim wallet contract and call respective set identifier function
    }

    receive() external payable {
        // receive ETH
    }
}