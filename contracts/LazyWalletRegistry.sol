pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Contract for deploying the factory contracts and maintaining registry
contract LazyWalletRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, RegistryHelper {

    /// @notice Address (owned/controlled by eSIM wallet project) that can upgrade contracts
    address public upgradeManager;

    /// @notice Data Bundle related details stored in the eSIM wallet
    struct DataBundleDetail {
        string dataBundleID;
        uint256 dataBundlePrice;
    }

    /// @notice Details related to eSIM purchased by the fiat user
    struct eSIMDetails {
        uint256 id;
        DataBundleDetail[] history;
    }

    /// @notice Mapping from fiat user's unique device identifier to the eSIM details
    mapping(string => eSIMDetails[]) public deviceIdentifierToESIMDetails;

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

    function initialize(address _upgradeManager) external initializer {
        require(_upgradeManager != address(0), "Upgrade Manager address cannot be zero address");
        upgradeManager = _upgradeManager;

        __Ownable_init(_upgradeManager);
    }
}
