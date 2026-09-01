// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/esim-wallet/ESIMWallet.sol";

contract MockESIMWallet is ESIMWallet {

    function getTransactionHistory() public view returns (DataBundleDetails[] memory) {
        return transactionHistory;
    }
}
