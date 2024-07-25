pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {Registry} from "../Registry.sol";
import {DeviceWalletFactory} from "./DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "../esim-wallet/ESIMWallet.sol";
import {Account4337} from "../aa-helper/Account4337.sol";

error OnlyRegistryOrDeviceWalletFactoryOrOwner();
error OnlyDeviceWalletOrOwner();
error OnlyESIMWalletAdmin();
error OnlyESIMWalletAdminOrDeviceWalletOwner();
error OnlyESIMWalletAdminOrDeviceWalletFactory();
error OnlyAssociatedESIMWallets();
error FailedToTransfer();

// TODO: Add ReentrancyGuard
contract DeviceWallet is Initializable, Account4337 {
    using Address for address;

    /// @notice Emitted when the contract pays ETH for data bundle
    event ETHPaidForDataBundle(address indexed _vault, address indexed _eSIMWallet, uint256 indexed _amount);

    /// @notice Emitted when ower updates ETH access to a particular eSIM wallet
    event ETHAccessUpdated(address indexed _eSIMWalletAddress, bool _hasAccessToETH);

    /// @notice Emitted when ETH is sent out from the contract
    /// @dev mostly when an eSIM wallet pulls ETH from this contract
    event ETHSent(address indexed _eSIMWalletAddress, uint256 _amount);

    /// @notice Emitted when eSIM wallet is deployed
    event ESIMWalletDeployed(address indexed _eSIMWalletAddress, bool _hasAccessToETH);

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Mapping from eSIMUniqueIdentifier to the respective eSIM wallet address
    mapping(string => address) public uniqueIdentifierToESIMWallet;

    /// @notice Set to true if the eSIM wallet belongs to this device wallet
    mapping(address => bool) public isValidESIMWallet;

    /// @notice Mapping that tracks if an associated eSIM wallet can pull ETH or not
    mapping(address => bool) public canPullETH;

    function _onlyRegistryOrDeviceWalletFactoryOrOwner() private view {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            msg.sender != owner
        ) {
            revert OnlyRegistryOrDeviceWalletFactoryOrOwner();
        }
    }

    modifier onlyRegistryOrDeviceWalletFactoryOrOwner() {
        _onlyRegistryOrDeviceWalletFactoryOrOwner();
        _;
    }

    function _onlyDeviceWalletFactoryOrOwner() private view {
        if(
            msg.sender != owner &&
            msg.sender != address(registry.deviceWalletFactory())
        ) {
            revert OnlyDeviceWalletOrOwner();
        }
    }

    modifier onlyDeviceWalletFactoryOrOwner() {
        _onlyDeviceWalletFactoryOrOwner();
        _;
    }

    function _onlyESIMWalletAdmin() private view {
        if (msg.sender != registry.deviceWalletFactory().eSIMWalletAdmin()) {
            revert OnlyESIMWalletAdmin();
        }
    }

    modifier onlyESIMWalletAdmin() {
        _onlyESIMWalletAdmin();
        _;
    }

    function _onlyAssociatedESIMWallets() private view {
        if (!isValidESIMWallet[msg.sender]) revert OnlyAssociatedESIMWallets();
    }

    modifier onlyAssociatedESIMWallets() {
        _onlyAssociatedESIMWallets();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IEntryPoint anEntryPoint) Account4337(anEntryPoint) initializer {
        _disableInitializers();
    }

    /// @notice Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs
    function init(
        address _registry,
        address _deviceWalletOwner,
        string calldata _deviceUniqueIdentifier
    ) external initializer {
        require(_registry != address(0), "Registry contract cannot be zero address");
        require(_deviceWalletOwner != address(0), "eSIM wallet owner cannot be zero address");
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be zero");

        registry = Registry(_registry);
        deviceUniqueIdentifier = _deviceUniqueIdentifier;
        
        initialize(_deviceWalletOwner);
    }

    /// @notice Allow device wallet owner to deploy new eSIM wallet
    /// @param _hasAccessToETH Set to true if the eSIM wallet is allowed to pull ETH from this wallet.
    /// @return eSIM wallet address
    function deployESIMWallet(
        bool _hasAccessToETH
    ) external onlyOwner returns (address) {
        ESIMWalletFactory eSIMWalletFactory = registry.eSIMWalletFactory();
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(msg.sender);

        _updateESIMInfo(eSIMWalletAddress, true, _hasAccessToETH);
        _updateDeviceWalletAssociatedWithESIMWallet(eSIMWalletAddress, address(this));
        emit ESIMWalletDeployed(eSIMWalletAddress, _hasAccessToETH);

        return eSIMWalletAddress;
    }

    /// @notice Allow wallet owner or admin to set unique identifier for their eSIM wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet smart contract
    /// @param _eSIMUniqueIdentifier String unique identifier for the eSIM wallet
    function setESIMUniqueIdentifierForAnESIMWallet(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) public onlyESIMWalletAdmin returns (string memory) {
        require(
            registry.isESIMWalletValid(_eSIMWalletAddress) != address(0),
            "Unknown eSIM wallet address provided"
        );
        require(
            uniqueIdentifierToESIMWallet[_eSIMUniqueIdentifier] == address(0),
            "eSIM unique identifier already set for the provided eSIM wallet"
        );

        ESIMWallet eSIMWallet = ESIMWallet(payable(_eSIMWalletAddress));
        eSIMWallet.setESIMUniqueIdentifier(_eSIMUniqueIdentifier);

        return eSIMWallet.eSIMUniqueIdentifier();
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pay ETH for data bundles
    /// @dev Instead of pulling the ETH into the eSIM wallet and then sending to the vault,
    ///      the eSIM wallet can directly request the device wallet to pay ETH for the data bundles
    /// @param _amount Amount of ETH to pull
    function payETHForDataBundles(uint256 _amount) external onlyAssociatedESIMWallets returns (uint256) {
        require(_amount > 0, "Amount cannot be zero");
        require(canPullETH[msg.sender] == true, "Cannot pull ETH. Access has been revoked");

        address vault = getVaultAddress();
        _transferETH(vault, _amount);

        emit ETHPaidForDataBundle(vault, msg.sender, _amount);

        return _amount;
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pull ETH (for data bundles)
    /// @param _amount Amount of ETH to pull
    function pullETH(uint256 _amount) external onlyAssociatedESIMWallets returns (uint256) {
        require(_amount > 0, "Amount cannot be zero");
        require(canPullETH[msg.sender] == true, "Cannot pull ETH. Access has been revoked");

        _transferETH(msg.sender, _amount);

        return _amount;
    }

    /// @notice Fetches the vault address (that receives payment for data bundles) from the device wallet factory
    /// @dev Mostly used by the associated eSIM wallets for reference
    function getVaultAddress() public view returns (address) {
        return registry.vault();
    }

    /// @notice Allow owner to revoke or give access to any associated eSIM wallet for pulling ETH
    /// @param _eSIMWalletAddress Address of the eSIM wallet to toggle ETH access for
    /// @param _hasAccessToETH Set to true to give access, false to revoke access
    function toggleAccessToETH(address _eSIMWalletAddress, bool _hasAccessToETH) external onlyOwner {
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
            else emit ETHSent(_recipient, _amount);
        }
    }

    function updateESIMInfo(
        address _eSIMWalletAddress,
        bool _isESIMWalletValid,
        bool _hasAccessToETH
    ) external onlyRegistryOrDeviceWalletFactoryOrOwner {
        _updateESIMInfo(_eSIMWalletAddress, _isESIMWalletValid, _hasAccessToETH);
    }

    function _updateESIMInfo(
        address _eSIMWalletAddress,
        bool _isESIMWalletValid,
        bool _hasAccessToETH
    ) internal {
        isValidESIMWallet[_eSIMWalletAddress] = _isESIMWalletValid;
        canPullETH[_eSIMWalletAddress] = _hasAccessToETH;
    }

    function updateDeviceWalletAssociatedWithESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) external onlyDeviceWalletFactoryOrOwner {
        require(_deviceWalletAddress != address(this), "Cannot update device wallet to same address");
        _updateDeviceWalletAssociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);
        isValidESIMWallet[_eSIMWalletAddress] = false;
    }

    function _updateDeviceWalletAssociatedWithESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) internal {
        registry.updateDeviceWalletAssociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);
    }

    // receive function already exists in the Account4337.sol
    // receive() external payable {
    //     receive ETH
    // }
}
