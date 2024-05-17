// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IOwnableESIMWalletEvents {
    event TransferApprovalChanged(
        address indexed from,
        address indexed to,
        bool status
    );
}

interface IOwnableESIMWallet is IOwnableESIMWalletEvents {
    
    /// @dev Using init instead of constructor
    function init(address owner) external;

}