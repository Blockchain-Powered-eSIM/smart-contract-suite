pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {RegistryHelper} from "./RegistryHelper.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";

import "account-abstraction/contracts/interfaces/IEntryPoint.sol";

error OnlyDeviceWallet();
error OnlyDeviceWalletFactory();

/// @notice Contract for deploying the factory contracts and maintaining registry
contract Registry is Initializable, UUPSUpgradeable, OwnableUpgradeable, RegistryHelper {

    /// @notice Entry point contract address (one entryPoint per chain)
    IEntryPoint public immutable entryPoint;

    ///@notice eSIM wallet project admin address
    address public admin;

    /// @notice Address of the vault that receives payments for the eSIM data bundles
    address public vault;

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    modifier onlyDeviceWallet() {
        if(isDeviceWalletValid[msg.sender] == address(0)) revert OnlyDeviceWallet();
        _;
    }

    modifier onlyDeviceWalletFactory() {
        if(msg.sender != address(deviceWalletFactory)) revert OnlyDeviceWalletFactory();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IEntryPoint _entryPoint) initializer {
        entryPoint = _entryPoint;
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize(address _eSIMWalletAdmin, address _vault, address _upgradeManager) external initializer {
        require(_eSIMWalletAdmin != address(0), "eSIM Admin address cannot be zero address");
        require(_vault != address(0), "Vault address cannot be zero address");
        require(_upgradeManager != address(0), "Upgrade Manager address cannot be zero address");

        admin = _eSIMWalletAdmin;
        vault = _vault;
        upgradeManager = _upgradeManager;

        address deviceWalletFactoryImplementation = address(new DeviceWalletFactory(entryPoint));
        ERC1967Proxy deviceWalletFactoryProxy = new ERC1967Proxy(
            deviceWalletFactoryImplementation,
            abi.encodeCall(
                DeviceWalletFactory(deviceWalletFactoryImplementation).initialize,
                (address(this), _eSIMWalletAdmin, _vault, _upgradeManager)
            )
        );
        deviceWalletFactory = DeviceWalletFactory(address(deviceWalletFactoryProxy));

        address eSIMWalletFactoryImplementation = address(new ESIMWalletFactory());
        ERC1967Proxy eSIMWalletFactoryProxy = new ERC1967Proxy(
            eSIMWalletFactoryImplementation,
            abi.encodeCall(
                ESIMWalletFactory(eSIMWalletFactoryImplementation).initialize,
                (address(this), _upgradeManager)
            )
        );

        eSIMWalletFactory = ESIMWalletFactory(address(eSIMWalletFactoryProxy));

        __Ownable_init(_upgradeManager);
    }

    /// @notice Function to add or update the lazy wallet registry address
    function addOrUpdateLazyWalletRegistryAddress(
        address _lazyWalletRegistry
    ) public onlyOwner returns (address) {
        require(_lazyWalletRegistry != address(0), "Cannot be zero address");

        lazyWalletRegistry = _lazyWalletRegistry;

        emit UpdatedLazyWalletRegistryAddress(_lazyWalletRegistry);

        return lazyWalletRegistry;
    }

    /// Allow anyone to deploy a device wallet and an eSIM wallet for themselves
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and eSIM wallet address
    function deployWallet(
        string calldata _deviceUniqueIdentifier,
        uint256 _salt
    ) external returns (address, address) {
        require(bytes(_deviceUniqueIdentifier).length >= 1, "Device unique identifier cannot be empty");
        require(ownerToDeviceWallet[msg.sender] == address(0), "User is already an owner of a device wallet");
        require(
            uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] == address(0),
            "Device wallet already exists"
        );

        address deviceWallet = deviceWalletFactory.deployDeviceWallet(_deviceUniqueIdentifier, msg.sender, _salt);
        _updateDeviceWalletInfo(deviceWallet, _deviceUniqueIdentifier, msg.sender);

        address eSIMWallet = eSIMWalletFactory.deployESIMWallet(msg.sender, _salt);
        _updateESIMInfo(eSIMWallet, deviceWallet);

        emit WalletDeployed(_deviceUniqueIdentifier, deviceWallet, eSIMWallet);

        return (deviceWallet, eSIMWallet);
    }

    function updateDeviceWalletAssociatedWithESIMWallet(
        address _eSIMWalletAddress,
        address _deviceWalletAddress
    ) external onlyDeviceWallet {
        isESIMWalletValid[_eSIMWalletAddress] = _deviceWalletAddress;
        emit UpdatedDeviceWalletassociatedWithESIMWallet(_eSIMWalletAddress, _deviceWalletAddress);
    }

    /// @dev For all the device wallets deployed by the esim wallet admin using the device wallet factory,
    ///      update the mappings
    /// @param _deviceWallet Address of the device wallet
    /// @param _deviceUniqueIdentifier String unique identifier associated with the device wallet
    function updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        address _deviceWalletOwner
    ) external onlyDeviceWalletFactory {
        _updateDeviceWalletInfo(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwner);
    }
}
