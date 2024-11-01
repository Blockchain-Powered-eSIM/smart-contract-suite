// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/esim-wallet/ESIMWallet.sol";

contract MockESIMWallet is ESIMWallet {

    function getTransactionHistory() public view returns (DataBundleDetails[] memory) {
        return transactionHistory;
    }
}