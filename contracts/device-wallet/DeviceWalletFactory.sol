pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {DeviceWallet} from "./DeviceWallet.sol";
import {UpgradeableBeacon} from "../UpgradableBeacon.sol";

error OnlyAdmin();

/// @notice Contract for deploying a new eSIM wallet
contract DeviceWalletFactory {
    /// @notice Emitted when the admin sets the eSIM wallet factory address
    event SetESIMWalletFactoryAddress(address indexed _eSIMWalletFactoryAddress);

    /// @notice Emitted when factory is deployed and admin is set
    event DeviceWalletFactoryDeployed(
        address indexed _factoryAddress,
        address _admin,
        address _vault,
        address _upgradeManager,
        address indexed _deviceWalletImplementation,
        address indexed _beacon
    );

    /// @notice Emitted when the Vault address is updated
    event VaultAddressUpdated(address indexed _updatedVaultAddress);

    /// @notice Emitted when a new device wallet is deployed
    event DeviceWalletDeployed(address indexed _deviceWalletAddress, string[] indexed _eSIMUniqueIdentifiers);

    /// @notice Emitted when the admin address is updated
    event AdminUpdated(address indexed _newAdmin);

    /// @notice Admin address of the eSIM wallet project
    address public eSIMWalletAdmin;

    /// @notice Vault address that receives payments for eSIM data bundles
    address public vault;

    /// @notice Implementation (logic) contract address of the device wallet
    address public deviceWalletImplementation;

    /// @notice Beacon contract address for this contract
    address public beacon;

    /// @notice eSIM wallet factory contract address;
    address public eSIMWalletFactoryAddress;

    /// @notice deviceUniqueIdentifier <> deviceWalletAddress
    mapping(string => address) public walletAddressOfDeviceUniqueIdentifier;

    /// @notice Set to true if device wallet was deployed by the device wallet factory, false otherwise.
    mapping(address => bool) public isDeviceWalletValid;

    modifier onlyAdmin() {
        if (msg.sender != eSIMWalletAdmin) revert OnlyAdmin();
        _;
    }

    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    constructor(address _eSIMWalletAdmin, address _vault, address _upgradeManager) {
        require(_eSIMWalletAdmin != address(0), "Admin cannot be zero address");
        require(_vault != address(0), "Vault address cannot be zero");
        require(_upgradeManager != address(0), "Upgrade manager address cannot be zero");

        eSIMWalletAdmin = _eSIMWalletAdmin;
        vault = _vault;

        // device wallet implementation (logic) contract
        deviceWalletImplementation = address(new DeviceWallet());
        // Upgradable beacon for device wallet implementation contract
        beacon = address(new UpgradeableBeacon(deviceWalletImplementation, _upgradeManager));

        emit DeviceWalletFactoryDeployed(
            address(this), _eSIMWalletAdmin, _vault, _upgradeManager, deviceWalletImplementation, beacon
        );
    }

    /// @notice Function to update vault address.
    /// @dev Can only be called by the admin
    /// @param _newVaultAddress New vault address
    function updateVaultAddress(address _newVaultAddress) public onlyAdmin returns (address) {
        require(vault != _newVaultAddress, "Cannot update to same address");
        require(_newVaultAddress != address(0), "Vault address cannot be zero");

        vault = _newVaultAddress;
        emit VaultAddressUpdated(vault);

        return vault;
    }

    /// @notice Function to update admin address
    /// @param _newAdmin New admin address
    function updateAdmin(address _newAdmin) public onlyAdmin returns (address) {
        require(eSIMWalletAdmin != _newAdmin, "Cannot update to same address");
        require(_newAdmin != address(0), "Admin address cannot be zero");

        eSIMWalletAdmin = _newAdmin;
        emit AdminUpdated(eSIMWalletAdmin);

        return eSIMWalletAdmin;
    }

    function setESIMWalletFactoryAddress(address _eSIMWalletFactoryAddress) public onlyAdmin returns (address) {
        require(_eSIMWalletFactoryAddress != address(0), "Factory address cannot be zero");

        eSIMWalletFactoryAddress = _eSIMWalletFactoryAddress;
        emit SetESIMWalletFactoryAddress(eSIMWalletFactoryAddress);

        return eSIMWalletFactoryAddress;
    }

    /// @notice To deploy multiple device wallets at once
    /// @param _deviceUniqueIdentifiers Array of unique device identifiers for each device wallet
    /// @param _dataBundleIDs 2D array of IDs of data bundles to be bought for respective eSIMs
    /// @param _dataBundlePrices 2D array of price of respective data bundles for respective eSIMs
    /// @param _eSIMUniqueIdentifiers 2D array of unique eSIM identifiers for each device wallet
    /// @return Array of deployed device wallet address
    function deployMultipleDeviceWalletsWithESIMWallets(
        string[] calldata _deviceUniqueIdentifiers,
        string[][] calldata _dataBundleIDs,
        uint256[][] calldata _dataBundlePrices,
        string[][] calldata _eSIMUniqueIdentifiers
    ) public payable returns (address[] memory) {
        uint256 numberOfDeviceWallets = _deviceUniqueIdentifiers.length;
        require(numberOfDeviceWallets != 0, "Array cannot be empty");
        require(numberOfDeviceWallets == _eSIMUniqueIdentifiers.length, "Array mismatch");

        address[] memory deviceWalletsDeployed = new address[](numberOfDeviceWallets);

        for (uint256 i = 0; i < numberOfDeviceWallets; ++i) {
            deviceWalletsDeployed[i] = deployDeviceWalletWithESIMWallets(
                _deviceUniqueIdentifiers[i],
                _dataBundleIDs[i],
                _dataBundlePrices[i],
                _eSIMUniqueIdentifiers[i],
                msg.sender
            );
        }

        return deviceWalletsDeployed;
    }

    /// @dev To deploy a device wallet and eSIM wallets for given unique eSIM identifiers
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _dataBundleIDs List of IDs of data bundles to be bought for respective eSIMs
    /// @param _dataBundlePrices List of price of respective data bundles
    /// @param _eSIMUniqueIdentifiers Array of unique eSIM identifiers for the device wallet
    /// @param _deviceWalletOwner User's address (owner of the device wallet and respective eSIM wallets)
    /// @return Deployed device wallet address
    function deployDeviceWalletWithESIMWallets(
        string calldata _deviceUniqueIdentifier,
        string[] calldata _dataBundleIDs,
        uint256[] calldata _dataBundlePrices,
        string[] calldata _eSIMUniqueIdentifiers,
        address _deviceWalletOwner
    ) public payable returns (address) {
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device unique identifier cannot be empty");
        require(eSIMWalletFactoryAddress != address(0), "eSIM wallet factory address not set or contract not deployed");

        require(
            walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifier] == address(0), "Device wallet already exists"
        );

        // msg.value will be sent along with the abi.encodeCall
        address deviceWalletAddress = address(
            new BeaconProxy(
                beacon,
                abi.encodeCall(
                    DeviceWallet(payable(deviceWalletImplementation)).init,
                    (
                        DeviceWallet.InitParams(
                            address(this),
                            eSIMWalletFactoryAddress,
                            _deviceWalletOwner,
                            _deviceUniqueIdentifier,
                            _dataBundleIDs,
                            _dataBundlePrices,
                            _eSIMUniqueIdentifiers
                        )
                    )
                )
            )
        );
        isDeviceWalletValid[deviceWalletAddress] = true;
        walletAddressOfDeviceUniqueIdentifier[_deviceUniqueIdentifier] = deviceWalletAddress;

        emit DeviceWalletDeployed(deviceWalletAddress, _eSIMUniqueIdentifiers);

        return deviceWalletAddress;
    }
}
