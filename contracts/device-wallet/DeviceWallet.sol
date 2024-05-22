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

    /// @notice ETH balance of the contract
    uint256 public ethBalance;

    /// @notice ESIM wallet factory contract instance
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

    /// @notice Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs
    /// @param _eSIMWalletAdmin Admin address of eSIM wallet project
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory smart contract address
    /// @param _owner User's address (Owner of device wallet and related eSIM wallet smart contracts)
    /// @param _deviceUniqueIdentifier String to uniquely identify the device wallet
    /// @param _dataBundleIDs List of data bundle IDs to be bought for respective eSIMs
    /// @param _dataBundlePrices List of data bundle prices for the respective data bundle IDs
    /// @param _eSIMUniqueIdentifiers Unique identifiers for already existing eSIMs
    function init(
        address _eSIMWalletAdmin,
        address _eSIMWalletFactoryAddress,
        address _owner,
        string calldata _deviceUniqueIdentifier,
        string[] calldata _dataBundleIDs,
        uint256[] _dataBundlePrices,
        string[] calldata _eSIMUniqueIdentifiers
    ) external payable returns (address) {
        require(_eSIMWalletAdmin != address (0), "eSIM wallet admin cannot be zero address");
        require(_owner != address (0), "eSIM wallet owner cannot be zero address");
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be zero");
        require(_dataBundleIDs.length > 0, "Data bundle ID array cannot be zero");
        require(_dataBundleIDs.length == _dataBundlePrices.length, "Array mismatch");
        
        eSIMWalletAdmin = _eSIMWalletAdmin;
        deviceUniqueIdentifier = _deviceUniqueIdentifier;
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactoryAddress);

        uint256 leftOverETH = msg.value;

        if(_eSIMUniqueIdentifiers.length != 0) {
            uint256 len = _eSIMUniqueIdentifiers.length;
            require(len == _dataBundleIDs.length, "Insufficient data bundle IDs provided");

            for(uint256 i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
                require(leftOverETH >= _dataBundlePrices[i], "Not enough ETH left for data bundle");

                address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet{value: _dataBundlePrices[i]}(
                    _owner,
                    _dataBundleIDs[i],
                    _dataBundlePrices[i],
                    _eSIMUniqueIdentifiers[i]
                );
                
                isValidESIMWallet[eSIMWalletAddress] = true;
                leftOverETH -= _dataBundlePrices[i];
            }
        }
        else {
            address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet{value: _dataBundlePrices[0]}(
                _owner,
                _dataBundleIDs[0],
                _dataBundlePrices[0],
                "" // uninitialised eSIM unique identifier
            );

            isValidESIMWallet[eSIMWalletAddress] = true;
            leftOverETH -= _dataBundlePrices[0];
        }

        if(leftOverETH > 0) {
            ethBalance += leftOverETH;
        }

        _transferOwnership(_owner);

        return address(this);
    }

    /// @notice Allow device wallet owner to deploy new eSIM wallet
    /// @param _dataBundleID String data bundle ID to be bought for the eSIM
    /// @param _dataBundlePrice Price in uint256 for the data bundle
    /// @param _eSIMUniqueIdentifier String unique identifier for the eSIM wallet
    /// @return eSIM wallet address
    function deployESIMWallet(
        string calldata _dataBundleID,
        uint256 _dataBundlePrice,
        string calldata _eSIMUniqueIdentifier
    ) onlyOwner external payable returns (address) {
        require(owner != address (0), "eSIM wallet owner cannot be zero address");

        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet{value: _dataBundlePrice}(
            owner,
            _eSIMUniqueIdentifier
        );

        isValidESIMWallet[eSIMWalletAddress] = true;
        uint256 leftOverETH = msg.value - _dataBundlePrice;
        if(leftOverETH > 0) {
            ethBalance += leftOverETH;
        }

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
        ethBalance += msg.value;
        // receive ETH
    }
}