pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {Registry} from "../Registry.sol";
import {DeviceWalletFactory} from "./DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {ESIMWallet} from "../esim-wallet/ESIMWallet.sol";
import {Account4337} from "../aa-helper/Account4337.sol";
import {P256Verifier} from "../P256Verifier.sol";

error OnlyRegistryOrDeviceWalletFactoryOrOwner();
error OnlyDeviceWalletOrOwner();
error OnlyESIMWalletAdminOrLazyWallet();
error OnlyESIMWalletAdminOrDeviceWalletOwner();
error OnlyESIMWalletAdminOrDeviceWalletFactory();
error OnlyAssociatedESIMWallets();
error FailedToTransfer();
error OnlyESIMWalletAdmin();

contract DeviceWallet is Initializable, ReentrancyGuardUpgradeable, Account4337 {
    using Address for address;

    /// @notice Emitted when the contract pays ETH for data bundle
    event ETHPaidForDataBundle(address indexed _vault, address indexed _eSIMWallet, uint256 indexed _amount);

    /// @notice Emitted when ower updates ETH access to a particular eSIM wallet
    event ETHAccessUpdated(address indexed _eSIMWalletAddress, bool _hasAccessToETH);

    /// @notice Emitted when ETH is sent out from the contract
    /// @dev mostly when an eSIM wallet pulls ETH from this contract
    event ETHSent(address indexed _eSIMWalletAddress, uint256 _amount);

    /// @notice Emitted when eSIM wallet is added to this Device Wallet
    event ESIMWalletAdded(address indexed _eSIMWalletAddress, bool _hasAccessToETH, address indexed _caller);

    /// @notice EMitted when the eSIM wallet is removed from this Device Wallet
    event ESIMWalletRemoved(address indexed _eSIMWalletAddress, address indexed _deviceWalletAddress, address indexed _caller);

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM wallet factory address
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice String identifier to uniquely identify user's device
    string public deviceUniqueIdentifier;

    /// @notice Set to true if the eSIM wallet belongs to this device wallet
    mapping(address => bool) public isValidESIMWallet;

    /// @notice Mapping that tracks if an associated eSIM wallet can pull ETH or not
    mapping(address => bool) public canPullETH;

    function _onlyRegistryOrDeviceWalletFactoryOrOwner() private view {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            msg.sender != address(this)
        ) {
            revert OnlyRegistryOrDeviceWalletFactoryOrOwner();
        }
    }

    modifier onlyRegistryOrDeviceWalletFactoryOrOwner() {
        _onlyRegistryOrDeviceWalletFactoryOrOwner();
        _;
    }

    function _onlyDeviceWalletFactoryOrOwner() private view {
        if(
            msg.sender != address(this) &&
            msg.sender != address(registry.deviceWalletFactory())
        ) {
            revert OnlyDeviceWalletOrOwner();
        }
    }

    modifier onlyDeviceWalletFactoryOrOwner() {
        _onlyDeviceWalletFactoryOrOwner();
        _;
    }

    function _onlyESIMWalletAdminOrLazyWallet() private view {
        if (
            msg.sender != registry.deviceWalletFactory().eSIMWalletAdmin() &&
            msg.sender != registry.lazyWalletRegistry()
        ) {
            revert OnlyESIMWalletAdminOrLazyWallet();
        }
    }

    modifier onlyESIMWalletAdminOrLazyWallet() {
        _onlyESIMWalletAdminOrLazyWallet();
        _;
    }

    function _onlyAssociatedESIMWallets() private view {
        if (!isValidESIMWallet[msg.sender]) revert OnlyAssociatedESIMWallets();
    }

    modifier onlyAssociatedESIMWallets() {
        _onlyAssociatedESIMWallets();
        _;
    }

    modifier onlyESIMWalletAdmin() {
        if(
            msg.sender != registry.deviceWalletFactory().eSIMWalletAdmin()
        ) {
            revert OnlyESIMWalletAdmin();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint anEntryPoint,
        P256Verifier _verifier
    ) Account4337(anEntryPoint, _verifier) initializer {
        _disableInitializers();
    }

    /// @notice Initialises the device wallet and deploys eSIM wallets for any already existing eSIMs
    function init(
        address _registry,
        bytes32[2] memory _deviceWalletOwnerKey,
        string memory _deviceUniqueIdentifier
    ) external initializer {
        require(_registry != address(0), "Registry contract cannot be zero");
        require(bytes(_deviceUniqueIdentifier).length != 0, "Device identifier cannot be zero");

        registry = Registry(_registry);
        deviceUniqueIdentifier = _deviceUniqueIdentifier;
        eSIMWalletFactory = registry.eSIMWalletFactory();
        
        initialize(_deviceWalletOwnerKey);
        __ReentrancyGuard_init();
    }

    /// @notice Allow device wallet owner to deploy new eSIM wallet
    /// @dev Don't forget to call setESIMUniqueIdentifierForAnESIMWallet function after deploying eSIM wallet
    /// @param _hasAccessToETH Set to true if the eSIM wallet is allowed to pull ETH from this wallet.
    /// @return eSIM wallet address
    function deployESIMWallet(
        bool _hasAccessToETH,
        uint256 _salt
    ) external onlyESIMWalletAdmin returns (address) {
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(address(this), _salt);

        addESIMWallet(eSIMWalletAddress, _hasAccessToETH);

        return eSIMWalletAddress;
    }

    /// @notice Allow wallet owner or admin to set unique identifier for their eSIM wallet
    /// @dev Allow lazy wallet registry to call the function for fiat users who later decided to get a smart wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet smart contract
    /// @param _eSIMUniqueIdentifier String unique identifier for the eSIM wallet
    function setESIMUniqueIdentifierForAnESIMWallet(
        address _eSIMWalletAddress,
        string calldata _eSIMUniqueIdentifier
    ) public onlyESIMWalletAdminOrLazyWallet returns (string memory) {
        require(
            registry.isESIMWalletValid(_eSIMWalletAddress) != address(0),
            "Unknown eSIM wallet address"
        );

        ESIMWallet eSIMWallet = ESIMWallet(payable(_eSIMWalletAddress));
        eSIMWallet.setESIMUniqueIdentifier(_eSIMUniqueIdentifier);

        return eSIMWallet.eSIMUniqueIdentifier();
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pay ETH for data bundles
    /// @dev Instead of pulling the ETH into the eSIM wallet and then sending to the vault,
    ///      the eSIM wallet can directly request the device wallet to pay ETH for the data bundles
    /// NOTE This function is not yet being used by the eSIM wallet. If not needed, this might be removed in future
    /// @param _amount Amount of ETH to pull
    function payETHForDataBundles(uint256 _amount) external onlyAssociatedESIMWallets nonReentrant returns (uint256) {
        require(_amount > 0, "_amount 0");
        require(canPullETH[msg.sender] == true, "Access revoked");

        address vault = getVaultAddress();
        _transferETH(vault, _amount);

        emit ETHPaidForDataBundle(vault, msg.sender, _amount);

        return _amount;
    }

    /// @notice Allow the eSIM wallets associated with this device wallet to pull ETH (for data bundles)
    /// @param _amount Amount of ETH to pull
    function pullETH(uint256 _amount) external onlyAssociatedESIMWallets nonReentrant returns (uint256) {
        require(_amount > 0, "_amount 0");
        require(canPullETH[msg.sender] == true, "Access revoked");

        _transferETH(msg.sender, _amount);

        return _amount;
    }

    /// @notice Fetches the vault address (that receives payment for data bundles) from the device wallet factory
    /// @dev Mostly used by the associated eSIM wallets for reference
    function getVaultAddress() public view returns (address) {
        return registry.vault();
    }

    /// @notice Allow owner to revoke or give access to any associated eSIM wallet for pulling ETH
    /// @param _eSIMWalletAddress Address of the eSIM wallet to toggle ETH access for
    /// @param _hasAccessToETH Set to true to give access, false to revoke access
    function toggleAccessToETH(address _eSIMWalletAddress, bool _hasAccessToETH) public onlySelf {
        require(isValidESIMWallet[_eSIMWalletAddress], "Unknown _eSIMWalletAddress");

        canPullETH[_eSIMWalletAddress] = _hasAccessToETH;

        emit ETHAccessUpdated(_eSIMWalletAddress, _hasAccessToETH);
    }

    function _transferETH(address _recipient, uint256 _amount) internal virtual {
        require(_amount <= address(this).balance, "Not enough ETH");
        require(_recipient != address(0), "_recipient 0");

        if (_amount > 0) {
            (bool success,) = _recipient.call{value: _amount}("");
            if (!success) revert FailedToTransfer();
            else emit ETHSent(_recipient, _amount);
        }
    }

    /// @notice Allow the device wallet factory or the wallet owner to add new eSIM wallet to this device wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be added
    function addESIMWallet(
        address _eSIMWalletAddress,
        bool _hasAccessToETH
    ) public onlyRegistryOrDeviceWalletFactoryOrOwner {
        require(registry.isESIMWalletValid(_eSIMWalletAddress) == address(0), "Already has device wallet");
        
        isValidESIMWallet[_eSIMWalletAddress] = true;
        canPullETH[_eSIMWalletAddress] = _hasAccessToETH;

        // Inform and update the registry about the newly added eSIM wallet to this device wallet
        registry.updateDeviceWalletAssociatedWithESIMWallet(_eSIMWalletAddress, address(this));
        // Since the eSIM wallet now has a device wallet, remove it from standby
        if(registry.isESIMWalletOnStandby(_eSIMWalletAddress)) {
            registry.toggleESIMWalletStandbyStatus(_eSIMWalletAddress, false);
        }

        emit ESIMWalletAdded(_eSIMWalletAddress, _hasAccessToETH, msg.sender);
    }

    /// @notice Allow device wallet factory or the wallet owner to remove any eSIM wallet bound with this device wallet
    /// @param _eSIMWalletAddress Address of the eSIM wallet to be removed
    function removeESIMWallet(
        address _eSIMWalletAddress
    ) public onlyDeviceWalletFactoryOrOwner {
        require(isValidESIMWallet[_eSIMWalletAddress] == true, "Unknown eSIM wallet");

        isValidESIMWallet[_eSIMWalletAddress] = false;
        canPullETH[_eSIMWalletAddress] = false;

        // Inform and update the registry about the newly added eSIM wallet to this device wallet
        registry.updateDeviceWalletAssociatedWithESIMWallet(_eSIMWalletAddress, address(0));
        registry.toggleESIMWalletStandbyStatus(_eSIMWalletAddress, true);

        emit ESIMWalletRemoved(_eSIMWalletAddress, address(this), msg.sender);
    }

    // receive function already exists in the Account4337.sol
    // receive() external payable {
    //     receive ETH
    // }
}
