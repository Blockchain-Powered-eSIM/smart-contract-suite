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
        bytes32[2] _deviceOwnerPublicKey,
        address deviceWallet,
        string _deviceUniqueIdentifier,
        address[] eSIMWallets,
        string[] _eSIMUniqueIdentifiers
    );

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice Device identifier <> eSIM identifier <> DataBundleDetails[](list of purchase history)
    mapping(string => mapping(string => DataBundleDetails[])) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device identifier can have multiple associated eSIM identifiers.
    /// But an eSIM identifier can have only a single device identifier.
    mapping(string => string) public eSIMIdentifierToDeviceIdentifier;

    /// @notice Device identifier <> List of associated eSIM identifiers
    mapping(string => string[]) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

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
    function isLazyWalletDeployed(string calldata _deviceUniqueIdentifier) public view returns (bool) {
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
        string[] calldata _deviceUniqueIdentifiers,
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
    /// @param _deviceOwnerPublicKey P256 public key of the device owner
    /// @param _deviceUniqueIdentifier Unique device identifier associated with the device
    /// @return Return device wallet address and list of eSIM wallet addresses
    function deployLazyWalletAndSetESIMIdentifier(
        bytes32[2] memory _deviceOwnerPublicKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt
    ) external onlyESIMWalletAdmin returns (address, address[] memory) {
        require(isLazyWalletDeployed(_deviceUniqueIdentifier) == false, "Device identifier is already associated with a device wallet");

        address deviceWallet;
        address[] memory eSIMWallets;

        string[] memory eSIMUniqueIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];

        DataBundleDetails[][] memory listOfDataBundleDetails;

        for(uint256 i=0; i<eSIMUniqueIdentifiers.length; ++i) {
            listOfDataBundleDetails[i] = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifiers[i]];
        }

        (deviceWallet, eSIMWallets) = registry.deployLazyWallet(
            _deviceOwnerPublicKey,
            _deviceUniqueIdentifier,
            _salt,
            eSIMUniqueIdentifiers,
            listOfDataBundleDetails
        );

        emit LazyWalletDeployed(
            _deviceOwnerPublicKey,
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
        string calldata _deviceUniqueIdentifier,
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

            if(bytes(eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier]).length == 0) {
                eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier] = _deviceUniqueIdentifier;

                string[] storage associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
                associatedESIMIdentifiers.push(eSIMUniqueIdentifier);
            }

            DataBundleDetails[] storage dataBundleDetails = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifier];
            // Manually add a new struct to history and then set its fields
            dataBundleDetails.push();  // Increase the array length by one
            DataBundleDetails storage newDataBundleDetail = dataBundleDetails[dataBundleDetails.length - 1];
            newDataBundleDetail.dataBundleID = _dataBundleDetails[i].dataBundleID;
            newDataBundleDetail.dataBundlePrice = _dataBundleDetails[i].dataBundlePrice;
        }

        emit DataUpdatedForDevice(_deviceUniqueIdentifier, _eSIMUniqueIdentifiers, _dataBundleDetails);
    }
}
