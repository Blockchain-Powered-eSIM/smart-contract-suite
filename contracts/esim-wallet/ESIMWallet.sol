// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {DeviceWallet} from "../device-wallet/DeviceWallet.sol";
import {Registry} from "../Registry.sol";
import {Errors} from "../Errors.sol";
import "../CustomStructs.sol";

contract ESIMWallet is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Address for address;

    /// Emitted when the eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress,
        address indexed _owner
    );

    /// Emitted when the payment for a data bundle is made
    event DataBundleBought(
        string _dataBundleID,
        uint256 _dataBundlePrice,
        uint256 _ethFromUser
    );

    /// @notice Emitted when the eSIM unique identifier is initialised
    event ESIMUniqueIdentifierInitialised(string _eSIMUniqueIdentifier);

    /// @notice Emitted for every batch of history the lazy wallet registry copies in after deployment.
    ///         `_totalEntries` is the transaction history length once the batch has landed, which is
    ///         what tells a partial copy apart from a finished one.
    event TransactionHistoryPopulated(DataBundleDetails[] _dataBundleDetails, uint256 _totalEntries);

    /// @notice Emitted when ETH moves out of this contract
    event ETHSent(address indexed _recipient, uint256 _amount);

    /// @notice Emitted when the current owner wants to transfer the ownership to a new device wallet
    event OwnershipTransferRequested(address indexed _currentOwner, address indexed _newOwner);

    /// @notice Emitted when the current owner revoked the ownership transfer request
    event OwnershipTransferRevoked(address indexed _currentOwner, address indexed _revokedOwner);

    /// @notice Emitted when the owner sets this wallet's own price ceiling
    event DataBundlePriceCapUpdated(uint256 _cap);

    /// @notice Address of the eSIM wallet factory contract
    address public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify eSIM wallet
    string public eSIMUniqueIdentifier;

    /// @notice Device wallet contract instance associated with this eSIM wallet
    DeviceWallet public deviceWallet;

    /// @notice Array of all the data bundle purchase
    DataBundleDetails[] public transactionHistory;

    /// @notice Address of the owner (device wallet) that becomes the new owner
    address public newRequestedOwner;

    /// @notice Most this wallet may be charged for one data bundle, or zero to follow the registry
    /// @dev Appended, and this contract is a leaf, so the slot lands past everything a live proxy
    ///      already holds and reads zero there. Zero has to keep meaning "no limit of my own" for
    ///      that reason, which is why the fallback lives on the registry rather than here.
    uint256 public dataBundlePriceCap;

    modifier onlyDeviceWallet() {
        if (msg.sender != address(deviceWallet)) revert Errors.OnlyDeviceWallet();
        _;
    }

    modifier onlyRegistry() {
        if(msg.sender != address(deviceWallet.registry())) revert Errors.OnlyRegistry();
        _;
    }

    function _onlyDeviceWalletOrESIMWalletAdmin() private view {
        if(
            msg.sender != address(deviceWallet) &&
            msg.sender != deviceWallet.registry().eSIMWalletAdmin()
        ) {
            revert Errors.OnlyDeviceWalletOrESIMWalletAdmin();
        }
    }

    modifier onlyDeviceWalletOrESIMWalletAdmin() {
        _onlyDeviceWalletOrESIMWalletAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @notice ESIMWallet initialize function to initialise the contract
    /// @dev If _eSIMUniqueIdentifier is empty, the eSIM wallet is being deployed before buying an eSIM
    ///      If _eSIMUniqueIdentifier is non-empty, the eSIM wallet is being deployed after the eSIM has been bought by the user
    /// @param _eSIMWalletFactoryAddress eSIM wallet factory contract address
    /// @param _deviceWalletAddress Device wallet contract address (the contract that deploys this eSIM wallet)
    function initialize(
        address _eSIMWalletFactoryAddress,
        address _deviceWalletAddress
    ) external initializer {
        if(_eSIMWalletFactoryAddress == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactoryAddress");
        if(_deviceWalletAddress == address(0)) revert Errors.ZeroAddress("_deviceWalletAddress");

        eSIMWalletFactory = _eSIMWalletFactoryAddress;
        deviceWallet = DeviceWallet(payable(_deviceWalletAddress));

        __Ownable_init(_deviceWalletAddress);
        __ReentrancyGuard_init();

        emit ESIMWalletDeployed(address(this), _deviceWalletAddress, _deviceWalletAddress);
    }

    /// @notice Since buying the eSIM (along with data bundle) happens before the identifier is generated,
    ///         the identifier is to be set separately after the wallet is deployed and eSIM is created
    /// @dev This function can only be called once
    /// @param _eSIMUniqueIdentifier String that uniquely identifies eSIM wallet
    function setESIMUniqueIdentifier(string calldata _eSIMUniqueIdentifier) external onlyDeviceWallet {
        // Read the identifier itself only on the failing branch, so setting one for the first time
        // pays for the length slot alone
        if(bytes(eSIMUniqueIdentifier).length != 0) revert Errors.ESIMIdentifierAlreadySet(eSIMUniqueIdentifier);
        if(bytes(_eSIMUniqueIdentifier).length == 0) revert Errors.EmptyESIMIdentifier();

        eSIMUniqueIdentifier = _eSIMUniqueIdentifier;

        emit ESIMUniqueIdentifierInitialised(_eSIMUniqueIdentifier);
    }

    /// @notice Function to make payment for the data bundle
    /// @param _dataBundleDetail Details of the data bundle being bought. (dataBundleID, dataBundlePrice)
    /// @return True if the transaction is successful
    function buyDataBundle(
        DataBundleDetails memory _dataBundleDetail
    ) public payable onlyDeviceWalletOrESIMWalletAdmin nonReentrant returns (bool) {
        Registry registry = deviceWallet.registry();
        registry.requireNotPaused();
        if(bytes(_dataBundleDetail.dataBundleID).length == 0) revert Errors.EmptyDataBundleID();
        if(_dataBundleDetail.dataBundlePrice == 0) revert Errors.ZeroDataBundlePrice();
        _requirePriceWithinCap(_dataBundleDetail.dataBundlePrice, registry);

        // 1. msg.value is received by contract
        // 2. if wallet balance is less than dataBundlePrice, pull ETH from device wallet
        // 3. send dataBundlePrice amount of ETH to vault
        uint256 walletBalance = address(this).balance;

        if (walletBalance < _dataBundleDetail.dataBundlePrice) {
            uint256 remainingETH = _dataBundleDetail.dataBundlePrice - walletBalance;
            deviceWallet.pullETH(remainingETH);
        }

        address vault = deviceWallet.getVaultAddress();
        _transferETH(vault, _dataBundleDetail.dataBundlePrice);

        transactionHistory.push(_dataBundleDetail);

        emit DataBundleBought(_dataBundleDetail.dataBundleID, _dataBundleDetail.dataBundlePrice, msg.value);

        return true;
    }

    /// @notice Sets the most this wallet may be charged for one data bundle
    /// @dev Only the owning device wallet, which means the person holding its P256 key: reaching
    ///      this needs a device wallet `execute`, and that needs a signature. The admin names the
    ///      price on `buyDataBundle`, so it must not also be able to raise the ceiling on that
    ///      price. Setting zero hands the wallet back to the registry's ceiling.
    /// @param _cap Maximum price in wei, or zero to follow the registry
    function setDataBundlePriceCap(uint256 _cap) external onlyDeviceWallet {
        dataBundlePriceCap = _cap;
        emit DataBundlePriceCapUpdated(_cap);
    }

    /// @notice Rejects a price above whichever ceiling applies to this wallet
    /// @dev The wallet's own ceiling wins when it has one. Zero is not a ceiling of zero, because
    ///      every wallet deployed before this existed reads zero and would otherwise be unable to
    ///      buy anything.
    /// @param _price Price being charged
    /// @param _registry Registry holding the fallback ceiling
    function _requirePriceWithinCap(uint256 _price, Registry _registry) private view {
        uint256 cap = dataBundlePriceCap;
        if (cap == 0) {
            cap = _registry.defaultDataBundlePriceCap();
        }

        if (cap != 0 && _price > cap) {
            revert Errors.DataBundlePriceAboveCap(_price, cap);
        }
    }

    /// @notice Appends pre-deployment purchase history, one batch at a time, on behalf of the lazy
    ///         wallet registry
    /// @dev The registry carries the cursor that says how much of an eSIM's history has already been
    ///      copied, so this function appends whatever it is handed and does not police repeats.
    /// @param _dataBundleDetails One batch of data bundle purchase details from before the wallet
    ///        was deployed
    function populateHistory(DataBundleDetails[] calldata _dataBundleDetails) external onlyRegistry returns (bool) {
        // Assigning the whole calldata array at once is not supported for arrays of structs, so
        // each entry is pushed on its own. The batch lands after whatever the array already held.
        uint256 alreadyStored = transactionHistory.length;
        uint256 entries = _dataBundleDetails.length;
        for (uint256 i = 0; i < entries; ++i) {
            transactionHistory.push(_dataBundleDetails[i]);
        }

        emit TransactionHistoryPopulated(_dataBundleDetails, alreadyStored + entries);

        return true;
    }

    /// @dev Returns the current owner of the wallet
    function owner() public view override returns (address) {
        return OwnableUpgradeable.owner();
    }

    /// @notice Function to request transfer of ownership (a 2-step transfer) to a new device wallet
    /// If the owner revokes the transfer, they have to manually add the eSIM wallet from their device wallet
    /// @param _newOwner Address of the new device wallet to transfer ownership of this wallet
    /** 
    *   @dev newRequestedOwner is deliberately not checked for address(0).
    *   This helps in scenario where the owner sends ownership request to a wrong address
    *   The owner (device wallet) can simply call this function to overwrite the request
    */
    function requestTransferOwnership(address _newOwner) external onlyDeviceWallet nonReentrant {
        Registry registry = deviceWallet.registry();
        if(!registry.isDeviceWalletValid(_newOwner)) revert Errors.NotADeviceWallet(_newOwner);

        // If the owner wants to retain the ownership of the contract, 
        // they simply revoke the request by requesting a transfer to themselves
        if(_newOwner == owner()) {
            address revokedAddress = newRequestedOwner;
            newRequestedOwner = address(0);
            emit OwnershipTransferRevoked(owner(), revokedAddress);
            return;
        }

        // Remove this eSIMWallet from the device wallet and send all ETH to device wallet.
        // The transient window opens here rather than at acceptance, so a reader that sees the
        // standby flag raised also sees the request that caused it.
        deviceWallet.removeESIMWallet(address(this), true);

        newRequestedOwner = _newOwner;

        emit OwnershipTransferRequested(owner(), newRequestedOwner);
    }

    /// @notice Function to be called by the new owner to accept the ownership
    function acceptOwnershipTransfer() external {
        address requestedOwner = newRequestedOwner;
        if(msg.sender != requestedOwner) revert Errors.OnlyRequestedOwner(requestedOwner);

        _secureTransferOwnership();
    }

    /// @notice Allow the owner device wallet to callback all the ETH from this eSIM wallet
    /// @dev This function is generally called before the owner device wallet removes this eSIM wallet
    /// @dev Deliberately not nonReentrant. removeESIMWallet calls this from inside a try/catch while
    ///      requestTransferOwnership already holds this contract's guard, so guarding here would
    ///      make the callback revert into that catch and strand the wallet's ETH with no error.
    ///      It writes no state of its own, and only the owner can call it to move ETH to itself,
    ///      so re-entering it gains nothing.
    /// @param _amount Amount of ETH to be sent
    function sendETHToDeviceWallet(
        uint256 _amount
    ) external onlyDeviceWallet returns (uint256) {
        if(owner() == address(0)) revert Errors.ZeroAddress("owner");

        _transferETH(owner(), _amount);

        return _amount;
    }

    /// @notice Do not allow owner to directly call OwnableUpgradeable's transferOwnership function
    /// The owner should first call requestTransferOwnership and specify the recipient (new owner)
    /// The recipient (new owner) should accept the ownership using acceptOwnershipTransfer
    function transferOwnership(address) public pure override {
        revert Errors.UseAcceptOwnershipTransfer();
    }

    /// @notice An eSIM wallet always belongs to a device wallet, so ownership is never renounced
    /// @dev Renouncing leaves owner() at zero while deviceWallet still points at the old device
    ///      wallet. sendETHToDeviceWallet then reverts on its own zero-owner check and
    ///      DeviceWallet._addESIMWallet can never accept this wallet again, so the ETH held here
    ///      is unreachable for the rest of the wallet's life.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Instead of using transferOwnership, the contract uses secureTransferOwnership
    function _secureTransferOwnership() internal {
        address newOwner = newRequestedOwner;
        // Reset ownership transfer address
        newRequestedOwner = address(0);
        deviceWallet = DeviceWallet(payable(newOwner));
        // Transfer ownership to the request address
        // _transferOwnership emits OwnershipTransferred, so this function must not emit it again
        _transferOwnership(newOwner);
    }

    /// @dev Internal function to send ETH from this contract
    function _transferETH(address _recipient, uint256 _amount) internal virtual {
        uint256 balance = address(this).balance;
        if(balance < _amount) revert Errors.InsufficientBalance(balance, _amount);
        if(_recipient == address(0)) revert Errors.ZeroAddress("_recipient");

        if (_amount > 0) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert Errors.FailedToTransfer();
            else emit ETHSent(_recipient, _amount);
        }
    }

    receive() external payable {
        // receive ETH
    }
}
