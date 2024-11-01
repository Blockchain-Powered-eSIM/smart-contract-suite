// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/device-wallet/DeviceWallet.sol";

contract MockDeviceWalletV2 is DeviceWallet {

    constructor(
        IEntryPoint anEntryPoint,
        P256Verifier _verifier
    ) DeviceWallet(anEntryPoint, _verifier) {}

    function getOwner() public view returns (bytes32[2] memory) {
        return owner;
    }

    // Just to check upgradability of the contract
    function addTwoNumbers(uint256 _a, uint256 _b) public pure returns (uint256) {
        return _a + _b;
    }
}