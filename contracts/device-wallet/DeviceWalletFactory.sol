pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../Registry.sol";
import {DeviceWallet} from "./DeviceWallet.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {UpgradeableBeacon} from "../UpgradableBeacon.sol";
import {P256Verifier} from "../P256Verifier.sol";

error OnlyAdmin();

/// @notice Contract for deploying a new eSIM wallet
contract DeviceWalletFactory is Initializable, OwnableUpgradeable {

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

    /// @notice Emitted when the admin address is updated
    event AdminUpdated(address indexed _newAdmin);

    IEntryPoint public immutable entryPoint;

    P256Verifier public immutable verifier;

    /// @notice Admin address of the eSIM wallet project
    address public eSIMWalletAdmin;

    /// @notice Vault address that receives payments for eSIM data bundles
    address public vault;

    /// @notice Implementation (logic) contract address of the device wallet
    DeviceWallet public deviceWalletImplementation;

    /// @notice Beacon contract address for this contract
    address public beacon;

    ///@notice Registry contract instance
    Registry public registry;

    function _onlyAdmin() private view {
        if (msg.sender != eSIMWalletAdmin) revert OnlyAdmin();
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) initializer {
        entryPoint = _entryPoint;
        verifier = _verifier;

        // device wallet implementation (logic) contract
        deviceWalletImplementation = new DeviceWallet(_entryPoint, _verifier);
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    {}

    /// @param _eSIMWalletAdmin Admin address of the eSIM wallet project
    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize(
        address _registryContractAddress,
        address _eSIMWalletAdmin,
        address _vault,
        address _upgradeManager
    ) external initializer {
        require(_eSIMWalletAdmin != address(0), "Admin cannot be zero address");
        require(_vault != address(0), "Vault address cannot be zero");
        require(_upgradeManager != address(0), "_upgradeManager cannot be zero");

        eSIMWalletAdmin = _eSIMWalletAdmin;
        vault = _vault;
        registry = Registry(_registryContractAddress);

        // Upgradable beacon for device wallet implementation contract
        beacon = address(new UpgradeableBeacon(address(deviceWalletImplementation), _upgradeManager));

        emit DeviceWalletFactoryDeployed(
            _eSIMWalletAdmin,
            _vault,
            _upgradeManager,
            address(deviceWalletImplementation),
            beacon
        );
        
        __Ownable_init(_upgradeManager);
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

    /// @notice Function to update admin address
    /// @param _newAdmin New admin address
    function updateAdmin(address _newAdmin) public onlyAdmin returns (address) {
        require(eSIMWalletAdmin != _newAdmin, "Cannot update to same address");
        require(_newAdmin != address(0), "Admin address cannot be zero");

        eSIMWalletAdmin = _newAdmin;
        emit AdminUpdated(eSIMWalletAdmin);

        return eSIMWalletAdmin;
    }

    /// @notice To deploy multiple device wallets at once
    /// @param _deviceUniqueIdentifiers Array of unique device identifiers for each device wallet
    /// @param _deviceWalletOwnersKey Array of P256 public keys of owners of the respective device wallets
    /// @return Array of deployed device wallet address
    function deployDeviceWalletForUsers(
        string[] memory _deviceUniqueIdentifiers,
        bytes32[2][] memory _deviceWalletOwnersKey,
        uint256[] calldata _salts
    ) public onlyAdmin returns (address[] memory) {
        uint256 numberOfDeviceWallets = _deviceUniqueIdentifiers.length;
        require(numberOfDeviceWallets != 0, "Array cannot be empty");
        require(numberOfDeviceWallets == _deviceWalletOwnersKey.length, "Array mismatch");
        require(numberOfDeviceWallets == _salts.length, "Array mismatch");

        address[] memory deviceWalletsDeployed = new address[](numberOfDeviceWallets);

        for (uint256 i = 0; i < numberOfDeviceWallets; ++i) {
            deviceWalletsDeployed[i] = deployDeviceWalletAsAdmin(
                _deviceUniqueIdentifiers[i],
                _deviceWalletOwnersKey[i],
                _salts[i]
            );
        }

        return deviceWalletsDeployed;
    }

    /// @dev Allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _deviceWalletOwnerKey User's P256 public key (owner of the device wallet and respective eSIM wallets)
    /// @return Deployed device wallet address
    function deployDeviceWalletAsAdmin(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt
    ) public onlyAdmin returns (address) {
        address deviceWalletAddress = address(
            createAccount(
                _deviceUniqueIdentifier,
                _deviceWalletOwnerKey,
                _salt
            )
        );

        ESIMWalletFactory eSIMWalletFactory = registry.eSIMWalletFactory();
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(deviceWalletAddress, _salt);
        DeviceWallet(payable(deviceWalletAddress)).addESIMWallet(
            eSIMWalletAddress,
            deviceWalletAddress,
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
        uint256 _salt
    ) public payable returns (DeviceWallet deviceWallet) {
        require(
            bytes(_deviceUniqueIdentifier).length != 0, 
            "DeviceIdentifier cannot be empty"
        );
        require(
            registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier) == address(0),
            "DeviceIdentifier already in use"
        );

        address addr = getAddress(
            address(registry),
            _deviceWalletOwnerKey,
            _deviceUniqueIdentifier,
            _salt
        );

        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return DeviceWallet(payable(addr));
        }

        // Prefund the account with msg.value
        if (msg.value > 0) {
            entryPoint.depositTo{value: msg.value}(addr);
        }

        deviceWallet = DeviceWallet(
            payable(
                new ERC1967Proxy{salt : bytes32(_salt)}(
                    address(deviceWalletImplementation),
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
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(deviceWalletImplementation),
                        abi.encodeCall(
                            DeviceWallet.init,
                            (_registry, _deviceWalletOwnerKey, _deviceUniqueIdentifier)
                        )
                    )
                )
            )
        );
    }
}
