// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

interface IOwnableESIMWalletEvents {
    event TransferApprovalChanged(address indexed from, address indexed to, bool status);
}

interface IOwnableESIMWallet is IOwnableESIMWalletEvents {
    function initialize(
        address eSIMWalletFactoryAddress,
        address deviceWalletAddress,
        address owner
    ) external;

    function setESIMUniqueIdentifier(string calldata eSIMUniqueIdentifier) external;

    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;

    function isTransferApproved(address from, address to) external view returns (bool);

    function setApproval(address to, bool status) external;
}
