pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ESIMWallet } from "../esim-wallet/ESIMWallet.sol";
import { ESIMWalletFactory } from "../esim-wallet/ESIMWalletFactory.sol";

// TODO: Make the contract upgradable
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
// import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// TODO: Add UpgradeableBeacon contract based on https://github.com/OpenZeppelin/openzeppelin-contracts/blob/0db76e98f90550f1ebbb3dea71c7d12d5c533b5c/contracts/proxy/UpgradeableBeacon.sol
// import { UpgradeableBeacon } from "../proxy/UpgradeableBeacon.sol";

error OnlyESIMWalletAdmin();
error OnlyESIMWalletAdminOrDeviceWallet();

// TODO: Add ReentrancyGuard
contract DeviceWallet is Ownable, Initializable {

    using Address for address;

    /// @notice eSIM wallet project's admin wallet address
    address public eSIMWalletAdmin;

    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Mapping from eSIMUniqueIdentifier to the respective eSIM wallet address
    mapping(string => address) public eSIMUniqueIdentifierToESIMWalletAddress;

    /// @notice Set to true if the eSIM wallet belongs to this device wallet
    mapping(address => bool) public isValidESIMWallet;

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
        address _eSIMWalletFactoryAddress,
        address _owner,
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers
    ) external returns (address) {
        require(_eSIMWalletAdmin != address (0), "eSIM wallet admin cannot be zero address");
        require(_owner != address (0), "eSIM wallet owner cannot be zero address");
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be zero");
        
        eSIMWalletAdmin = _eSIMWalletAdmin;
        deviceUniqueIdentifier = _deviceUniqueIdentifier;
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactoryAddress);

        if(_eSIMUniqueIdentifiers.length != 0) {
            for(uint256 i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
                address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(_owner);
                isValidESIMWallet[eSIMWalletAddress] = true;

                setESIMUniqueIdentifierForAnESIMWallet(eSIMWalletAddress, _eSIMUniqueIdentifiers[i]);
            }
        }

        _transferOwnership(_owner);

        return address(this);
    }

    /// @notice Allow device wallet owner to deploy new eSIM wallet
    /// @return eSIM wallet address
    function deployESIMWallet() onlyOwner external returns (address) {
        require(owner != address (0), "eSIM wallet owner cannot be zero address");
        
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(owner);
        isValidESIMWallet[eSIMWalletAddress] = true;

        return eSIMWalletAddress;
    }

    function setESIMUniqueIdentifierForAnESIMWallet(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) onlyESIMWalletAdminOrDeviceWallet public returns(string calldata) {
        require(eSIMUniqueIdentifierToESIMWalletAddress[_eSIMUniqueIdentifier] == address(0), "eSIM unique identifier already set for the provided eSIM wallet");
        
        ESIMWallet eSIMWallet = ESIMWallet(payable(_eSIMWalletAddress));
        eSIMWallet.setESIMUniqueIdentifier(_eSIMUniqueIdentifier);

        return eSIMWallet.eSIMUniqueIdentifier();
    }

    receive() external payable {
        // receive ETH
    }
}