// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title Beacon with upgradeable implementation
/// @dev Beacon contract holds information about the implementation contract
///      and is used by all the proxy contracts to interact with the implementation contract
///      A beacon proxy is used in scenarios where a single implementation contract is used by
///      multiple proxy contracts. In this case, eSIM wallets and device wallets
// contract UpgradeableBeacon is IBeacon, OwnableUpgradeable {
contract UpgradeableBeacon is IBeacon, OwnableUpgradeable {
    using Address for address;

    address private implementationContractAddress_;

    /// @notice Emitted when the implementation returned by the beacon is updated.
    event Upgraded(address indexed implementationContractAddress);

    /// @param _implementation Address of the logic (implementation) contract
    /// @dev ownership is transferred to an address owned by admin
    constructor(address _implementation, address _owner) {
        _setImplementation(_implementation);
        __Ownable_init(_owner);
    }

    /// @return current implementation contract address
    function implementation() external view override returns (address) {
        return implementationContractAddress_;
    }

    /// @notice Allows the admin to update the logic (implementation) contract address
    /// @param _newImplementationContractAddress Address of the new implementation contract
    function updateImplementation(address _newImplementationContractAddress) external onlyOwner {
        _setImplementation(_newImplementationContractAddress);
    }

    /// @dev internal method for setting/updating the implementation contract address.
    ///      Make sure that the supplied address is a contract
    function _setImplementation(address _implementationContractAddress) private {
        require(_implementationContractAddress != address(0), "Invalid implementation");
        // require(_implementationContractAddress.isContract(), "Implementation address must be a contract address");
        implementationContractAddress_ = _implementationContractAddress;
        emit Upgraded(implementationContractAddress_);
    }
}

// Based on https://github.com/OpenZeppelin/@openzeppelin-contracts/blob/0db76e98f90550f1ebbb3dea71c7d12d5c533b5c/contracts/proxy/UpgradeableBeacon.sol
