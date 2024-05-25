pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ESIMWallet } from "../esim-wallet/ESIMWallet.sol";
import { ESIMWalletFactory } from "../esim-wallet/ESIMWalletFactory.sol";
import { DeviceWalletFactory } from "./DeviceWalletFactory.sol";

// TODO: Make the contract upgradable
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
// import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// TODO: Add UpgradeableBeacon contract based on https://github.com/OpenZeppelin/openzeppelin-contracts/blob/0db76e98f90550f1ebbb3dea71c7d12d5c533b5c/contracts/proxy/UpgradeableBeacon.sol
// import { UpgradeableBeacon } from "../proxy/UpgradeableBeacon.sol";

error OnlyESIMWalletAdmin();
error OnlyESIMWalletAdminOrDeviceWalletOwner();
error OnlyESIMWalletAdminOrDeviceWalletFactory();
error OnlyAssociatedESIMWallets();
error FailedToTransfer();

// TODO: Add ReentrancyGuard
contract DeviceWallet is Ownable, Initializable {

    using Address for address;

    /// @notice Emitted when the contract pays ETH for data bundle
    event ETHPaidForDataBundle(address indexed _vault, address indexed _eSIMWallet, uint256 indexed _amount);

    /// @notice Emitted when ower updates ETH access to a particular eSIM wallet
    event ETHAccessUpdated(address indexed _eSIMWalletAddress, bool _hasAccessToETH);

    /// @notice Emitted when ETH is sent out from the contract
    /// @dev mostly when an eSIM wallet pulls ETH from this contract
    event ETHSent(address indexed _eSIMWalletAddress, uint256 _amount);

    /// @notice ESIM wallet factory contract instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice Device wallet factory contract instance
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Mapping from eSIMUniqueIdentifier to the respective eSIM wallet address
    mapping(string => address) public eSIMUniqueIdentifierToESIMWalletAddress;

    /// @notice Set to true if the eSIM wallet belongs to this device wallet
    mapping(address => bool) public isValidESIMWallet;

    /// @notice Mapping that tracks if an associated eSIM wallet can pull ETH or not
    mapping(address => bool) public canPullETH;

    modifier onlyESIMWalletAdmin() {
        if(msg.sender != deviceWalletFactory.eSIMWalletAdmin()) revert OnlyESIMWalletAdmin();
        _;
    }

    modifier onlyESIMWalletAdminOrDeviceWalletFactory() {
        if(
            msg.sender != deviceWalletFactory.eSIMWalletAdmin() && 
            msg.sender != address(deviceWalletFactory)
        ) revert OnlyESIMWalletAdminOrDeviceWalletFactory();
        _;
    }

    modifier onlyESIMWalletAdminOrDeviceWalletOwner() {
        if(
            msg.sender != deviceWalletFactory.eSIMWalletAdmin() && 
            msg.sender != owner
        ) revert OnlyESIMWalletAdminOrDeviceWalletOwner();
        _;
    }

    modifier onlyAssociatedESIMWallets() {
        if(!isValidESIMWallet[msg.sender]) revert OnlyAssociatedESIMWallets();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs
    /// @param _deviceWalletFactoryAddress Device wallet factory smart contract address
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory smart contract address
    /// @param _owner User's address (Owner of device wallet and related eSIM wallet smart contracts)
    /// @param _deviceUniqueIdentifier String to uniquely identify the device wallet
    /// @param _dataBundleIDs List of data bundle IDs to be bought for respective eSIMs
    /// @param _dataBundlePrices List of data bundle prices for the respective data bundle IDs
    /// @param _eSIMUniqueIdentifiers Unique identifiers for already existing eSIMs
    function init(
        address _deviceWalletFactoryAddress,
        address _eSIMWalletFactoryAddress,
        address _owner,
        string calldata _deviceUniqueIdentifier,
        string[] calldata _dataBundleIDs,
        uint256[] calldata _dataBundlePrices,
        string[] calldata _eSIMUniqueIdentifiers
    ) external payable returns (address) {
        require(_deviceWalletFactoryAddress != address(0), "Device wallet factory cannot be zero address");
        require(_owner != address (0), "eSIM wallet owner cannot be zero address");
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be zero");
        require(_dataBundleIDs.length > 0, "Data bundle ID array cannot be zero");
        require(_dataBundleIDs.length == _dataBundlePrices.length, "Array mismatch");
        
        deviceWalletFactory = DeviceWalletFactory(_deviceWalletFactoryAddress);
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
                canPullETH[eSIMWalletAddress] = true;
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
            canPullETH[eSIMWalletAddress] = true;
            leftOverETH -= _dataBundlePrices[0];
        }

        _transferOwnership(_owner);

        return address(this);
    }

    /// @notice Allow device wallet owner to deploy new eSIM wallet
    /// @param _dataBundleID String data bundle ID to be bought for the eSIM
    /// @param _dataBundlePrice Price in uint256 for the data bundle
    /// @param _eSIMUniqueIdentifier String unique identifier for the eSIM wallet
    /// @param _hasAccessToETH Set to true if the eSIM wallet is allowed to pull ETH from this wallet.
    /// @return eSIM wallet address
    function deployESIMWallet(
        string calldata _dataBundleID,
        uint256 _dataBundlePrice,
        string calldata _eSIMUniqueIdentifier,
        bool _hasAccessToETH
    ) onlyOwner external payable returns (address) {
        require(owner != address (0), "eSIM wallet owner cannot be zero address");

        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet{value: _dataBundlePrice}(
            owner,
            _dataBundleID,
            _dataBundlePrice,
            _eSIMUniqueIdentifier
        );

        isValidESIMWallet[eSIMWalletAddress] = true;
        canPullETH[eSIMWalletAddress] = _hasAccessToETH;

        uint256 leftOverETH = msg.value - _dataBundlePrice;

        return eSIMWalletAddress;
    }

    /// @notice Allow wallet owner or admin to set unique identifier for their eSIM wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet smart contract
    /// @param _eSIMUniqueIdentifier String unique identifier for the eSIM wallet
    function setESIMUniqueIdentifierForAnESIMWallet(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) onlyESIMWalletAdmin public returns(string calldata) {
        require(ESIMWalletFactory.isValidESIMWallet(_eSIMWalletAddress) == true, "Unknown eSIM wallet address provided");
        require(eSIMUniqueIdentifierToESIMWalletAddress[_eSIMUniqueIdentifier] == address(0), "eSIM unique identifier already set for the provided eSIM wallet");
        
        ESIMWallet eSIMWallet = ESIMWallet(payable(_eSIMWalletAddress));
        eSIMWallet.setESIMUniqueIdentifier(_eSIMUniqueIdentifier);

        return eSIMWallet.eSIMUniqueIdentifier();
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pay ETH for data bundles
    /// @dev Instead of pulling the ETH into the eSIM wallet and then sending to the vault,
    ///      the eSIM wallet can directly request the device wallet to pay ETH for the data bundles
    /// @param _amount Amount of ETH to pull
    function payETHForDataBundles(
        uint256 _amount
    ) onlyAssociatedESIMWallets external returns (uint256) {
        require(_amount > 0, "Amount cannot be zero");
        require(canPullETH[msg.sender] == true, "Cannot pull ETH. Access has been revoked");
        
        address vault = getVaultAddress();
        _transferETH(vault, _amount);

        emit ETHPaidForDataBundle(vault, msg.sender, _amount);

        return _amount;
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pull ETH (for data bundles)
    /// @param _amount Amount of ETH to pull
    function pullETH(
        uint256 _amount
    ) onlyAssociatedESIMWallets external returns (uint256) {
        require(_amount > 0, "Amount cannot be zero");
        require(canPullETH[msg.sender] == true, "Cannot pull ETH. Access has been revoked");
        
        _transferETH(msg.sender, _amount);

        return _amount;
    }

    /// @notice Fetches the vault address (that receives payment for data bundles) from the device wallet factory
    /// @dev Mostly used by the associated eSIM wallets for reference
    function getVaultAddress() public view returns (address) {
        return deviceWalletFactory.vault();
    }

    /// @notice Allow owner to revoke or give access to any associated eSIM wallet for pulling ETH
    /// @param _eSIMWalletAddress Address of the eSIM wallet to toggle ETH access for
    /// @param _hasAccessToETH Set to true to give access, false to revoke access
    function toggleAccessToETH(
        address _eSIMWalletAddress,
        bool _hasAccessToETH
    ) onlyOwner external {
        require(isValidESIMWallet[_eSIMWalletAddress], "Invalid eSIM wallet address");

        canPullETH[_eSIMWalletAddress] = _hasAccessToETH;

        emit ETHAccessUpdated(_eSIMWalletAddress, _hasAccessToETH);
    }

    function _transferETH(address _recipient, uint256 _amount) internal virtual {
        require(_amount <= address(this).balance, "Not enough ETH in the wallet. Please topup ETH into the wallet");
        require(_recipient != address(0), "Recipient cannot be zero address");

        if (_amount > 0) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert FailedToTransfer();
            else ETHSent(_recipient, _amount);
        }
    }

    receive() external payable {
        // receive ETH
    }
}