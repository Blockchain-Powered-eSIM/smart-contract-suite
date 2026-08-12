// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import "contracts/LazyWalletRegistry.sol";

contract MockLazyWalletRegistry is LazyWalletRegistry {

    function getDeviceIdentifierToESIMDetails(
        string calldata _deviceIdentifier,
        string calldata _eSIMIdentifier
    ) public view returns (DataBundleDetails[] memory) {
        return deviceIdentifierToESIMDetails[_deviceIdentifier][_eSIMIdentifier];
    }

    function getESIMIdentifiersAssociatedWithDeviceIdentifier(
        string calldata _deviceUniqueIdentifier
    ) public view returns (string[] memory) {
        return eSIMIdentifiersAssociatedWithDeviceIdentifier[_deviceUniqueIdentifier];
    }

    /// @notice Writes the identifier mapping directly, without touching the associated array
    /// @dev The two are always written together in production. This exists so a test can force
    ///      the gap between them and exercise the guard that catches it.
    function setESIMIdentifierToDeviceIdentifier(
        string calldata _eSIMIdentifier,
        string calldata _deviceIdentifier
    ) external {
        eSIMIdentifierToDeviceIdentifier[_eSIMIdentifier] = _deviceIdentifier;
    }
}
