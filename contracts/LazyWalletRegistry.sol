pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Registry} from "./Registry.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, RegistryHelper {

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
    struct eSIMDetails {
        DataBundleDetail[] history;
    }

    /// @notice Struct to store list of all eSIMs associated with a device
    struct associatedESIMIdentifiers {
        string[] eSIMIdentifiers;
    }

    /// @notice Device identifier <> eSIM identifier <> eSIMDetails(purchase history)
    mapping(string => mapping(string => eSIMDetails)) public deviceIdentifierToESIMDetails;

    /// @notice Mapping from eSIM unique identifier to device unique identifier
    /// @dev A device identifier can have multiple associated eSIM identifiers.
    /// But an eSIM identifier can have only a single device identifier.
    mapping(string => string) public eSIMIdentifierToDeviceIdentifier;

    /// @notice Device identifier <> List of associated eSIM identifiers
    mapping(string => associatedESIMIdentifiers) public eSIMIdentifiersAssociatedWithDeviceIdentifier;

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

    function batchPopulateHistory(
        string[] calldata _deviceUniqueIdentifiers,
        string[][] calldata _eSIMUniqueIdentifiers,
        eSIMDetails[][] calldata _eSIMDetails
    ) external {
        uint256 len = _deviceUniqueIdentifiers.length;
        require(len == _eSIMUniqueIdentifiers.length, "Unequal array provided");
        require(len == _eSIMDetails.length, "Unequal array provided");

        for(uint256 i=0; i<len; ++i) {
            _populateHistory(_deviceUniqueIdentifiers[i], _eSIMUniqueIdentifiers[i], _eSIMDetails[i]);
        }
    }

    function _populateHistory(
        string calldata _deviceUniqueIdentifier,
        string[] calldata _eSIMUniqueIdentifiers,
        eSIMDetails[] calldata _eSIMDetails
    ) internal {

    }
}
