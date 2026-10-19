// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Errors} from "../Errors.sol";

// Types
import {Wallets} from "../CustomStructs.sol";

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Registry} from "../Registry.sol";
import {DeviceWallet} from "./DeviceWallet.sol";
import {ESIMWalletFactory} from "../esim-wallet/ESIMWalletFactory.sol";
import {P256Verifier} from "../P256Verifier.sol";

/// @notice Deploys device wallets at deterministic addresses and owns the beacon they all point at
/// @dev The admin batch route deploys and registers in one go. `createAccount` runs inside ERC-4337
///      validation and writes no external storage, so `postCreateAccount` registers it afterwards.
///      Both routes give the same CREATE2 address for the same inputs.
contract DeviceWalletFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Beacon every device wallet proxy reads its implementation from
    /// @dev One update moves every wallet at once, and none can decline it.
    UpgradeableBeacon public beacon;

    /// @notice ERC-4337 EntryPoint singleton passed into every device wallet implementation
    IEntryPoint public entryPoint;

    /// @notice Contract the device wallets verify WebAuthn assertions through
    P256Verifier public verifier;

    /// @notice Registry contract instance
    Registry public registry;

    /// @notice eSIM wallet factory contract instance
    ESIMWalletFactory public eSIMWalletFactory;

    /// @notice Tracks all the device wallets that have their data added into the registry upon deployment
    mapping(address deviceWallet => bool isAdded) public deviceWalletInfoAdded;

    /// @notice Emitted when factory is deployed
    event DeviceWalletFactoryDeployed(
        address indexed _upgradeManager,
        address indexed _deviceWalletImplementation,
        address indexed _beacon
    );

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

    /// @notice Reverts unless the caller is the eSIM wallet admin or the registry
    /// @dev A function rather than inline in the modifier, so the check is compiled once.
    function _onlyAdminOrRegistry() private view {
        if (
            msg.sender != eSIMWalletAdmin() &&
            msg.sender != address(registry)
        ) revert Errors.OnlyAdminOrRegistry();
    }

    /// @notice Restricts a call to the eSIM wallet admin or the registry
    modifier onlyAdminOrRegistry() {
        _onlyAdminOrRegistry();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Disables initializers on the implementation contract
    /// @dev Otherwise anyone could initialize and own the implementation itself. The proxy is
    ///      unaffected, but an owned implementation is a trap for a later upgrade that adds an
    ///      outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Deploys the beacon and hands ownership of this factory to the upgrade manager
    /// @dev The admin and the vault are read from the registry, set later by addRegistryAddress,
    ///      so there is one source for each. Admin functions stay closed until then.
    /// @param _deviceWalletImplementation First device wallet logic contract the beacon points at
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    /// @param _eSIMWalletFactoryAddress Factory the device wallets deploy their eSIM wallets through
    /// @param _entryPoint ERC-4337 EntryPoint singleton for this chain
    /// @param _verifier Contract the device wallets verify WebAuthn assertions through
    function initialize(
        address _deviceWalletImplementation,
        address _upgradeManager,
        address _eSIMWalletFactoryAddress,
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) external initializer {
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");
        if(address(_entryPoint) == address(0)) revert Errors.ZeroAddress("_entryPoint");
        if(address(_verifier) == address(0)) revert Errors.ZeroAddress("_verifier");
        if(_eSIMWalletFactoryAddress == address(0)) revert Errors.ZeroAddress("_eSIMWalletFactoryAddress");

        entryPoint = _entryPoint;
        verifier = _verifier;
        eSIMWalletFactory = ESIMWalletFactory(_eSIMWalletFactoryAddress);

        beacon = new UpgradeableBeacon(_deviceWalletImplementation, address(this));

        emit DeviceWalletFactoryDeployed(
            _upgradeManager,
            getCurrentDeviceWalletImplementation(),
            address(beacon)
        );

        __Ownable_init(_upgradeManager);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    // ---------------------------------------------------------------------------------------------
    // Registry wiring and beacon
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the registry, once, after it has been deployed
    /// @dev Gated on the owner because the admin is read from the registry, so there is no admin
    ///      to check until this lands. Same as ESIMWalletFactory.
    /// @param _registryContractAddress Address of the registry
    /// @return The registry address now in force
    function addRegistryAddress(
        address _registryContractAddress
    ) external onlyOwner returns (address) {
        if(_registryContractAddress == address(0)) revert Errors.ZeroAddress("_registryContractAddress");
        if(address(registry) != address(0)) revert Errors.RegistryAlreadySet(address(registry));

        registry = Registry(_registryContractAddress);
        emit AddedRegistry(address(registry));

        return address(registry);
    }

    /// @notice Points the beacon at a new device wallet implementation
    /// @dev A protocol-wide upgrade: every device wallet moves at once and none can decline it.
    /// @param _newDeviceImpl Address of the new device implementation contract
    /// @return The implementation now in force
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

    // ---------------------------------------------------------------------------------------------
    // Device wallet deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys device wallets, each with its first eSIM wallet and registry records
    /// @dev Unspent ETH is returned to the caller. Refused while paused, since it moves ETH.
    /// @param _deviceUniqueIdentifiers Device identifier per wallet
    /// @param _deviceWalletOwnersKey Owner P256 public key per wallet
    /// @param _salts CREATE2 salt per wallet
    /// @param _depositAmounts ETH to deposit per wallet
    /// @return The deployed device and eSIM wallet addresses
    function deployDeviceWalletForUsers(
        string[] calldata _deviceUniqueIdentifiers,
        bytes32[2][] calldata _deviceWalletOwnersKey,
        uint256[] calldata _salts,
        uint256[] calldata _depositAmounts
    ) external payable onlyAdminOrRegistry returns (Wallets[] memory) {
        registry.requireNotPaused();
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

        uint256 availableETH = msg.value;
        Wallets[] memory walletsDeployed = new Wallets[](numberOfDeviceWallets);

        // The registry calls this to deploy against its own reservation, so only a direct admin
        // batch is checked against reservations.
        bool checkReservations = msg.sender != address(registry);

        for (uint256 i = 0; i < numberOfDeviceWallets; ++i) {
            if(_depositAmounts[i] > availableETH) {
                revert Errors.InsufficientBalance(availableETH, _depositAmounts[i]);
            }

            if(checkReservations) {
                registry.requireDeviceIdentifierNotReserved(_deviceUniqueIdentifiers[i]);
            }

            uint256 spentETH;
            (walletsDeployed[i], spentETH) = _deployDeviceWallet(
                _deviceUniqueIdentifiers[i],
                _deviceWalletOwnersKey[i],
                _salts[i],
                _depositAmounts[i]
            );

            // Charge what was forwarded, not what was requested. An entry that resolves to an
            // already registered wallet forwards nothing, and that ETH must stay refundable.
            availableETH -= spentETH;
        }

        if(availableETH > 0) {
            (bool success,) = msg.sender.call{value: availableETH}("");
            if(!success) revert Errors.FailedToTransfer();
        }

        return walletsDeployed;
    }

    /// @notice Records a wallet the EntryPoint deployed through createAccount
    /// @dev The key and identifier are proxy constructor arguments, so an address that matches the
    ///      derivation and holds code was deployed by this factory with exactly those arguments.
    /// @param _deviceWallet Wallet that was deployed
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning the wallet
    /// @param _salt CREATE2 salt the wallet was deployed with
    function postCreateAccount(
        address _deviceWallet,
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt
    ) external onlyAdminOrRegistry {
        if(deviceWalletInfoAdded[_deviceWallet]) revert Errors.DeviceWalletInfoAlreadyAdded(_deviceWallet);
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireValidOwnerKey(_deviceWalletOwnerKey);

        // Only a direct admin call claims a fresh identifier. This is also the reservation check for
        // `createAccount`, which runs in ERC-4337 validation and may not read other contracts.
        if(msg.sender != address(registry)) {
            registry.requireDeviceIdentifierNotReserved(_deviceUniqueIdentifier);
        }

        address derived = getCounterFactualAddress(
            _deviceWalletOwnerKey,
            _deviceUniqueIdentifier,
            _salt
        );
        if(derived != _deviceWallet) revert Errors.DeviceWalletMismatch(_deviceWallet, derived);

        // The derivation matches whether or not anything is deployed there yet.
        if(_deviceWallet.code.length == 0) revert Errors.DeviceWalletNotDeployed(_deviceWallet);

        // Set before the call so a reentrant pass cannot reach the registry. The registry also
        // rejects duplicates, so this is a second guard, not the only one.
        deviceWalletInfoAdded[_deviceWallet] = true;
        registry.updateDeviceWalletInfo(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment through the EntryPoint
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a device wallet, returning the existing one if that address already holds it
    /// @dev Runs in ERC-4337 validation, so it leaves the registry to `postCreateAccount`. Reading
    ///      its own and the beacon's storage needs a staked factory. Returning an existing wallet
    ///      instead of reverting keeps `entryPoint.getSenderAddress()` working after creation.
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning the wallet
    /// @param _salt CREATE2 salt for the wallet
    /// @return deviceWallet The wallet at the computed address, new or already deployed
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
            // Forward the ETH, since the factory has no way to send on anything left here
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

        if (msg.value > 0) {
            _fundDeviceWallet(address(deviceWallet), msg.value);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner alone upgrades this factory and the beacon, so renouncing would freeze every
    ///      device wallet on its current logic for good.
    function renounceOwnership() public pure override {
        revert Errors.OwnershipCannotBeRenounced();
    }

    /// @notice Restricts UUPS upgrades of this factory to the owner
    /// @param newImplementation Address of the implementation being moved to
    function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
    {}

    // ---------------------------------------------------------------------------------------------
    // Deployment internals
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys one device wallet, its first eSIM wallet and the binding between them
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _deviceWalletOwnerKey Owner P256 public key of the device and eSIM wallets
    /// @param _salt CREATE2 salt for both wallets
    /// @param _depositAmount ETH to deposit into the device wallet
    /// @return The device and eSIM wallet addresses
    /// @return ETH actually forwarded, zero if an already registered wallet was returned
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
        // No access to the device wallet's funds. Only the owner grants that, by signing
        // `toggleAccessToFunds`.
        DeviceWallet(payable(deviceWalletAddress)).addESIMWallet(
            eSIMWalletAddress,
            false
        );

        emit DeviceWalletDeployed(deviceWalletAddress, eSIMWalletAddress, _deviceWalletOwnerKey);

        return (Wallets(deviceWalletAddress, eSIMWalletAddress), spentETH);
    }

    /// @notice Deploys a device wallet and writes its registry records, or adopts one that already exists
    /// @dev Callers holding a budget must charge `spentETH`, not the requested deposit. It is zero
    ///      for an already registered wallet, and the full deposit for a new or adopted one.
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning the wallet
    /// @param _salt CREATE2 salt for the wallet
    /// @param _depositAmount ETH the caller asked to be deposited
    /// @return deviceWallet The wallet at the computed address
    /// @return spentETH ETH actually forwarded to it
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

        address wallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);
        if(wallet != address(0)) {
            if(wallet != addr) revert Errors.DeviceWalletAlreadyExists(_deviceUniqueIdentifier, wallet);
            return (DeviceWallet(payable(wallet)), 0);
        }

        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        wallet = registry.registeredP256Keys(keyHash);
        if(wallet != address(0)) {
            if(wallet != addr) revert Errors.OwnerKeyAlreadyRegistered(keyHash);
            return (DeviceWallet(payable(wallet)), 0);
        }

        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            // Deployed but unregistered, as createAccount leaves it, and anyone can do that. Adopt
            // it rather than return an address that later registry writes would reject.
            deviceWalletInfoAdded[addr] = true;
            registry.updateDeviceWalletInfo(addr, _deviceUniqueIdentifier, _deviceWalletOwnerKey);

            // The deposit was meant for this wallet, so it goes there. Refunding it instead would
            // let whoever deployed the address first force a refund to a caller that rejects ETH.
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

    /// @notice Rejects a P256 public key that is not a point on the curve
    /// @dev Same check FCL_ecdsa.ecdsa_verify runs first, so a rejected key could never sign. A
    ///      wallet with such a key is dead for life and still uses up its identifier and key hash,
    ///      which the protocol cannot release.
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key to check
    function _requireValidOwnerKey(bytes32[2] memory _deviceWalletOwnerKey) private pure {
        if(
            !FCL_Elliptic_ZZ.ecAff_isOnCurve(
                uint256(_deviceWalletOwnerKey[0]),
                uint256(_deviceWalletOwnerKey[1])
            )
        ) revert Errors.InvalidDeviceWalletOwnerKey();
    }

    /// @notice Sends ETH to a device wallet so that it lands in the wallet's own balance
    /// @dev No EntryPoint deposit is made, so the ETH stays spendable. The account pays any missing
    ///      prefund from this balance; unused gas lands in its EntryPoint deposit (withdrawDepositTo).
    /// @param _deviceWallet Wallet to receive the ETH
    /// @param _amount Amount of ETH to send
    function _fundDeviceWallet(address _deviceWallet, uint256 _amount) private {
        (bool success, ) = _deviceWallet.call{value: _amount}("");
        if(!success) revert Errors.FailedToTransfer();
    }

    // ---------------------------------------------------------------------------------------------
    // Addresses and address prediction
    // ---------------------------------------------------------------------------------------------

    /// @notice Admin address of the eSIM wallet project
    /// @dev Read from the registry so a rotation there applies here too. Returns address(0), which
    ///      no caller matches, until the registry is set, rather than calling into address(0).
    /// @return The current admin, or zero if the registry is not yet wired up
    function eSIMWalletAdmin() public view returns (address) {
        if(address(registry) == address(0)) return address(0);
        return registry.eSIMWalletAdmin();
    }

    /// @notice Checks the inputs for a fresh device wallet against the registry
    /// @dev For use before `createAccount`, which cannot read the registry itself
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _deviceWalletOwnerKey Owner P256 public key of the device and eSIM wallets
    /// @return wallet address(0) if both are free, else the wallet already holding one of them
    function preCreateAccountValidation(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey
    ) public view returns (address wallet) {
        if(bytes(_deviceUniqueIdentifier).length == 0) revert Errors.EmptyDeviceIdentifier();
        _requireValidOwnerKey(_deviceWalletOwnerKey);

        wallet = registry.uniqueIdentifierToDeviceWallet(_deviceUniqueIdentifier);
        if(wallet != address(0)) {
            return wallet;
        }

        bytes32 keyHash = keccak256(abi.encode(_deviceWalletOwnerKey[0], _deviceWalletOwnerKey[1]));
        wallet = registry.registeredP256Keys(keyHash);
        if(wallet != address(0)) {
            return wallet;
        }
    }

    /// @notice The address createAccount would deploy to for these inputs
    /// @dev The key and identifier are proxy constructor arguments, so changing either, or the
    ///      salt, moves the address.
    /// @param _deviceWalletOwnerKey X,Y co-ordinates of the P256 key owning the wallet
    /// @param _deviceUniqueIdentifier Identifier the device is reached by
    /// @param _salt CREATE2 salt
    /// @return The predicted device wallet address
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

    /// @notice The device wallet logic contract every device wallet currently runs
    /// @return The current implementation address
    function getCurrentDeviceWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
