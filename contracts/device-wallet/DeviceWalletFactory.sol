pragma solidity 0.8.36;

// SPDX-License-Identifier: MIT

import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Registry} from "../Registry.sol";
import {DeviceWallet} from "./DeviceWallet.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {P256Verifier} from "../P256Verifier.sol";
import {Errors} from "../Errors.sol";
import "../CustomStructs.sol";

/// @notice Contract for deploying a new eSIM wallet
contract DeviceWalletFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Emitted when factory is deployed
    event DeviceWalletFactoryDeployed(
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

    /// @notice Emitted when the device wallet implementation is updated
    event DeviceWalletImplementationUpdated(address indexed _newDeviceImplementation);

    /// @notice Emitted when the registry is added to the factory contract
    event AddedRegistry(address indexed registry);

    /// @notice Upgradeable beacon that points to correct Device wallet implementation
    /// @dev    Just updating the device wallet implementation address in this contract resolves
    ///         the issue of manually updating each device wallet proxy with a new implementation
    UpgradeableBeacon public beacon;

    IEntryPoint public entryPoint;

    P256Verifier public verifier;

    ///@notice Registry contract instance
    Registry public registry;

    /// @notice eSIM wallet factory contract instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice Vault address that receives payments for eSIM data bundles
    address public vault;

    /// @notice Tracks all the device wallets that have their data added into the registry upon deployment
    mapping(address deviceWallet => bool isAdded) public deviceWalletInfoAdded;

    /// @notice Admin address of the eSIM wallet project
    /// @dev Held by the registry, which is where it is rotated, so this contract cannot fall
    ///      behind the rest of the protocol after a rotation. Answers address(0) before the
    ///      registry is wired up, which no caller can match, so admin functions stay closed until
    ///      then rather than reverting on a call into address(0).
    function eSIMWalletAdmin() public view returns (address) {
        if(address(registry) == address(0)) return address(0);
        return registry.eSIMWalletAdmin();
    }

    function _onlyAdmin() private view {
        if (msg.sender != eSIMWalletAdmin()) revert Errors.OnlyAdmin();
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdminOrRegistry() private view {
        if (
            msg.sender != eSIMWalletAdmin() &&
            msg.sender != address(registry)
        ) revert Errors.OnlyAdminOrRegistry();
    }

    modifier onlyAdminOrRegistry() {
        _onlyAdminOrRegistry();
        _;
    }

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation, own it, and make it deploy a beacon it controls. The
    ///      proxy is unaffected either way, but an owned implementation is a trap for any later
    ///      upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
    {}

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and this contract owns the
    ///      beacon, so it is also the only route to updateDeviceWalletImplementation. Renouncing
    ///      would freeze every device wallet on its current logic permanently.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @param _vault Address of the vault that receives payments for the data bundles
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    /// @dev The admin is not taken here. It comes from the registry, which is added afterwards
    ///      through addRegistryAddress, so admin functions stay closed until that is done.
    function initialize(
        address _deviceWalletImplementation,
        address _vault,
        address _upgradeManager,
        address _eSIMWalletFactoryAddress,
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) external initializer {
        if(_vault == address(0)) revert Errors.ZeroAddress("_vault");
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");
        if(address(_entryPoint) == address(0)) revert Errors.ZeroAddress("_entryPoint");
        if(address(_verifier) == address(0)) revert Errors.ZeroAddress("_verifier");
        if(_eSIMWalletFactoryAddress == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactoryAddress");

        vault = _vault;
        entryPoint = _entryPoint;
        verifier = _verifier;
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactoryAddress);

        // Upgradable beacon for device wallet implementation contract
        beacon = new UpgradeableBeacon(_deviceWalletImplementation, address(this));

        emit DeviceWalletFactoryDeployed(
            _vault,
            _upgradeManager,
            getCurrentDeviceWalletImplementation(),
            address(beacon)
        );
        
        __Ownable_init(_upgradeManager);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Allow the owner to add the registry contract after it has been deployed
    /// @dev The owner and not the admin, because the admin is read from the registry and there is
    ///      no admin to check against until this call lands. Matches ESIMWalletFactory, which has
    ///      always gated its own version on the owner.
    function addRegistryAddress(
        address _registryContractAddress
    ) external onlyOwner returns (address) {
        if(_registryContractAddress == address(0)) revert Errors.ZeroAddress("_registryContractAddress");
        if(address(registry) != address(0)) revert Errors.RegistryAlreadySet(address(registry));

        registry = Registry(_registryContractAddress);
        emit AddedRegistry(address(registry));

        return address(registry);
    }

    /// @notice Function to update vault address.
    /// @dev Can only be called by the admin
    /// @param _newVaultAddress New vault address
    function updateVaultAddress(address _newVaultAddress) public onlyAdmin returns (address) {
        if(vault == _newVaultAddress) revert Errors.VaultUnchanged(vault);
        if(_newVaultAddress == address(0)) revert Errors.ZeroAddress("_newVaultAddress");

        vault = _newVaultAddress;
        emit VaultAddressUpdated(vault);

        return vault;
    }

    /// @notice Function to update the device wallet implementation
    /// @param _newDeviceImpl Address of the new device implementation contract
    function updateDeviceWalletImplementation(
        address _newDeviceImpl
    ) external onlyOwner returns (address) {
        if(_newDeviceImpl == address(0)) revert Errors.ZeroAddress("_newDeviceImpl");
        if(_newDeviceImpl == getCurrentDeviceWalletImplementation()) {
            revert Errors.ImplementationUnchanged(_newDeviceImpl);
        }

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
        string[] calldata _deviceUniqueIdentifiers,
        bytes32[2][] calldata _deviceWalletOwnersKey,
        uint256[] calldata _salts,
        uint256[] calldata _depositAmounts
    ) external payable onlyAdminOrRegistry returns (Wallets[] memory) {
        uint256 numberOfDeviceWallets = _deviceUniqueIdentifiers.length;
        if(numberOfDeviceWallets == 0) revert Errors.EmptyBatch();
        if(numberOfDeviceWallets != _deviceWalletOwnersKey.length) {
            revert Errors.ArrayLengthMismatch(numberOfDeviceWallets, _deviceWalletOwnersKey.length);
        }
        if(numberOfDeviceWallets != _salts.length) {
            revert Errors.ArrayLengthMismatch(numberOfDeviceWallets, _salts.length);
        }
        if(numberOfDeviceWallets != _depositAmounts.length) {
            revert Errors.ArrayLengthMismatch(numberOfDeviceWallets, _depositAmounts.length);
        }

        // Track the available ETH to spend
        uint256 availableETH = msg.value;
        Wallets[] memory walletsDeployed = new Wallets[](numberOfDeviceWallets);

        for (uint256 i = 0; i < numberOfDeviceWallets; ++i) {
            if(_depositAmounts[i] > availableETH) {
                revert Errors.InsufficientBalance(availableETH, _depositAmounts[i]);
            }
            
            uint256 spentETH;
            (walletsDeployed[i], spentETH) = _deployDeviceWallet(
                _deviceUniqueIdentifiers[i],
                _deviceWalletOwnersKey[i],
                _salts[i],
                _depositAmounts[i]
            );

            // Charge the budget for what was forwarded, not what was requested. An entry that
            // resolves to an existing wallet forwards nothing, and that ETH must stay refundable.
            availableETH -= spentETH;
        }

        // return unused ETH
        if(availableETH > 0) {
            (bool success,) = msg.sender.call{value: availableETH}("");
            if(!success) revert Errors.FailedToTransfer();
        }

        return walletsDeployed;
    }

    /// @dev Internal function to allow admin to deploy a device wallet (and an eSIM wallet) for given unique device identifiers
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _deviceWalletOwnerKey User's P256 public key (owner of the device wallet and respective eSIM wallets)
    /// @param _depositAmount Amount of ETH to be deposited into the device wallet
    /// @return Deployed device wallet address
    /// @return ETH actually forwarded to the wallet, zero if an existing wallet was returned
    function _deployDeviceWallet(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt,
        uint256 _depositAmount
    ) internal returns (Wallets memory, uint256) {
        (DeviceWallet deviceWallet, uint256 spentETH) = _createAccountForUser(
            _deviceUniqueIdentifier,
            _deviceWalletOwnerKey,
            _salt,
            _depositAmount
        );
        address deviceWalletAddress = address(deviceWallet);

        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(deviceWalletAddress, _salt);
        DeviceWallet(payable(deviceWalletAddress)).addESIMWallet(
            eSIMWalletAddress,
            true
        );

        emit DeviceWalletDeployed(deviceWalletAddress, eSIMWalletAddress, _deviceWalletOwnerKey);

        return (Wallets(deviceWalletAddress, eSIMWalletAddress), spentETH);
    }

    /// @notice Rejects a P256 public key that is not a point on the curve
    /// @dev This is the same predicate FCL_ecdsa.ecdsa_verify applies before it does anything else,
    ///      so a key rejected here is one that could never have verified a signature. A wallet
    ///      deployed with such a key is unusable for its whole life and it consumes its device
    ///      identifier and key hash, neither of which the protocol can release.
    function _requireValidOwnerKey(bytes32[2] memory _deviceWalletOwnerKey) private pure {
        if(
            !FCL_Elliptic_ZZ.ecAff_isOnCurve(
                uint256(_deviceWalletOwnerKey[0]),
                uint256(_deviceWalletOwnerKey[1])
            )
        ) revert Errors.InvalidDeviceWalletOwnerKey();
    }

    /// @dev Returns the ETH actually forwarded to the wallet, which is zero whenever an existing
    ///      wallet is returned instead of a new one being deployed. Callers holding a budget must
    ///      decrement by this value, not by the requested deposit.
    function _createAccountForUser(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt,
        uint256 _depositAmount
    ) internal returns (DeviceWallet deviceWallet, uint256 spentETH) {
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireValidOwnerKey(_deviceWalletOwnerKey);

        address addr = getCounterFactualAddress(
            _deviceWalletOwnerKey,
            _deviceUniqueIdentifier,
            _salt
        );

        // Check if the device identifier is actually unique
        address wallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);
        if(wallet != address(0)) {
            if(wallet != addr) revert Errors.DeviceWalletAlreadyExists(_deviceUniqueIdentifier, wallet);
            return (DeviceWallet(payable(wallet)), 0);
        }

        // Check if P256 public key is actually unique
        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        wallet = registry.registeredP256Keys(keyHash);
        if(wallet != address(0)) {
            if(wallet != addr) revert Errors.OwnerKeyAlreadyRegistered(keyHash);
            return (DeviceWallet(payable(wallet)), 0);
        }

        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            // The wallet exists but holds no registry record, which is the state createAccount
            // leaves behind. Anyone can put a wallet into it, so adopt it here rather than
            // returning an unregistered address that later registry writes would reject.
            deviceWalletInfoAdded[addr] = true;
            registry.updateDeviceWalletInfo(addr, _deviceUniqueIdentifier, _deviceWalletOwnerKey);

            // The deposit follows the wallet instead of staying behind to be refunded. Adoption is
            // the one existing-wallet case where the deposit was still meant for the wallet the
            // caller asked for, and leaving it behind hands anyone who deploys that address first
            // a way to force the refund through a caller that cannot receive ETH.
            if (_depositAmount > 0) {
                _fundDeviceWallet(addr, _depositAmount);
            }

            return (DeviceWallet(payable(addr)), _depositAmount);
        }

        deviceWallet = DeviceWallet(
            payable(
                new BeaconProxy{salt : bytes32(_salt)}(
                    address(beacon),
                    abi.encodeCall(
                        DeviceWallet.init, 
                        (address(registry), _deviceWalletOwnerKey, _deviceUniqueIdentifier, address(eSIMWalletFactory))
                    )
                )
            )
        );

        registry.updateDeviceWalletInfo(address(deviceWallet), _deviceUniqueIdentifier, _deviceWalletOwnerKey);
        deviceWalletInfoAdded[address(deviceWallet)] = true;

        // Funded last, after every storage write, because this hands control to the wallet
        if (_depositAmount > 0) {
            _fundDeviceWallet(address(deviceWallet), _depositAmount);
            spentETH = _depositAmount;
        }
    }

    /// @notice Sends ETH to a device wallet so that it lands in the wallet's own balance
    /// @dev No EntryPoint deposit is created. A wallet holding no deposit still transacts: the
    ///      EntryPoint reports the whole prefund as missing during validation and the account pays
    ///      it out of this balance. Until an operation needs it, the ETH is spendable for anything
    ///      else the owner wants to do. Gas the EntryPoint does not consume is refunded into the
    ///      wallet's EntryPoint deposit rather than back here, so the balance drains slowly and
    ///      the owner reclaims it with withdrawDepositTo.
    /// @param _deviceWallet Wallet to receive the ETH
    /// @param _amount Amount of ETH to send
    function _fundDeviceWallet(address _deviceWallet, uint256 _amount) private {
        (bool success, ) = _deviceWallet.call{value: _amount}("");
        if(!success) revert Errors.FailedToTransfer();
    }

    /// @notice Checks that all the input params needed for deploying a fresh device wallet are valid
    /// @dev This is needed when deploying the device wallet via the EntryPoint using userops
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _deviceWalletOwnerKey User's P256 public key (owner of the device wallet and respective eSIM wallets)
    /// @return wallet address(0) if valid. device wallet address for any existing wallet
    function preCreateAccountValidation(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) public view returns (address wallet) {
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireValidOwnerKey(_deviceWalletOwnerKey);

        // Check if the device identifier is actually unique
        wallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);
        if(wallet != address(0)) {
            return wallet;
        }

        // Check if P256 public key is actually unique
        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        wallet = registry.registeredP256Keys(keyHash);
        if(wallet != address(0)) {
            return wallet;
        }
    }

    /**
     * create an account, and return its address.
     * returns the address even if the account is already deployed.
     * Note that during UserOperation execution, this method is called only if the account is not deployed.
     * This method returns an existing account address so that entryPoint.getSenderAddress() would work even after account creation
     */
    /// @dev This createAccount needs to be called by the entry point,
    /// hence it cannot read or write to any external contract storages
    /// The validation should be done off-chain, and any storage update to external contracts should be done as a separate function
    function createAccount(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt
    ) public payable returns (DeviceWallet deviceWallet) {
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireValidOwnerKey(_deviceWalletOwnerKey);

        address addr = getCounterFactualAddress(
            _deviceWalletOwnerKey,
            _deviceUniqueIdentifier,
            _salt
        );

        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            // The wallet is already deployed, so the ETH has to follow it. Keeping it here would
            // strand it in the factory, which has no way to send it anywhere.
            if (msg.value > 0) {
                _fundDeviceWallet(addr, msg.value);
            }

            return DeviceWallet(payable(addr));
        }

        deviceWallet = DeviceWallet(
            payable(
                new BeaconProxy{salt : bytes32(_salt)}(
                    address(beacon),
                    abi.encodeCall(
                        DeviceWallet.init,
                        (address(registry), _deviceWalletOwnerKey, _deviceUniqueIdentifier, address(eSIMWalletFactory))
                    )
                )
            )
        );

        // Funding has to come after deployment, since the wallet does not exist before this point
        if (msg.value > 0) {
            _fundDeviceWallet(address(deviceWallet), msg.value);
        }
    }

    /// @notice Update the respective storage after createAccount was called via EntryPoint
    /// @dev This is not needed if the admin deploys the wallet for users as an EOA
    /// The function can be called by the admin directly, and can also be called by the registry
    /// when deploying the wallet via lazy wallet registry
    function postCreateAccount(
        address _deviceWallet,
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) external onlyAdminOrRegistry {
        if(deviceWalletInfoAdded[_deviceWallet]) revert Errors.DeviceWalletInfoAlreadyAdded(_deviceWallet);
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();

        // Flag set before the call so a second pass through here cannot reach the registry at all.
        // The registry already rejects a duplicate identifier or key, so this closes the window
        // rather than being the only thing holding it shut.
        deviceWalletInfoAdded[_deviceWallet] = true;
        registry.updateDeviceWalletInfo(address(_deviceWallet), _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    /**
     * calculate the counterfactual address of this account as it would be returned by createAccount()
     */
    function getCounterFactualAddress(
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
                        address(beacon),
                        abi.encodeCall(
                            DeviceWallet.init,
                            (address(registry), _deviceWalletOwnerKey, _deviceUniqueIdentifier, address(eSIMWalletFactory))
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
