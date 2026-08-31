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
    /// @dev Every eSIM wallet is a beacon proxy reading its implementation from here, so the
    ///      implementation is replaced once rather than on each proxy:
    ///
    ///      eSIM wallet beacon proxy ─┐
    ///      eSIM wallet beacon proxy ─┼─> beacon ─> eSIM wallet implementation
    ///      eSIM wallet beacon proxy ─┘
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
    /// @dev The first two deploy on behalf of a device wallet during setup. A device wallet reaching
    ///      this directly is constrained further inside `deployESIMWallet`.
    ///
    ///      That third caller is what makes `DeviceWallet.deployESIMWallet`'s admin gate a workflow
    ///      convenience rather than a boundary: an owner can sign an `execute` straight at this
    ///      function and get the same wallet with no admin in the call. Deliberate, since a device
    ///      wallet reaches every external function through `execute` and no check downstream of its
    ///      call can tell which of its owner's intents produced it.
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

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation, own it, and make it deploy a beacon it controls. The
    ///      proxy is unaffected either way, but an owned implementation is a trap for any later
    ///      upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Deploys the beacon and hands ownership of this factory to the upgrade manager
    /// @dev The factory owns the beacon rather than the upgrade manager owning it directly, so the
    ///      only way to move the implementation is `updateESIMWalletImplementation`, which is
    ///      owner gated and emits an event.
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
        // The registry and the device wallet factory deploy on behalf of a device wallet, so they
        // name an arbitrary one. A device wallet calling directly may only name itself: otherwise
        // it can create a wallet owned by another device wallet that never asked for it and that
        // neither _addESIMWallet nor the registry records, and can take the CREATE2 address that
        // owner would get for this salt, leaving its own deployment to fail without a reason.
        if(registry.isDeviceWalletValid(msg.sender) && _deviceWalletAddress != msg.sender) {
            revert Errors.OnlyDeployForSelf();
        }

        // CREATE2 reverts with no data when something already sits at the address, which leaves
        // the caller nothing to go on. The salt is its own input, so name it back.
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
    /// @dev Moves every eSIM wallet in the protocol at once. Treat any change here as a
    ///      protocol-wide upgrade, since no wallet can decline it.
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
    /// @dev The owner is the only caller _authorizeUpgrade accepts, and this contract owns the
    ///      beacon, so it is also the only route to updateESIMWalletImplementation. Renouncing
    ///      would freeze every eSIM wallet on its current logic permanently.
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
    function getCurrentESIMWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
