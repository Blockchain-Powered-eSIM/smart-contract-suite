// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IOwnableESIMWallet } from "../interfaces/IOwnableESIMWallet.sol";
import { DeviceWallet } from "../device-wallet/DeviceWallet.sol";

error OnlyDeviceWallet();

contract ESIMWallet is IOwnableESIMWallet, Ownable, Initializable {

    using Address for address;

    /// Emitted when the eSIM wallet is deployed
    event ESIMWalletDeployed(address indexed _eSIMWalletAddress, address indexed _deviceWalletAddress, address indexed _owner);

    /// Emitted when the payment for a data bundle is made
    event DataBundleBought(string _dataBundleID, uint256 _dataBundlePrice, uint256 _transactionCount);

    /// @notice Emitted when the eSIM unique identifier is initialised
    event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier);

    /// @notice Address of the vault that receives payments for eSIM data bundles
    address public vault;

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @notice Device wallet contract instance associated with this eSIM wallet
    DeviceWallet public deviceWallet;

    /// @notice Total number of data bundle transactions made by user
    uint256 public lastTransactionCount;

    struct DataBundleDetails {
        string dataBundleID;
        uint256 dataBundlePrice;
    }

    /// @notice lastTransactionCount -> (data bundle ID, data bundle price)
    mapping(uint256 => DataBundleDetails) public transactionHistory;

    /// @dev A map from owner and spender to transfer approval. Determines whether
    ///      the spender can transfer this wallet from the owner. 
    mapping(address => mapping(address => bool)) internal _isTransferApproved;

    modifier onlyDeviceWallet() {
        if(msg.sender != deviceWalletAddress) revert OnlyDeviceWallet();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice ESIMWallet init function to initialise the contract
    /// @dev If _eSIMUniqueIdentifier is empty, the eSIM wallet is being deployed before buying an eSIM
    ///      If _eSIMUniqueIdentifier is non-empty, the eSIM wallet is being deployed after the eSIM has been bought by the user
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory contract address
    /// @param _deviceWalletAddress Device wallet contract address (the contract that deploys this eSIM wallet)
    /// @param _owner User's address
    /// @param _eSIMUniqueIdentifier Unique identifier for the eSIM wallet
    function init(
        address _eSIMWalletFactoryAddress,
        address _deviceWalletAddress,
        address _owner,
        string calldata _dataBundleID,
        uint256 _dataBundlePrice,
        string calldata _eSIMUniqueIdentifier
    ) external payable override initializer {
        require(_owner != address(0), "Owner cannot be address zero");
        require(_eSIMWalletFactoryAddress != address(0), "eSIM wallet factory address cannot be zero");
        require(_deviceWalletAddress != address(0), "Device wallet address cannot be zero");

        eSIMWalletFactory = _eSIMWalletFactoryAddress;
        deviceWallet = DeviceWallet(_deviceWalletAddress);

        if(bytes(_eSIMUniqueIdentifier).length > 0) {
            eSIMUniqueIdentifier = _eSIMUniqueIdentifier;
            emit ESIMUniqueIdentifierInitialised(_eSIMUniqueIdentifier);
        }

        _transferOwnership(_owner);

        buyDataBundle(_dataBundleID, _dataBundlePrice);

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

    /// TODO: check if ETH is in the contract, if not pull ETH from device wallet
    /// For the above TODO, approve eSIM wallet contracts to pull funds from device wallet
    /// TODO: Send ETH to eSIM wallet project's vault
    /// @notice Function to make payment for the data bundle
    /// @param _dataBundleID string data bundle ID from the backend catalogue
    /// @param _dataBundlePrice uint256 price for the data bundle
    /// @return True if the transaction is successful
    function buyDataBundle(
        string calldata _dataBundleID,
        uint256 _dataBundlePrice
    ) public payable returns (bool) {
        require(bytes(_dataBundleID).length > 0, "Data bundle ID cannot be empty");
        require(_dataBundlePrice == msg.value, "Incorrect amount");
        require(_dataBundlePrice > 0, "Price cannot be zero");

        address vault = deviceWallet.getVaultAddress();

        DataBundleDetails storage dataBundleDetails = transactionHistory[lastTransactionCount];
        dataBundleDetails.dataBundleID = _dataBundleID;
        dataBundleDetails.dataBundlePrice = _dataBundlePrice;

        emit DataBundleBought(_dataBundleID, _dataBundlePrice, lastTransactionCount);

        lastTransactionCount += 1;

        return true;
    }

    /// @dev Returns the current owner of the wallet
    function owner() public view override(IOwnableESIMWallet, Ownable) returns (address) {
        return Ownable.owner();
    }

    /// @dev Transfers ownership from the current owner to another address
    /// @param newOwner The address that will be the new owner
    function transferOwnership(address newOwner) public override(IOwnableESIMWallet, Ownable) {
        // Only the admin of deviceWalletFactory contract can transfer ownership
        require(
            isTransferApproved(owner(), msg.sender),
            "OwnableSmartWallet: Transfer is not allowed"
        );

        // Approval is revoked, in order to avoid unintended transfer allowance
        // if this wallet ever returns to the previous owner
        if (msg.sender != owner()) {
            _setApproval(owner(), msg.sender, false);
        }
        _transferOwnership(newOwner);
    }

    /// @dev Returns whether the address 'to' can transfer a wallet from address 'from'
    /// @param from The owner address
    /// @param to The spender address
    /// @notice The owner can always transfer the wallet to someone, i.e.,
    ///         approval from an address to itself is always 'true'
    function isTransferApproved(address from, address to) public override view returns (bool) {
        return from == to ? true : _isTransferApproved[from][to];
    }

    /// @dev Changes authorization status for transfer approval from msg.sender to an address
    /// @param to Address to change allowance status for
    /// @param status The new approval status
    function setApproval(address to, bool status) external onlyOwner override {
        require(
            to != address(0),
            "OwnableSmartWallet: Approval cannot be set for zero address"
        );
        _setApproval(msg.sender, to, status);
    }

    /// @param from The owner address
    /// @param to The spender address
    /// @param status Status of approval
    function _setApproval(
        address from,
        address to,
        bool status
    ) internal {
        bool statusChanged = _isTransferApproved[from][to] != status;
        _isTransferApproved[from][to] = status;
        if (statusChanged) {
            emit TransferApprovalChanged(from, to, status);
        }
    }

    receive() external payable {
        // receive ETH
    }
}
