pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeviceWalletFactory} from "./device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "./esim-wallet/ESIMWalletFactory.sol";
import {DeviceWallet} from "./device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "./esim-wallet/ESIMWallet.sol";
import {P256Verifier} from "./P256Verifier.sol";
import "./CustomStructs.sol";

error OnlyLazyWalletRegistry();

contract RegistryHelper {

    event WalletDeployed(
        string _deviceUniqueIdentifier,
        address indexed _deviceWallet,
        address indexed _eSIMWallet
    );

    event DeviceWalletInfoUpdated(
        address indexed _deviceWallet,
        string _deviceUniqueIdentifier,
        bytes32[2] _deviceWalletOwnerKey
    );

    event UpdatedDeviceWalletassociatedWithESIMWallet(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress
    );

    event UpdatedLazyWalletRegistryAddress(
        address indexed _lazyWalletRegistry
    );

    event RegistryInitialized(
        address _eSIMWalletAdmin, 
        address _vault, 
        address indexed _upgradeManager, 
        address indexed _deviceWalletFactory, 
        address indexed _eSIMWalletFactory,
        address _verifier
    );

    event ESIMWalletSetOnStandby(
        address indexed _eSIMWalletAddress,
        bool _isOnStandby,
        address indexed _deviceWalletAddress
    );

    /// @notice Address of the Lazy wallet registry
    address public lazyWalletRegistry;

    /// @notice Device wallet factory instance
    DeviceWalletFactory public deviceWalletFactory;

    /// @notice eSIM wallet factory instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice device unique identifier <> device wallet address
    ///         Mapping for all the device wallets deployed by the registry
    /// @dev Use this to check if a device identifier has already been used or not
    mapping(string => address) public uniqueIdentifierToDeviceWallet;

    /// @notice device wallet address <> owner P256 public key.
    mapping(address => bytes32[2]) public deviceWalletToOwner;

    /// @notice device wallet address <> boolean (true if deployed by the registry or device wallet factory)
    ///         Mapping of all the device wallets deployed by the registry (or the device wallet factory)
    ///         to their respective owner.
    mapping(address => bool) public isDeviceWalletValid;

    /// @notice eSIM wallet address <> device wallet address
    ///         All the eSIM wallets deployed using this registry are valid and set to true
    mapping(address => address) public isESIMWalletValid;

    /// @notice If an existing eSIM wallet is in the process of being transferred from one device wallet to another
    ///         If bool is `true`, it means that the eSIM wallet has no device wallet associated to it yet
    mapping(address => bool) public isESIMWalletOnStandby;

    modifier onlyLazyWalletRegistry() {
        if(msg.sender != lazyWalletRegistry) revert OnlyLazyWalletRegistry();
        _;
    }

    /// @notice Allow LazyWalletRegistry to deploy a device wallet and an eSIM wallet on behalf of a user
    /// @param _deviceWalletOwnerKey P256 public key of user
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and list of addresses of all the eSIM wallets
    function deployLazyWallet(
        bytes32[2] memory _deviceWalletOwnerKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        string[] memory _eSIMUniqueIdentifiers,
        DataBundleDetails[][] memory _dataBundleDetails
    ) external onlyLazyWalletRegistry returns (address, address[] memory) {
        require(_eSIMUniqueIdentifiers.length + _salt < type(uint256).max, "Salt value too high");
        require(
            uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] == address(0),
            "Device wallet already exists"
        );

        // Deploys device smart wallet
        // Updates device wallet info via Registry
        address deviceWallet = address(deviceWalletFactory.createAccount(_deviceUniqueIdentifier, _deviceWalletOwnerKey, _salt));

        address[] memory eSIMWallets;

        for(uint256 i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
            // increase salt for subsequent eSIM wallet deployments
            address eSIMWallet = eSIMWalletFactory.deployESIMWallet(deviceWallet, (_salt + i));
            emit WalletDeployed(_deviceUniqueIdentifier, deviceWallet, eSIMWallet);

            // Updates the Device wallet storage variables as well as for the registry
            DeviceWallet(payable(deviceWallet)).addESIMWallet(eSIMWallet, deviceWallet, true);

            // Since the eSIM unique identifier is already known in this scenario
            // We can execute the setESIMUniqueIdentifierForAnESIMWallet function in same transaction as deploying the smart wallet
            DeviceWallet(payable(deviceWallet)).setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, _eSIMUniqueIdentifiers[i]);

            // Populate data bundle purchase details for the eSIM wallet
            ESIMWallet(payable(eSIMWallet)).populateHistory(_dataBundleDetails[i]);

            eSIMWallets[i] = eSIMWallet;
        }

        return (deviceWallet, eSIMWallets);
    }

    function _updateDeviceWalletInfo(
        address _deviceWallet,
        string calldata _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) internal {
        uniqueIdentifierToDeviceWallet[_deviceUniqueIdentifier] = _deviceWallet;
        isDeviceWalletValid[_deviceWallet] = true;
        deviceWalletToOwner[_deviceWallet] = _deviceWalletOwnerKey;

        emit DeviceWalletInfoUpdated(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    /// @dev Internal function to deploy Device wallet factory during Registry initialisation
    function _deployDeviceWalletFactory(
        IEntryPoint entryPoint,
        P256Verifier _verifier,
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager
    ) internal {
        address deviceWalletFactoryImplementation = address(new DeviceWalletFactory(entryPoint, _verifier));
        ERC1967Proxy deviceWalletFactoryProxy = new ERC1967Proxy(
            deviceWalletFactoryImplementation,
            abi.encodeCall(
                DeviceWalletFactory(deviceWalletFactoryImplementation).initialize,
                (address(this), _eSIMWalletAdmin, _vault, _upgradeManager)
            )
        );
        deviceWalletFactory = DeviceWalletFactory(address(deviceWalletFactoryProxy));
    }

    /// @dev Internal function to deploy eSIM wallet factory during Registry initialisation
    function _deployESIMWalletFactory(
        address _upgradeManager
    ) internal {
        address eSIMWalletFactoryImplementation = address(new ESIMWalletFactory());
        ERC1967Proxy eSIMWalletFactoryProxy = new ERC1967Proxy(
            eSIMWalletFactoryImplementation,
            abi.encodeCall(
                ESIMWalletFactory(eSIMWalletFactoryImplementation).initialize,
                (address(this), _upgradeManager)
            )
        );
        eSIMWalletFactory = ESIMWalletFactory(address(eSIMWalletFactoryProxy));
    }
}
