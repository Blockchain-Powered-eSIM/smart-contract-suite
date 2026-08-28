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
/// @dev A UUPS singleton with two deployment routes. The admin batch route deploys a wallet, its
///      first eSIM wallet and the registry records together. The EntryPoint route, `createAccount`,
///      writes no external storage at all, so a wallet created that way is registered afterwards
///      through `postCreateAccount`. Both land on the same CREATE2 address for the same inputs.
contract DeviceWalletFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Upgradeable beacon that points to correct Device wallet implementation
    /// @dev Every device wallet is a beacon proxy reading its implementation from here, so one
    ///      update moves all of them at once and none can decline it.
    UpgradeableBeacon public beacon;

    /// @notice ERC-4337 EntryPoint singleton passed into every device wallet implementation
    IEntryPoint public entryPoint;

    /// @notice Contract the device wallets verify WebAuthn assertions through
    P256Verifier public verifier;

    ///@notice Registry contract instance
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
    /// @dev Private rather than inline in the modifier, so the check is emitted once instead of at
    ///      every use site. Keep each of these next to the modifier that calls it.
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

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation, own it, and make it deploy a beacon it controls. The
    ///      proxy is unaffected either way, but an owned implementation is a trap for any later
    ///      upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Deploys the beacon and hands ownership of this factory to the upgrade manager
    /// @dev Neither the admin nor the vault is taken here. Both come from the registry, which is
    ///      added afterwards through addRegistryAddress, so admin functions stay closed until that
    ///      is done and every payment reads one address.
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

        // Upgradable beacon for device wallet implementation contract
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

    /// @notice Allow the owner to add the registry contract after it has been deployed
    /// @dev Write-once, and the owner rather than the admin, because the admin is read from the
    ///      registry and there is no admin to check against until this call lands. Matches
    ///      ESIMWalletFactory, which has always gated its own version on the owner.
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

    /// @notice Function to update the device wallet implementation
    /// @dev Moves every device wallet in the protocol at once. Treat any change here as a
    ///      protocol-wide upgrade, since no wallet can decline it.
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

    /// @notice To deploy multiple device wallets at once
    /// @dev Each entry deploys a device wallet, its first eSIM wallet and the registry records in
    ///      one go. ETH left over once the batch has been funded is returned to the caller.
    /// @param _deviceUniqueIdentifiers Array of unique device identifiers for each device wallet
    /// @param _deviceWalletOwnersKey Array of P256 public keys of owners of the respective device wallets
    /// @param _salts Array of CREATE2 salts, one per device wallet
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

        // The lazy route reaches this through the registry and is deploying against its own
        // reservation, so only a direct admin batch is checked. Read once rather than per entry.
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

    /// @notice Records a wallet the EntryPoint deployed through createAccount
    /// @dev Not needed on the admin batch route, which writes the registry itself. Callable by the
    ///      admin directly and by the registry on the lazy deployment path.
    ///
    ///      The wallet was not deployed in this call, so nothing binds the arguments to it. The
    ///      re-derivation does: the key and the identifier are proxy constructor arguments, so an
    ///      address matching the derivation and holding code was deployed here with exactly those.
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

        // Same reason as the batch route: only a direct admin call is claiming a fresh identifier.
        // This is also where the permissionless `createAccount` route gets checked, since that one
        // runs inside ERC-4337 validation and may not read another contract's storage.
        if(msg.sender != address(registry)) {
            registry.requireDeviceIdentifierNotReserved(_deviceUniqueIdentifier);
        }

        address derived = getCounterFactualAddress(
            _deviceWalletOwnerKey,
            _deviceUniqueIdentifier,
            _salt
        );
        if(derived != _deviceWallet) revert Errors.DeviceWalletMismatch(_deviceWallet, derived);

        // The derivation answers for an address whether or not anything stands there, so the code
        // check is what separates a wallet from a slot someone could still deploy into.
        if(_deviceWallet.code.length == 0) revert Errors.DeviceWalletNotDeployed(_deviceWallet);

        // Flag set before the call so a second pass through here cannot reach the registry at all.
        // The registry already rejects a duplicate identifier or key, so this closes the window
        // rather than being the only thing holding it shut.
        deviceWalletInfoAdded[_deviceWallet] = true;
        registry.updateDeviceWalletInfo(_deviceWallet, _deviceUniqueIdentifier, _deviceWalletOwnerKey);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment through the EntryPoint
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a device wallet, returning the existing one if that address already holds it
    /// @dev Called by the EntryPoint during a user operation, so it must not read or write any
    ///      other contract's storage: that is barred by the ERC-4337 validation rules. The registry
    ///      is therefore not consulted here and not written, and `postCreateAccount` records the
    ///      wallet afterwards. Validation the registry would have done happens offchain, through
    ///      `preCreateAccountValidation`.
    ///
    ///      Returning an existing address rather than reverting is what makes
    ///      `entryPoint.getSenderAddress()` keep working once the account has been created.
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

    // ---------------------------------------------------------------------------------------------
    // Ownership and upgrades
    // ---------------------------------------------------------------------------------------------

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and this contract owns the
    ///      beacon, so it is also the only route to updateDeviceWalletImplementation. Renouncing
    ///      would freeze every device wallet on its current logic permanently.
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
    /// @param _deviceUniqueIdentifier Unique device identifier for the device wallet
    /// @param _deviceWalletOwnerKey User's P256 public key (owner of the device wallet and respective eSIM wallets)
    /// @param _salt CREATE2 salt for both wallets
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
        // No access to the device wallet's money: only the owner grants that, with a signed
        // `toggleAccessToFunds`.
        DeviceWallet(payable(deviceWalletAddress)).addESIMWallet(
            eSIMWalletAddress,
            false
        );

        emit DeviceWalletDeployed(deviceWalletAddress, eSIMWalletAddress, _deviceWalletOwnerKey);

        return (Wallets(deviceWalletAddress, eSIMWalletAddress), spentETH);
    }

    /// @notice Deploys a device wallet and writes its registry records, or adopts one that already exists
    /// @dev Returns the ETH actually forwarded to the wallet, which is zero whenever an existing
    ///      wallet is returned instead of a new one being deployed. Callers holding a budget must
    ///      decrement by this value, not by the requested deposit.
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

    /// @notice Rejects a P256 public key that is not a point on the curve
    /// @dev This is the same predicate FCL_ecdsa.ecdsa_verify applies before it does anything else,
    ///      so a key rejected here is one that could never have verified a signature. A wallet
    ///      deployed with such a key is unusable for its whole life and it consumes its device
    ///      identifier and key hash, neither of which the protocol can release.
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

    // ---------------------------------------------------------------------------------------------
    // Addresses and address prediction
    // ---------------------------------------------------------------------------------------------

    /// @notice Admin address of the eSIM wallet project
    /// @dev Held by the registry, which is where it is rotated, so this contract cannot fall
    ///      behind the rest of the protocol after a rotation. Answers address(0) before the
    ///      registry is wired up, which no caller can match, so admin functions stay closed until
    ///      then rather than reverting on a call into address(0).
    function eSIMWalletAdmin() public view returns (address) {
        if(address(registry) == address(0)) return address(0);
        return registry.eSIMWalletAdmin();
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

    /// @notice The address createAccount would deploy to for these inputs
    /// @dev The owner key and the device identifier are part of the proxy's constructor arguments,
    ///      so they are folded into the address alongside the salt. Changing any of them moves it.
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
    function getCurrentDeviceWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
