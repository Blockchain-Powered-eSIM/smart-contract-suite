pragma solidity 0.8.36;

// SPDX-License-Identifier: MIT

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ESIMWallet} from "./ESIMWallet.sol";
import {Registry} from "../Registry.sol";
import {Errors} from "../Errors.sol";

/// @notice Contract for deploying a new eSIM wallet
contract ESIMWalletFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {

    /// @notice Address of the registry contract
    Registry public registry;

    /// @notice Upgradeable beacon that points to the correct eSIM wallet logic contract
    /// @dev    Just updating the eSIM wallet implementation address in this contract resolves
    ///         the issue of manually updating each eSIM wallet proxy with a new implementation
    /// eSIM Wallet proxies (Beacon Proxies) --> beacon (Upgradeable Beacon) --> eSIM wallet implementation (logic contract)
    /**
        eSIM wallet beacon proxy -------
                                        |
        eSIM wallet beacon proxy ------- -------> beacon (Upgradeable beacon) -------> eSIM wallet implementation
                                        |
        eSIM wallet beacon proxy -------
    */
    UpgradeableBeacon public beacon;

    /// @notice Set to true if eSIM wallet address is deployed using the factory, false otherwise
    mapping(address eSIMWalletAddress => bool isDeployed) public isESIMWalletDeployed;

    /// @notice Emitted when the eSIM wallet factory is deployed
    event ESIMWalletFactorydeployed(
        address indexed _upgradeManager,
        address indexed _eSIMWalletImplementation,
        address indexed beacon
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

    /// @dev Locks the implementation contract itself. Without this, anyone can call initialize
    ///      directly on the implementation, own it, and make it deploy a beacon it controls. The
    ///      proxy is unaffected either way, but an owned implementation is a trap for any later
    ///      upgrade that adds an outward call.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize (
        address _eSIMWalletImplementation,
        address _upgradeManager
    ) external initializer {
        if(_upgradeManager == address(0)) revert Errors.ZeroAddress("_upgradeManager");

        // Upgradable beacon for eSIM wallet implementation contract
        // Make the eSIM wallet factory the owner of the beacon
        // Only the _upgradeManager can call the update function to update the beacon
        // with the new implementation (logic) contract
        beacon = new UpgradeableBeacon(_eSIMWalletImplementation, (address(this)));

        emit ESIMWalletFactorydeployed(
            _upgradeManager,
            _eSIMWalletImplementation,
            address(beacon)
        );

        __Ownable2Step_init();
        __Ownable_init(_upgradeManager);
        __UUPSUpgradeable_init();
    }

    /// @notice Allow owner to add registry contract after it's been deployed
    function addRegistryAddress(
        address _registryContractAddress
    ) external onlyOwner returns (address) {
        if(_registryContractAddress == address(0)) revert Errors.ZeroAddress("_registryContractAddress");
        if(address(registry) != address(0)) revert Errors.RegistryAlreadySet(address(registry));

        registry = Registry(_registryContractAddress);
        emit AddedRegistry(address(registry));

        return address(registry);
    }

    /// Function to deploy an eSIM wallet
    /// @dev can only be called by the respective deviceWallet contract
    /// @param _deviceWalletAddress Address of the associated device wallet
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

        bytes memory initialisation = abi.encodeCall(
            ESIMWallet.initialize,
            (address(this), _deviceWalletAddress)
        );

        // CREATE2 reverts with no data when something already sits at the address, which leaves
        // the caller nothing to go on. The salt is its own input, so name it back.
        address predicted = Create2.computeAddress(
            bytes32(_salt),
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), initialisation)))
        );
        if(predicted.code.length > 0) revert Errors.SaltAlreadyUsed(_deviceWalletAddress, _salt);

        // Beacon Proxy deploys all the proxies which interact with the
        // beacon contract to get the implementation (logic) contract address
        // of the eSIM wallet. This way, the eSIM wallet implementation contract update
        // takes affect immediately without having to update each proxy separately
        // msg.value will be sent along with the abi.encodeCall
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

    /// @notice Update the eSIM wallet implementation address in the beacon contract
    /// @dev    Beacon Proxy uses the beacon contract to get the current implementation address
    /// @param  _eSIMWalletImpl Address of the new eSIM wallet implementation contract
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

    /// @dev Owner based upgrades for UUPS eSIM wallet factory
    function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
    {}

    /// @notice Public function to get the current eSIM wallet implementation (logic) contract
    function getCurrentESIMWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
