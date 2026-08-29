// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/esim-wallet/ESIMWallet.sol";

contract MockESIMWalletV2 is ESIMWallet {

    function getTransactionHistory() public view returns (DataBundleDetails[] memory) {
        return transactionHistory;
    }

    // Just to check upgradability of the contract
    function addTwoNumbers(uint256 _a, uint256 _b) public pure returns (uint256) {
        return _a + _b;
    }
}
