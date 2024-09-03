pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Registry} from "./Registry.sol";
import "./CustomStructs.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable{

    /// @notice Emitted when data related to a device is updated
    event DataUpdatedForDevice(
        string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, DataBundleDetails[] _dataBundleDetails
    );

    event LazyWalletDeployed(
        address _deviceOwner,
        address deviceWallet,
        string _deviceUniqueIdentifier,
        address[] eSIMWallets,
        string[] _eSIMUniqueIdentifiers
    );

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice Device identifier <> eSIM identifier <> ESIMDetails(purchase history)
    mapping(string => mapping(string => ESIMDetails)) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device identifier can have multiple associated eSIM identifiers.
    /// But an eSIM identifier can have only a single device identifier.
    mapping(string => string) public eSIMIdentifierToDeviceIdentifier;

    /// @notice Device identifier <> List of associated eSIM identifiers
    mapping(string => AssociatedESIMIdentifiers) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

    modifier onlyESIMWalletAdmin() {
        require(msg.sender == registry.admin(), "Only eSIM wallet admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    function initialize(
        address _registry,
        address _upgradeManager
    ) external initializer {
        require(_registry != address(0), "Registry contract address cannot be zero");
        require(_upgradeManager != address(0), "Upgrade Manager address cannot be zero address");
        
        registry = Registry(_registry);
        upgradeManager = _upgradeManager;

        __Ownable_init(_upgradeManager);
    }

    /// @notice Function to check if a lazy wallet has been deployed or not
    /// @return Boolean. True if deployed, false otherwise
    function isLazyWalletDeployed(string calldata _deviceUniqueIdentifier) public returns (bool) {
        if(registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier) != address(0)) {
            return true;
        }

        return false;
    }

    /// @notice Function to populate all the device and eSIM related data along with the data bundles
    /// @param _deviceUniqueIdentifiers List of device unique identifiers associated with the eSIM related data
    /// @param _eSIMUniqueIdentifiers 2D array of all the eSIMs corresponding to their device identifiers.
    /// @param _dataBundleDetails 2D array of all the new data bundles bought for the respective eSIMs
    function batchPopulateHistory(
        string[] memory _deviceUniqueIdentifiers,
        string[][] calldata _eSIMUniqueIdentifiers,
        DataBundleDetails[][] calldata _dataBundleDetails
    ) external {
        uint256 len = _deviceUniqueIdentifiers.length;
        require(len == _eSIMUniqueIdentifiers.length, "Unequal array provided");
        require(len == _dataBundleDetails.length, "Unequal array provided");

        for(uint256 i=0; i<len; ++i) {
            _populateHistory(_deviceUniqueIdentifiers[i], _eSIMUniqueIdentifiers[i], _dataBundleDetails[i]);
        }
    }

    /// @notice Function to deploy a device wallet and eSIM wallets on behalf of a user, also setting the eSIM identifiers
    /// @dev _salt should never be near to max value of uint256, if it is, the function call fails
    /// @param _deviceOwner Address of the device owner
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and list of eSIM wallet addresses
    function deployLazyWalletAndSetESIMIdentifier(
        address _deviceOwner,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt
    ) external onlyESIMWalletAdmin returns (address, address[] memory) {
        require(isLazyWalletDeployed(_deviceUniqueIdentifier) == false, "Device identifier is already associated with a device wallet");

        address deviceWallet;
        address[] memory eSIMWallets;

        AssociatedESIMIdentifiers memory associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        string[] memory eSIMUniqueIdentifiers = associatedESIMIdentifiers.eSIMIdentifiers;

        DataBundleDetails[][] memory listOfDataBundleDetails;

        for(uint256 i=0; i<eSIMUniqueIdentifiers.length; ++i) {
            ESIMDetails memory eSIMDetails = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifiers[i]];
            DataBundleDetails[] memory dataBundleDetails = eSIMDetails.history;
            listOfDataBundleDetails[i] = dataBundleDetails;
        }

        (deviceWallet, eSIMWallets) = registry.deployLazyWallet(
            _deviceOwner,
            _deviceUniqueIdentifier,
            _salt,
            eSIMUniqueIdentifiers,
            listOfDataBundleDetails
        );

        emit LazyWalletDeployed(
            _deviceOwner,
            deviceWallet,
            _deviceUniqueIdentifier,
            eSIMWallets,
            eSIMUniqueIdentifiers
        );

        return (deviceWallet, eSIMWallets);
    }

    /// @notice Internal function for populating information of all the eSIMs related to a device
    /// @dev The _eSIMUniqueIdentifiers array can have multiple repeating occurrences since there can be multiple purchases per eSIM
    function _populateHistory(
        string storage _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers,
        DataBundleDetails[] calldata _dataBundleDetails
    ) internal {
        require(bytes(_deviceUniqueIdentifier).length >= 1, "Device unique identifier cannot be empty");
        require(isLazyWalletDeployed(_deviceUniqueIdentifier) == false, "Device identifier is already associated with a device wallet");
        
        uint256 len = _eSIMUniqueIdentifiers.length;
        require(len == _dataBundleDetails.length, "Unequal array provided");

        for(uint256 i=0; i<len; ++i) {
            string calldata eSIMUniqueIdentifier = _eSIMUniqueIdentifiers[i];
            require(bytes(eSIMUniqueIdentifier).length >= 1, "eSIM unique identifier cannot be empty");

            string storage deviceIdentifier = eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier];

            if(bytes(deviceIdentifier).length == 0) {
                deviceIdentifier = _deviceUniqueIdentifier;

                AssociatedESIMIdentifiers storage associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
                associatedESIMIdentifiers.eSIMIdentifiers.push(eSIMUniqueIdentifier);
            }

            ESIMDetails storage eSIMDetails = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifier];
            eSIMDetails.history.push(_dataBundleDetails[i]);
        }

        emit DataUpdatedForDevice(_deviceUniqueIdentifier, _eSIMUniqueIdentifiers, _dataBundleDetails);
    }
}
