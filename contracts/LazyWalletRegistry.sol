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

    /// @notice Emitted when an eSIM identifier is associated with a device identifier
    event ESIMBindedWithDevice(string _eSIMUniqueIdentifier, string _deviceUniqueIdentifier);

    /// @notice Emitted when the Lazy wallet is deployed
    event LazyWalletDeployed(
        bytes32[2] _deviceOwnerPublicKey,
        address deviceWallet,
        string _deviceUniqueIdentifier,
        address[] eSIMWallets,
        string[] _eSIMUniqueIdentifiers
    );

    /// @notice Emitted when the user switches eSIM to a new device
    event ESIMIdentifierSwitchedToNewDeviceIdentifier(
        string _eSIMIdentifier,
        string _oldDeviceIdentifier,
        string currentDeviceIdentifier
    );

    /// @notice Emitted when the device identifier associated with an eSIM identifier is updated
    event NewDeviceIdentifierAssociatedWithESIMIdentifier(
        string _eSIMIdentifier,
        string _oldDeviceIdentifier,
        string _newDeviceIdentifier);

    /// @notice Emitted when the Data bundle related details of an eSIM are transferred to a new device identifier
    event DataBundleDetailsTransferredToNewDeviceIdentifier(
        string _newDeviceIdentifier,
        DataBundleDetails[] _newDataBundleDetails
    );

    /// @notice Emitted when teh Data bundle related details are deleted from the old device identifer
    event DataBundleDetailsDeletedFromOldDeviceIdentifier(
        string _oldDeviceIdentifier,
        string _eSIMIdentifier
    );

    /// @notice Emitted when an eSIM identifier is removed from a device identifier's list
    event ESIMIdentifierRemovedFromOldDeviceIdentifier(
        string _oldDeviceIdentifier, 
        string _eSIMIdentifier, 
        string[] _eSIMIdentifierOfOldDevice
    );

    /// @notice Emitted when an eSIM identifier is added to a new device identifier's list
    event ESIMIdentifierAddedToNewDeviceIdentifier(
        string _newDeviceIdentifier,
        string _eSIMIdentifier,
        string[] _eSIMIdentifierOfNewDevice
    );

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM identifiers and their details associated with the device identifiers
    mapping(string deviceIdentifier => mapping(string eSIMIdentifier => DataBundleDetails[] dataBundleDetails)) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device identifier can have multiple associated eSIM identifiers.
    /// But an eSIM identifier can have only a single device identifier.
    mapping(string eSIMIdentifier => string deviceIdentifier) public eSIMIdentifierToDeviceIdentifier;

    /// @notice List of eSIM identifiers associated with the device identifiers
    mapping(string deviceIdentifier => string[] associatedESIMIdentifiers) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

    modifier onlyESIMWalletAdmin() {
        require(msg.sender == registry.eSIMWalletAdmin(), "Only eSIM wallet admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

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
        require(_registry != address(0), "Registry 0");
        require(_upgradeManager != address(0), "Manager 0");
        
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
    ) external onlyESIMWalletAdmin {
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
    /// @param _depositAmount Amount of ETH to  be deposite in the device wallet
    /// @return Return device wallet address and list of eSIM wallet addresses
    function deployLazyWalletAndSetESIMIdentifier(
        bytes32[2] memory _deviceOwnerPublicKey,
        string calldata _deviceUniqueIdentifier,
        uint256 _salt,
        uint256 _depositAmount
    ) external payable onlyESIMWalletAdmin returns (address, address[] memory) {
        require(_depositAmount == msg.value, "Incorrect ETH");
        require(isLazyWalletDeployed(_deviceUniqueIdentifier) == false, "Already deployed");

        address deviceWallet;

        string[] memory eSIMUniqueIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        require(eSIMUniqueIdentifiers.length > 0, "No eSIM identifier found");

        address[] memory eSIMWallets = new address[](eSIMUniqueIdentifiers.length);
        DataBundleDetails[][] memory listOfDataBundleDetails = new DataBundleDetails[][](eSIMUniqueIdentifiers.length);

        for(uint256 i=0; i<eSIMUniqueIdentifiers.length; ++i) {
            listOfDataBundleDetails[i] = deviceIdentifierToESIMDetails[_deviceUniqueIdentifier][eSIMUniqueIdentifiers[i]];
        }

        (deviceWallet, eSIMWallets) = registry.deployLazyWallet{value: msg.value}(
            _deviceOwnerPublicKey,
            _deviceUniqueIdentifier,
            _salt,
            eSIMUniqueIdentifiers,
            listOfDataBundleDetails,
            _depositAmount
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
        require(bytes(_deviceUniqueIdentifier).length >= 1, "Device identifier 0");
        require(isLazyWalletDeployed(_deviceUniqueIdentifier) == false, "Already deployed");
        
        uint256 len = _eSIMUniqueIdentifiers.length;
        require(len == _dataBundleDetails.length, "Unequal array provided");

        for(uint256 i=0; i<len; ++i) {
            string calldata eSIMUniqueIdentifier = _eSIMUniqueIdentifiers[i];
            require(bytes(eSIMUniqueIdentifier).length >= 1, "eSIM identifier 0");

            string memory deviceUniqueIdentifier = eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier];

            if(bytes(deviceUniqueIdentifier).length == 0) {
                eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier] = _deviceUniqueIdentifier;

                string[] storage associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
                associatedESIMIdentifiers.push(eSIMUniqueIdentifier);

                emit ESIMBindedWithDevice(eSIMUniqueIdentifier, _deviceUniqueIdentifier);
            }
            else {
                require(keccak256(bytes(deviceUniqueIdentifier)) == keccak256(bytes(_deviceUniqueIdentifier)), "Invalid _deviceUniqueIdentifier");
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

    /// @notice This function should be called when the fiat user wants to switch their eSIM to a new device
    /// @param _eSIMIdentifier unique eSIM identifier that needs to be switched to a new device
    /// @param _oldDeviceIdentifier device identifier that the eSIM is currently associated with
    /// @param _newDeviceIdentifier new device identifier that the eSIM needs to be switched to
    /// @return bool Returns `true` if the switching of eSIM was successful
    function switchESIMIdentifierToNewDeviceIdentifier(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) external onlyESIMWalletAdmin returns (bool) {
        require(bytes( _eSIMIdentifier).length > 0, "_eSIMIdentifier 0");
        require(bytes( _newDeviceIdentifier).length > 0, "_newDeviceIdentifier 0");

        string memory currentDeviceIdentifier = eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier];
        require(bytes(currentDeviceIdentifier).length > 0, "Unknown _eSIMIdentifier");
        require(
            bytes(currentDeviceIdentifier).length == bytes(_oldDeviceIdentifier).length,
            "Incorrect device identifier"
        );
        require(
            keccak256(bytes(currentDeviceIdentifier)) == keccak256(bytes(_oldDeviceIdentifier)),
            "Incorrect device identifier"
        );
        require(
            keccak256(bytes(_newDeviceIdentifier)) != keccak256(bytes(currentDeviceIdentifier)),
            "Cannot switch to same device"
        );

        eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier] = _newDeviceIdentifier;
        emit NewDeviceIdentifierAssociatedWithESIMIdentifier(_eSIMIdentifier, currentDeviceIdentifier, _newDeviceIdentifier);

        _updateDeviceIdentifierToESIMDetails(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);
        _updateESIMIdentifiersAssociatedWithDeviceIdentifier(_eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier);

        emit ESIMIdentifierSwitchedToNewDeviceIdentifier(_eSIMIdentifier, _oldDeviceIdentifier, currentDeviceIdentifier);

        return true;
    }

    /// @dev Internal function to update the eSIM related details when switching to a new device identifier
    function _updateDeviceIdentifierToESIMDetails(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) internal {
        DataBundleDetails[] storage dataBundleDetails = deviceIdentifierToESIMDetails[_oldDeviceIdentifier][_eSIMIdentifier];
        // Transfer history of the eSIM identifier to the new device identifier
        DataBundleDetails[] storage newDataBundleDetails = deviceIdentifierToESIMDetails[_newDeviceIdentifier][_eSIMIdentifier];
        for(uint256 i=0; i<dataBundleDetails.length; ++i) {
            newDataBundleDetails.push(dataBundleDetails[i]);
        }
        emit DataBundleDetailsTransferredToNewDeviceIdentifier(_newDeviceIdentifier, newDataBundleDetails);

        // delete any reference of eSIM identifier from previous device identifier
        delete deviceIdentifierToESIMDetails[_oldDeviceIdentifier][_eSIMIdentifier];
        emit DataBundleDetailsDeletedFromOldDeviceIdentifier(_oldDeviceIdentifier, _eSIMIdentifier);
    }

    /// @dev Internal function to update the eSIM identifiers related to the device when switching
    function _updateESIMIdentifiersAssociatedWithDeviceIdentifier(
        string calldata _eSIMIdentifier,
        string calldata _oldDeviceIdentifier,
        string calldata _newDeviceIdentifier
    ) internal {
        // Remove eSIM identifier from previous device identifier
        string[] storage eSIMIdentifierOfOldDevice = eSIMIdentifiersAssociatedWithDeviceIdentifier[_oldDeviceIdentifier];

        uint256 i = 0;

        for(; i<eSIMIdentifierOfOldDevice.length; ++i) {
            if(
                keccak256(bytes(eSIMIdentifierOfOldDevice[i])) == keccak256(bytes(_eSIMIdentifier)) 
            ) {
                break;
            }
        }

        // Swap element to be removed with the element at the last index, and then pop last element
        eSIMIdentifierOfOldDevice[i] = eSIMIdentifierOfOldDevice[eSIMIdentifierOfOldDevice.length - 1];
        eSIMIdentifierOfOldDevice.pop();
        emit ESIMIdentifierRemovedFromOldDeviceIdentifier(_oldDeviceIdentifier, _eSIMIdentifier, eSIMIdentifierOfOldDevice);

        // Add eSIM identifier to new device identifier
        string[] storage eSIMIdentifierOfNewDevice = eSIMIdentifiersAssociatedWithDeviceIdentifier[_newDeviceIdentifier];
        eSIMIdentifierOfNewDevice.push(_eSIMIdentifier);
        emit ESIMIdentifierAddedToNewDeviceIdentifier(_newDeviceIdentifier, _eSIMIdentifier, eSIMIdentifierOfNewDevice);
    }
}
