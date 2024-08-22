pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Registry} from "./Registry.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, RegistryHelper {

    /// @notice Emitted when data related to a device is updated
    event DataUpdatedForDevice(
        string _deviceUniqueIdentifier, string[] _eSIMUniqueIdentifiers, DataBundleDetail[] _dataBundleDetails
    );

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice Data Bundle related details stored in the eSIM wallet
    struct DataBundleDetail {
        string dataBundleID;
        uint256 dataBundlePrice;
    }

    /// @notice Details related to eSIM purchased by the fiat user
    struct ESIMDetails {
        DataBundleDetail[] history;
    }

    /// @notice Struct to store list of all eSIMs associated with a device
    struct AssociatedESIMIdentifiers {
        string[] eSIMIdentifiers;
    }

    /// @notice Device identifier <> eSIM identifier <> ESIMDetails(purchase history)
    mapping(string => mapping(string => ESIMDetails)) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device identifier can have multiple associated eSIM identifiers.
    /// But an eSIM identifier can have only a single device identifier.
    mapping(string => string) public eSIMIdentifierToDeviceIdentifier;

    /// @notice Device identifier <> List of associated eSIM identifiers
    mapping(string => AssociatedESIMIdentifiers) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

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

    /// @notice Function to populate all the device and eSIM related data along with the data bundles
    /// @param _deviceUniqueIdentifiers List of device unique identifiers associated with the eSIM related data
    /// @param _eSIMUniqueIdentifiers 2D array of all the eSIMs corresponding to their device identifiers.
    /// @param _dataBundleDetails 2D array of all the new data bundles bought for the respective eSIMs
    function batchPopulateHistory(
        string[] calldata _deviceUniqueIdentifiers,
        string[][] calldata _eSIMUniqueIdentifiers,
        DataBundleDetail[][] calldata _dataBundleDetails
    ) external {
        uint256 len = _deviceUniqueIdentifiers.length;
        require(len == _eSIMUniqueIdentifiers.length, "Unequal array provided");
        require(len == _dataBundleDetails.length, "Unequal array provided");

        for(uint256 i=0; i<len; ++i) {
            _populateHistory(_deviceUniqueIdentifiers[i], _eSIMUniqueIdentifiers[i], _dataBundleDetails[i]);
        }
    }

    /*
        TODO: 
        * Make changes in device wallet to add history
        * Make changes in eSIM wallet to add history and other important data
        * Look into eSIM state and if possible create 
        an architecture standard for eSIM profile,
    */
    /// @notice Internal function for populating information of all the eSIMs related to a device
    /// @dev The _eSIMUniqueIdentifiers array can have multiple repeating occurrences since there can be multiple purchases per eSIM
    function _populateHistory(
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers,
        DataBundleDetail[] calldata _dataBundleDetails
    ) internal {
        require(registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier) == address(0), "Device identifier is already associated with a device wallet");
        
        uint256 len = _eSIMUniqueIdentifiers.length;
        require(len == _dataBundleDetails.length, "Unequal array provided");

        for(uint256 i=0; i<len; ++i) {
            string eSIMUniqueIdentifier = _eSIMUniqueIdentifiers[i];

            if(eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier].length == 0) {
                eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier] = _deviceUniqueIdentifier;

                AssociatedESIMIdentifiers storage associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
                string[] storage listOfIdentifiers = associatedESIMIdentifiers.eSIMIdentifiers;
                listOfIdentifiers.push(eSIMUniqueIdentifier);
                associatedESIMIdentifiers.eSIMIdentifiers = listOfIdentifiers;
            }

            ESIMDetails storage eSIMDetails = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifier];
            DataBundleDetail[] storage details = eSIMDetails.history;
            details.push(_dataBundleDetails[i]);
            eSIMDetails.history = details;
        }

        emit DataUpdatedForDevice(_deviceUniqueIdentifier, _eSIMUniqueIdentifiers, _dataBundleDetails);
    }
}
