pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


// TODO: Add ReentrancyGuard
contract ESIMWallet is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // TODO: create interfaces
    /// @inheritdoc IESIMWallet
    function init(
        string calldata _eSIMUniqueIdentifier
    ) external virtual override initializer {
        _init(
            _eSIMUniqueIdentifier
        );
    }

    /// @dev Internal function to initialise the DeviceWallet contract
    function _init(
        string calldata _eSIMUniqueIdentifier
    ) internal {
        
        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;
    }
}