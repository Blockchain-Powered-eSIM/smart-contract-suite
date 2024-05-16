pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// TODO: Add the below mentioned  imports as per need
// import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
// import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


// TODO: Add ReentrancyGuard
contract ESIMWallet is Initializable {

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // TODO: create interfaces
    function init(
        string calldata _eSIMUniqueIdentifier,
        address _eSIMWalletFactory
    ) external virtual initializer {
        _init(
            _eSIMUniqueIdentifier,
            _eSIMWalletFactory
        );
    }

    /// @dev Internal function to initialise the DeviceWallet contract
    function _init(
        string calldata _eSIMUniqueIdentifier,
        address _eSIMWalletFactory
    ) internal {
        eSIMWalletFactory = _eSIMWalletFactory;
        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;

        return address(this);
    }
}