// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/Registry.sol";

contract MockRegistry is Registry {

    function getDeviceWalletToOwner(address _deviceWallet) public view returns (bytes32[2] memory) {
        return deviceWalletToOwner[_deviceWallet];
    }
}
