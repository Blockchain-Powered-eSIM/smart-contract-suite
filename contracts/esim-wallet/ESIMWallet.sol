pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IOwnableESIMWallet } from "../interfaces/IOwnableESIMWallet.sol";

error OnlyDeviceWallet();

contract ESIMWallet is IOwnableESIMWallet, Ownable, Initializable {

    using Address for address;

    /// Emitted when the eSIM wallet is deployed
    event ESIMWalletDeployed(address indexed _eSIMWalletAddress, address indexed _deviceWalletAddress, address indexed _owner);

    /// @notice Emitted when the eSIM unique identifier is initialised
    event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier);

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @notice Address of the device wallet associated with this eSIM wallet
    address public deviceWalletAddress;

    modifier onlyDeviceWallet() {
        if(msg.sender != deviceWalletAddress) revert OnlyDeviceWallet();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // TODO: create interfaces
    function init(
        address _eSIMWalletFactoryAddress,
        address _deviceWalletAddress,
        address _owner
    ) external override initializer {
        require(_owner != address(0), "Owner cannot be address zero");
        require(_eSIMWalletFactoryAddress != address(0), "eSIM wallet factory address cannot be zero");
        require(_deviceWalletAddress != address(0), "Device wallet address cannot be zero");

        eSIMWalletFactory = _eSIMWalletFactoryAddress;
        deviceWalletAddress = _deviceWalletAddress;

        _transferOwnership(_owner);

        emit ESIMWalletDeployed(address(this), _deviceWalletAddress, _owner);
    }

    /// @notice Since buying the eSIM (along with data bundle) happens before the identifier is generated,
    ///         the identifier is to be set separately after the wallet is deployed and eSIM is created
    /// @dev This function can only be called once
    /// @param _eSIMUniqueIdentifier String that uniquely identifies eSIM wallet
    function setESIMUniqueIdentifier(
        string calldata _eSIMUniqueIdentifier
    ) onlyDeviceWallet external {
        require(bytes(eSIMUniqueIdentifier).length == 0, "eSIM unique identifier already initialised");
        require(bytes(_eSIMUniqueIdentifier).length != 0, "eSIM unique identifier cannot be zero");

        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;

        emit ESIMUniqueIdentifierInitialised(_eSIMUniqueIdentifier);
    }

    function transferOwnership(address newOwner)
        public
        override(IOwnableESIMWallet, Ownable)
    {
        // Only the admin of deviceWalletFactory contract can transfer ownership
        require(
            isTransferApproved(owner(), msg.sender),
            "OwnableSmartWallet: Transfer is not allowed"
        ); // F: [OSW-4]

        // Approval is revoked, in order to avoid unintended transfer allowance
        // if this wallet ever returns to the previous owner
        if (msg.sender != owner()) {
            _setApproval(owner(), msg.sender, false); // F: [OSW-5]
        }
        _transferOwnership(newOwner); // F: [OSW-5]
    }

    receive() external payable {
        // receive ETH
    }
}