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
    
    function eSIMWalletFactory() external view returns (address);

    function eSIMUniqueIdentifier() external view returns (string memory);

    function deviceWalletAddress() external view returns (address);

    function init(
        address eSIMWalletFactoryAddress,
        address deviceWalletAddress,
        address owner,
        string calldata _dataBundleID,
        uint256 _dataBundlePrice,
        string calldata eSIMUniqueIdentifier
    ) external payable;

    function setESIMUniqueIdentifier(
        string calldata eSIMUniqueIdentifier
    ) external;

    function owner() external view returns (address);

    function transferOwnership(
        address newOwner
    ) external;

    function isTransferApproved(
        address from, 
        address to
    ) external view returns (bool);

    function setApproval(
        address to, 
        bool status
    ) external;
}
