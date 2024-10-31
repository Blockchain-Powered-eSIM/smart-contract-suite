// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

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
}
