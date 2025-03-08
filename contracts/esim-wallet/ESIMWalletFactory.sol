pragma solidity 0.8.25;

// SPDX-License-Identifier: MIT

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
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
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @dev Owner based upgrades for UUPS eSIM wallet factory
    function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyOwner
    {}

    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize (
        address _eSIMWalletImplementation,
        address _upgradeManager
    ) external initializer {
        require(_upgradeManager != address(0), "Address cannot be zero");

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
    ) external returns (address) {
        require(msg.sender == owner(), "Only Owner");
        require(_registryContractAddress != address(0), "_registryContractAddress 0");
        require(address(registry) == address(0), "Already added");

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

        // Beacon Proxy deploys all the proxies which interact with the
        // beacon contract to get the implementation (logic) contract address
        // of the eSIM wallet. This way, the eSIM wallet implementation contract update
        // takes affect immediately without having to update each proxy separately
        // msg.value will be sent along with the abi.encodeCall
        address eSIMWalletAddress = address(
            payable(
                new BeaconProxy{salt : bytes32(_salt)}(
                    address(beacon),
                    abi.encodeCall(
                        ESIMWallet.initialize,
                        (address(this), _deviceWalletAddress)
                    )
                )
            )
        );
        isESIMWalletDeployed[eSIMWalletAddress] = true;

        emit ESIMWalletDeployed(eSIMWalletAddress, _deviceWalletAddress, msg.sender);

        return eSIMWalletAddress;
    }

    /// @notice Public function to get the current eSIM wallet implementation (logic) contract
    function getCurrentESIMWalletImplementation() public view returns (address) {
        return beacon.implementation();
    }

    /// @notice Update the eSIM wallet implementation address in the beacon contract
    /// @dev    Beacon Proxy uses the beacon contract to get the current implementation address
    /// @param  _eSIMWalletImpl Address of the new eSIM wallet implementation contract
    function updateESIMWalletImplementation(
        address _eSIMWalletImpl
    ) external onlyOwner returns (address) {
        require(_eSIMWalletImpl != address(0), "_eSIMWalletImpl 0");
        require(_eSIMWalletImpl != getCurrentESIMWalletImplementation(), "Same implementation");

        beacon.upgradeTo(_eSIMWalletImpl);

        emit ESIMWalletImplementationUpdated(getCurrentESIMWalletImplementation());

        return getCurrentESIMWalletImplementation();
    }
}
