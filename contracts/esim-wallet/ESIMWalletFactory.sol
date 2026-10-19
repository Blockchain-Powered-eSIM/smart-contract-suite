// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Errors} from "../Errors.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ESIMWallet} from "./ESIMWallet.sol";
import {Registry} from "../Registry.sol";

/// @notice Deploys eSIM wallets and owns the beacon they all point at
/// @dev A UUPS singleton. It owns an `UpgradeableBeacon`, so one call here moves every eSIM wallet
///      in the protocol onto new logic at once. There is no per-wallet opt-out.
contract ESIMWalletFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Address of the registry contract
    Registry public registry;

    /// @notice Upgradeable beacon that points to the correct eSIM wallet logic contract
    /// @dev Every eSIM wallet proxy reads its implementation from here, so one change moves them all.
    UpgradeableBeacon public beacon;

    /// @notice Set to true if eSIM wallet address is deployed using the factory, false otherwise
    mapping(address eSIMWalletAddress => bool isDeployed) public isESIMWalletDeployed;

    /// @notice Emitted when the eSIM wallet factory is deployed
    event ESIMWalletFactoryDeployed(
        address indexed _upgradeManager,
        address indexed _eSIMWalletImplementation,
        address indexed _beacon
    );

    /// @notice Emitted when a new eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        address indexed _deviceWalletAddress,
        address indexed _caller
    );

    /// @notice Emitted when the eSIM wallet implementation is updated
    event ESIMWalletImplementationUpdated(
        address indexed _newImplementation
    );

    /// @notice Emitted when the registry is added to the factory contract
    event AddedRegistry(address indexed registry);

    /// @notice Restricts a call to the registry, the device wallet factory or a known device wallet
    /// @dev A device wallet calling directly may only deploy for itself (checked in the function).
    ///      This also means the admin gate on `DeviceWallet.deployESIMWallet` is not a boundary: an
    ///      owner can `execute` straight here. Deliberate, since nothing here can tell which of the
    ///      owner's signed calls led to this one.
    modifier onlyRegistryOrDeviceWalletFactoryOrDeviceWallet() {
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            !registry.isDeviceWalletValid(msg.sender)
        ) {
            revert Errors.OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();
        }
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Disables initializers on the implementation contract
    /// @dev Otherwise anyone could initialize and own the implementation. The proxy is unaffected,
    ///      but an owned implementation is a trap for a later upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Deploys the beacon and hands ownership of this factory to the upgrade manager
    /// @dev The factory owns the beacon, so the only way to move the implementation is the
    ///      owner-gated `updateESIMWalletImplementation`, which emits an event.
    /// @param _eSIMWalletImplementation First eSIM wallet logic contract the beacon points at
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize (
        address _eSIMWalletImplementation,
        address _upgradeManager
    ) external initializer {
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");

        beacon = new UpgradeableBeacon(_eSIMWalletImplementation, (address(this)));

        emit ESIMWalletFactoryDeployed(
            _upgradeManager,
            _eSIMWalletImplementation,
            address(beacon)
        );

        __Ownable2Step_init();
        __Ownable_init(_upgradeManager);
        __UUPSUpgradeable_init();
    }

    // ---------------------------------------------------------------------------------------------
    // Registry wiring
    // ---------------------------------------------------------------------------------------------

    /// @notice Points the factory at the registry, which is deployed after it
    /// @dev Write-once. Every caller check in this contract reads the registry, so allowing it to
    ///      move would let a later owner redirect all of them at once.
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

    // ---------------------------------------------------------------------------------------------
    // eSIM wallet deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys an eSIM wallet at a deterministic address and binds it to a device wallet
    /// @param _deviceWalletAddress Address of the associated device wallet
    /// @param _salt CREATE2 salt, chosen by the caller and unique per wallet
    /// @return Address of the newly deployed eSIM wallet
    function deployESIMWallet(
        address _deviceWalletAddress,
        uint256 _salt
    ) external onlyRegistryOrDeviceWalletFactoryOrDeviceWallet returns (address) {
        // A device wallet may only deploy for itself. Otherwise it could give another device
        // wallet an unrecorded eSIM wallet and take the CREATE2 address that wallet would get
        // for this salt, making its real deployment fail.
        if(registry.isDeviceWalletValid(msg.sender) && _deviceWalletAddress != msg.sender) {
            revert Errors.OnlyDeployForSelf();
        }

        // CREATE2 on a used address reverts with no data, so name the salt back instead
        address predicted = getCounterFactualAddress(_deviceWalletAddress, _salt);
        if(predicted.code.length > 0) revert Errors.SaltAlreadyUsed(_deviceWalletAddress, _salt);

        bytes memory initialisation = abi.encodeCall(
            ESIMWallet.initialize,
            (address(this), _deviceWalletAddress)
        );

        address eSIMWalletAddress = address(
            payable(
                new BeaconProxy{salt : bytes32(_salt)}(
                    address(beacon),
                    initialisation
                )
            )
        );
        isESIMWalletDeployed[eSIMWalletAddress] = true;

        emit ESIMWalletDeployed(eSIMWalletAddress, _deviceWalletAddress, msg.sender);

        return eSIMWalletAddress;
    }

    /// @notice The address deployESIMWallet would land on for these inputs
    /// @dev Lets a caller probe a salt for occupancy before spending a deployment on it.
    /// @param _deviceWalletAddress Device wallet the eSIM wallet would be bound to
    /// @param _salt CREATE2 salt
    /// @return The predicted eSIM wallet address
    function getCounterFactualAddress(
        address _deviceWalletAddress,
        uint256 _salt
    ) public view returns (address) {
        bytes memory initialisation = abi.encodeCall(
            ESIMWallet.initialize,
            (address(this), _deviceWalletAddress)
        );

        return Create2.computeAddress(
            bytes32(_salt),
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), initialisation)))
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Beacon and ownership
    // ---------------------------------------------------------------------------------------------

    /// @notice Update the eSIM wallet implementation address in the beacon contract
    /// @dev A protocol-wide upgrade: every eSIM wallet moves at once and none can decline.
    /// @param  _eSIMWalletImpl Address of the new eSIM wallet implementation contract
    /// @return The implementation now in force
    function updateESIMWalletImplementation(
        address _eSIMWalletImpl
    ) external onlyOwner returns (address) {
        if(_eSIMWalletImpl == address(0)) revert Errors.ZeroAddress("_eSIMWalletImpl");
        if(_eSIMWalletImpl == getCurrentESIMWalletImplementation()) revert Errors.ImplementationUnchanged(_eSIMWalletImpl);

        beacon.upgradeTo(_eSIMWalletImpl);

        emit ESIMWalletImplementationUpdated(getCurrentESIMWalletImplementation());

        return getCurrentESIMWalletImplementation();
    }

    /// @notice Ownership of this contract is never renounced
    /// @dev The owner is the only one who can upgrade this factory or the beacon, so renouncing
    ///      would freeze every eSIM wallet on its current logic.
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

    /// @notice The eSIM wallet logic contract every eSIM wallet currently runs
    /// @return The current implementation address
    function getCurrentESIMWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
