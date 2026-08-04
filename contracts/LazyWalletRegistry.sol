pragma solidity 0.8.36;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {Registry} from "./Registry.sol";
import {Errors} from "./Errors.sol";
import "./CustomStructs.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

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

    /// @notice Longest device or eSIM identifier accepted when a new binding is created
    /// @dev An eSIM identifier is a UUID v4 in string form, so 36 bytes. This leaves room for a
    ///      longer device identifier while keeping both inside two storage words, which bounds the
    ///      keccak cost of the linear scan the switch path runs over the whole list.
    uint256 private constant MAX_IDENTIFIER_LENGTH = 64;

    /// @notice Most purchase history entries per eSIM that a deployment carries into the wallet
    /// @dev Only what the wallet receives is limited. This contract keeps every entry, so nothing
    ///      is lost and the full record stays readable. The limit exists because
    ///      deployLazyWalletAndSetESIMIdentifier writes the whole history of every eSIM in one
    ///      transaction, and history grows without bound as a user keeps buying.
    ///
    ///      Measured at 30 eSIMs, the most a device may hold: one entry each costs 15,300,000 gas
    ///      and every further entry across all 30 adds about 1,500,000, so the worst case here
    ///      lands near 21,300,000. That fits a 30,000,000 block with room left, and the deployment
    ///      chains are looser still at 40,000,000 and 1,200,000,000.
    ///
    ///      Trimmed rather than refused. Capping purchases would turn a paying user away, and
    ///      refusing to deploy a device that already exceeds the limit would strand exactly the
    ///      wallets this protects.
    uint256 private constant MAX_HISTORY_ENTRIES_PER_ESIM = 5;

    /// @dev Slot that used to hold a copy of the upgrade authority. It was written once in
    ///      `initialize` and had no setter, so it kept naming the deploy-time address once
    ///      ownership moved on. Kept so nothing below it shifts on the live proxies. Never read;
    ///      `upgradeManager()` returns `owner()` instead.
    ///
    ///      Slither raises `unused-state` and `constable-states` here. Both are false: occupying
    ///      the slot is the whole job, and either change takes it out of storage and moves every
    ///      variable below it.
    address private _retiredUpgradeManager;

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
        if(msg.sender != registry.eSIMWalletAdmin()) revert Errors.OnlyESIMWalletAdmin();
        _;
    }

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation and own it. The proxy is unaffected either way, but an
    ///      owned implementation is a trap for any later upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    override
    {}

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and there is no other route to
    ///      replace this implementation. Renouncing would freeze the contract on its current logic
    ///      permanently.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    /// @dev Reads through to the owner rather than holding its own copy. `_authorizeUpgrade` is
    ///      gated on `onlyOwner`, so the owner is the upgrade authority by definition and a second
    ///      copy could only ever disagree with it.
    function upgradeManager() public view returns (address) {
        return owner();
    }

    function initialize(
        address _registry,
        address _upgradeManager
    ) external initializer {
        if(_registry == address(0)) revert Errors.ZeroAddress("_registry");
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");

        registry = Registry(_registry);

        __Ownable2Step_init();
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
        if(len != _eSIMUniqueIdentifiers.length) {
            revert Errors.ArrayLengthMismatch(len, _eSIMUniqueIdentifiers.length);
        }
        if(len != _dataBundleDetails.length) {
            revert Errors.ArrayLengthMismatch(len, _dataBundleDetails.length);
        }

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
        if(_depositAmount != msg.value) revert Errors.DepositDoesNotMatchValue(_depositAmount, msg.value);
        if(isLazyWalletDeployed(_deviceUniqueIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_deviceUniqueIdentifier);
        }

        address deviceWallet;

        string[] memory eSIMUniqueIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
        if(eSIMUniqueIdentifiers.length == 0) {
            revert Errors.NoESIMIdentifiersForDevice(_deviceUniqueIdentifier);
        }

        address[] memory eSIMWallets = new address[](eSIMUniqueIdentifiers.length);
        DataBundleDetails[][] memory listOfDataBundleDetails = new DataBundleDetails[][](eSIMUniqueIdentifiers.length);

        for(uint256 i=0; i<eSIMUniqueIdentifiers.length; ++i) {
            listOfDataBundleDetails[i] = _recentHistory(_deviceUniqueIdentifier, eSIMUniqueIdentifiers[i]);
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
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireBoundedIdentifier(_deviceUniqueIdentifier);
        if(isLazyWalletDeployed(_deviceUniqueIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_deviceUniqueIdentifier);
        }

        uint256 len = _eSIMUniqueIdentifiers.length;
        if(len != _dataBundleDetails.length) {
            revert Errors.ArrayLengthMismatch(len, _dataBundleDetails.length);
        }

        for(uint256 i=0; i<len; ++i) {
            string calldata eSIMUniqueIdentifier = _eSIMUniqueIdentifiers[i];
            if(bytes(eSIMUniqueIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();

            string memory deviceUniqueIdentifier = eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier];

            if(bytes(deviceUniqueIdentifier).length == 0) {
                _requireBoundedIdentifier(eSIMUniqueIdentifier);

                eSIMIdentifierToDeviceIdentifier[eSIMUniqueIdentifier] = _deviceUniqueIdentifier;

                string[] storage associatedESIMIdentifiers = eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
                associatedESIMIdentifiers.push(eSIMUniqueIdentifier);

                emit ESIMBindedWithDevice(eSIMUniqueIdentifier, _deviceUniqueIdentifier);
            }
            else {
                if(keccak256(bytes(deviceUniqueIdentifier)) != keccak256(bytes(_deviceUniqueIdentifier))) {
                    revert Errors.ESIMBoundToADifferentDevice(eSIMUniqueIdentifier, deviceUniqueIdentifier);
                }
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
        if(bytes(_eSIMIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();
        if(bytes(_newDeviceIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        // Only the incoming device identifier is bounded. Bounding the eSIM identifier too would
        // block moving an over-length one off a device, which is how a device that predates this
        // limit gets unwound.
        _requireBoundedIdentifier(_newDeviceIdentifier);

        string memory currentDeviceIdentifier = eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier];
        if(bytes(currentDeviceIdentifier).length == 0) revert Errors.UnknownESIMIdentifier(_eSIMIdentifier);
        // The length check is a cheap filter ahead of the hash, not a separate condition
        if(
            bytes(currentDeviceIdentifier).length != bytes(_oldDeviceIdentifier).length ||
            keccak256(bytes(currentDeviceIdentifier)) != keccak256(bytes(_oldDeviceIdentifier))
        ) {
            revert Errors.ESIMBoundToADifferentDevice(_eSIMIdentifier, currentDeviceIdentifier);
        }
        if(keccak256(bytes(_newDeviceIdentifier)) == keccak256(bytes(currentDeviceIdentifier))) {
            revert Errors.CannotSwitchToTheSameDevice(currentDeviceIdentifier);
        }
        // Once a wallet exists onchain, the onchain graph is the authoritative record of which eSIM
        // belongs to which device, and nothing here reads back into it. Switching the old device
        // would leave the deployed eSIM wallet owned by it while deleting its purchase history.
        // Switching to a deployed new device orphans the eSIM, because deploying that device again
        // is already refused. Post-deployment movement belongs to ESIMWallet's ownership transfer.
        if(isLazyWalletDeployed(_oldDeviceIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_oldDeviceIdentifier);
        }
        if(isLazyWalletDeployed(_newDeviceIdentifier)) {
            revert Errors.LazyWalletAlreadyDeployed(_newDeviceIdentifier);
        }

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
        // The two arrays are distinct because the caller refuses a switch to the same device, so
        // pushing onto one cannot lengthen the other and the bound can be read once.
        uint256 entries = dataBundleDetails.length;
        for(uint256 i=0; i<entries; ++i) {
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

        uint256 associated = eSIMIdentifierOfOldDevice.length;
        bytes32 target = keccak256(bytes(_eSIMIdentifier));

        for(; i<associated; ++i) {
            if(keccak256(bytes(eSIMIdentifierOfOldDevice[i])) == target) {
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

    /// @notice The tail of an eSIM's purchase history, up to what a deployment can carry
    /// @dev The tail and not the head: a wallet showing five purchases should show the five most
    ///      recent ones. This contract keeps the whole record either way, so the entries left
    ///      behind stay readable through `getDeviceIdentifierToESIMDetails`.
    /// @param _deviceIdentifier Device the eSIM is bound to
    /// @param _eSIMIdentifier eSIM whose history is being read
    /// @return The most recent entries, oldest first, at most the per-eSIM limit
    function _recentHistory(
        string calldata _deviceIdentifier,
        string memory _eSIMIdentifier
    ) private view returns (DataBundleDetails[] memory) {
        DataBundleDetails[] storage history = deviceIdentifierToESIMDetails[_deviceIdentifier][_eSIMIdentifier];

        uint256 length = history.length;
        uint256 carried = length > MAX_HISTORY_ENTRIES_PER_ESIM ? MAX_HISTORY_ENTRIES_PER_ESIM : length;
        uint256 firstCarried = length - carried;

        DataBundleDetails[] memory recent = new DataBundleDetails[](carried);
        for(uint256 i=0; i<carried; ++i) {
            recent[i] = history[firstCarried + i];
        }

        return recent;
    }

    /// @notice Rejects an identifier longer than the protocol accepts
    /// @param _identifier Device or eSIM identifier about to create a new binding
    function _requireBoundedIdentifier(string calldata _identifier) private pure {
        if(bytes(_identifier).length > MAX_IDENTIFIER_LENGTH) {
            revert Errors.IdentifierTooLong(_identifier, MAX_IDENTIFIER_LENGTH);
        }
    }
}
