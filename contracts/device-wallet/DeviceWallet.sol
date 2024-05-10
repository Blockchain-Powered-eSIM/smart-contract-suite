pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UpgradeableBeacon } from "../proxy/UpgradeableBeacon.sol";

contract DeviceWallet is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Mapping from eSIMUniqueIdentifier to the respective eSIM wallet contract
    mapping(string => address) public eSIMUniqueIdentifierToESIMWallet;

    /// @dev Internal function to initialise the DeviceWallet contract
    function _init(
        string calldata _deviceUniqueIdentifier
        string[] calldata _eSIMUniqueIdentifiers
    ) internal {
        
        deviceUniqueIdentifier = _deviceUniqueIdentifier;

        for(let i=0; i<_eSIMUniqueIdentifiers.length; ++i) {
            // deploy eSIM Smart wallets
        }
    }
}