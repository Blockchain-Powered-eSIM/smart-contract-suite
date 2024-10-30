pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../Registry.sol";
import {DeviceWallet} from "./DeviceWallet.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {P256Verifier} from "../P256Verifier.sol";

error OnlyAdmin();

/// @notice Contract for deploying a new eSIM wallet
contract DeviceWalletFactory is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    /// @notice Emitted when factory is deployed and admin is set
    event DeviceWalletFactoryDeployed(
        address _admin,
        address _vault,
        address indexed _upgradeManager,
        address indexed _deviceWalletImplementation,
        address indexed _beacon
    );

    /// @notice Emitted when the Vault address is updated
    event VaultAddressUpdated(address indexed _updatedVaultAddress);

    /// @notice Emitted when a new device wallet is deployed
    event DeviceWalletDeployed(
        address indexed _deviceWalletAddress,
        address indexed _eSIMWalletAddress,
        bytes32[2] _deviceWalletOwnerKey
    );

    /// @notice Emitted when the current admin requests to transfer admin role to a new address
    event AdminUpdateRequested(address indexed eSIMWalletAdmin, address indexed _newAdmin);

    /// @notice Emitted when the newly requested admin accepts the role
    event AdminUpdated(address indexed _newAdmin);

    /// @notice Emitted when the current admin revokes the transfer of ownership
    event AdminUpdateRevoked(address indexed _currentAdmin, address indexed _revokedAddress);

    /// @notice Emitted when the device wallet implementation is updated
    event DeviceWalletImplementationUpdated(address indexed _newDeviceImplementation);

    IEntryPoint public entryPoint;

    P256Verifier public verifier;

    /// @notice Admin address of the eSIM wallet project
    address public eSIMWalletAdmin;

    /// @notice Vault address that receives payments for eSIM data bundles
    address public vault;

    /// @notice Upgradeable beacon that points to correct Device wallet implementation
    /// @dev    Just updating the device wallet implementation address in this contract resolves
    ///         the issue of manually updating each device wallet proxy with a new implementation
    UpgradeableBeacon public beacon;

    ///@notice Registry contract instance
    Registry public registry;

    /// @notice Address of the admin to be appointed
    /// @dev Only the current admin can send the request to transfer admin role
    ///      The new admin should accept the role, once accepted, this variable should be reset
    address public newRequestedAdmin;

    function _onlyAdmin() private view {
        if (msg.sender != eSIMWalletAdmin) revert OnlyAdmin();
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
    ) initializer {
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
    {}

    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize(
        address _registryContractAddress,
        address _deviceWalletImplementation,
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager,
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) external initializer {
        require(_eSIMWalletAdmin != address(0), "Admin cannot be zero address");
        require(_vault != address(0), "Vault address cannot be zero");
        require(_upgradeManager != address(0), "_upgradeManager cannot be zero");

        eSIMWalletAdmin = _eSIMWalletAdmin;
        vault = _vault;
        entryPoint = _entryPoint;
        verifier = _verifier;
        registry = Registry(_registryContractAddress);

        // Upgradable beacon for device wallet implementation contract
        beacon = new UpgradeableBeacon(_deviceWalletImplementation, address(this));

        emit DeviceWalletFactoryDeployed(
            _eSIMWalletAdmin,
            _vault,
            _upgradeManager,
            getCurrentDeviceWalletImplementation(),
            address(beacon)
        );
        
        __Ownable_init(_upgradeManager);
        __UUPSUpgradeable_init();
    }

    /// @notice Function to update vault address.
    /// @dev Can only be called by the admin
    /// @param _newVaultAddress New vault address
    function updateVaultAddress(address _newVaultAddress) public onlyAdmin returns (address) {
        require(vault != _newVaultAddress, "Cannot update to same address");
        require(_newVaultAddress != address(0), "Vault address cannot be zero");

        vault = _newVaultAddress;
        emit VaultAddressUpdated(vault);

        return vault;
    }

    /// @notice 2-step admin update function. Current admin sends request to for the new admin to accept the role
    /// @dev The function deliberately doesn't check for any existing requests
    ///      In case the current admin sends request to an unintended address, the admin can override 
    ///      the request to a new (intended) address by calling this function again.
    /// @param _newAdmin Address of the recipient to recieve the admin role
    function requestAdminUpdate(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Admin address cannot be zero");

        if(_newAdmin == eSIMWalletAdmin) {
            address revokedAdmin = newRequestedAdmin;
            newRequestedAdmin = address(0);
            emit AdminUpdateRevoked(msg.sender, revokedAdmin);
        }
        else {
            newRequestedAdmin = _newAdmin;
            emit AdminUpdateRequested(eSIMWalletAdmin, _newAdmin);
        }
    }

    /// @notice Function to update admin address
    /// @return Address of the new admin
    function acceptAdminUpdate() external returns (address) {
        require(msg.sender == newRequestedAdmin, "Unauthorised");

        eSIMWalletAdmin = msg.sender;
        emit AdminUpdated(msg.sender);

        // Reset the requested admin to address(0) for further role transfer
        newRequestedAdmin = address(0);

        return eSIMWalletAdmin;
    }

    /// @notice Function to update the device wallet implementation
    /// @param _newDeviceImpl Address of the new device implementation contract
    function updateDeviceWalletImplementation(
        address _newDeviceImpl
    ) external onlyOwner returns (address) {
        require(_newDeviceImpl != address(0), "_newDeviceImpl 0");
        require(_newDeviceImpl != getCurrentDeviceWalletImplementation(), "Existing implementation");

        beacon.upgradeTo(_newDeviceImpl);

        emit DeviceWalletImplementationUpdated(getCurrentDeviceWalletImplementation());

        return getCurrentDeviceWalletImplementation();
    }

    /// @notice To deploy multiple device wallets at once
    /// @param _deviceUniqueIdentifiers Array of unique device identifiers for each device wallet
    /// @param _deviceWalletOwnersKey Array of P256 public keys of owners of the respective device wallets
    /// @param _depositAmounts Array of all the ETH to be deposited into each of the device wallets 
    /// @return Array of deployed device wallet address
    function deployDeviceWalletForUsers(
        string[] memory _deviceUniqueIdentifiers,
        bytes32[2][] memory _deviceWalletOwnersKey,
        uint256[] calldata _salts,
        uint256[] calldata _depositAmounts
    ) external payable onlyAdmin returns (address[] memory) {
        uint256 numberOfDeviceWallets = _deviceUniqueIdentifiers.length;
        require(numberOfDeviceWallets != 0, "Array cannot be empty");
        require(numberOfDeviceWallets == _deviceWalletOwnersKey.length, "Array mismatch");
        require(numberOfDeviceWallets == _salts.length, "Array mismatch");
        require(numberOfDeviceWallets == _depositAmounts.length, "Array mismatch");

        // Track the available ETH to spend
        uint256 availableETH = msg.value;
        address[] memory deviceWalletsDeployed = new address[](numberOfDeviceWallets);

        for (uint256 i = 0; i < numberOfDeviceWallets; ++i) {
            require(_depositAmounts[i] <= availableETH, "Out of ETH");
            
            deviceWalletsDeployed[i] = deployDeviceWalletAsAdmin(
                _deviceUniqueIdentifiers[i],
                _deviceWalletOwnersKey[i],
                _salts[i],
                _depositAmounts[i]
            );

            availableETH -= _depositAmounts[i];
        }

        return deviceWalletsDeployed;
    }

    /// @dev Allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _deviceWalletOwnerKey User's P256 public key (owner of the device wallet and respective eSIM wallets)
    /// @param _depositAmount Amount of ETH to be deposited into the device wallet
    /// @return Deployed device wallet address
    function deployDeviceWalletAsAdmin(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt,
        uint256 _depositAmount
    ) public payable onlyAdmin returns (address) {
        address deviceWalletAddress = address(
            createAccount(
                _deviceUniqueIdentifier,
                _deviceWalletOwnerKey,
                _salt,
                _depositAmount
            )
        );

        ESIMWalletFactory eSIMWalletFactory = registry.eSIMWalletFactory();
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(deviceWalletAddress, _salt);
        DeviceWallet(payable(deviceWalletAddress)).addESIMWallet(
            eSIMWalletAddress,
            true
        );

        emit DeviceWalletDeployed(deviceWalletAddress, eSIMWalletAddress, _deviceWalletOwnerKey);

        return deviceWalletAddress;
    }

    /**
     * create an account, and return its address.
     * returns the address even if the account is already deployed.
     * Note that during UserOperation execution, this method is called only if the account is not deployed.
     * This method returns an existing account address so that entryPoint.getSenderAddress() would work even after account creation
     */
    function createAccount(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt,
        uint256 _depositAmount
    ) public payable returns (DeviceWallet deviceWallet) {
        require(
            bytes(_deviceUniqueIdentifier).length != 0, 
            "DeviceIdentifier cannot be empty"
        );

        address addr = getAddress(
            address(registry),
            _deviceWalletOwnerKey,
            _deviceUniqueIdentifier,
            _salt
        );

        address wallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);
        if(wallet != address(0)) {
            return DeviceWallet(payable(wallet));
        }

        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return DeviceWallet(payable(addr));
        }

        // Prefund the account with msg.value
        if (msg.value > 0 && _depositAmount == msg.value) {
            entryPoint.depositTo{value: _depositAmount}(addr);
        }

        deviceWallet = DeviceWallet(
            payable(
                new BeaconProxy{salt : bytes32(_salt)}(
                    address(beacon),
                    abi.encodeCall(
                        DeviceWallet.init, 
                        (address(registry), _deviceWalletOwnerKey, _deviceUniqueIdentifier)
                    )
                )
            )
        );

        registry.updateDeviceWalletInfo(address(deviceWallet), _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    /**
     * calculate the counterfactual address of this account as it would be returned by createAccount()
     */
    function getAddress(
        address _registry,
        bytes32[2] memory _deviceWalletOwnerKey,
        string memory _deviceUniqueIdentifier,
        uint256 _salt
    ) public view returns (address) {
        return Create2.computeAddress(
            bytes32(_salt),
            keccak256(
                abi.encodePacked(
                    type(BeaconProxy).creationCode,
                    abi.encode(
                        getCurrentDeviceWalletImplementation(),
                        abi.encodeCall(
                            DeviceWallet.init,
                            (_registry, _deviceWalletOwnerKey, _deviceUniqueIdentifier)
                        )
                    )
                )
            )
        );
    }

    /// @notice Public function to get the current device wallet implementation (logic) contract
    function getCurrentDeviceWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
