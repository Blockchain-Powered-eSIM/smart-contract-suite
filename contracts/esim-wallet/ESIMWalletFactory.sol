pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ESIMWallet} from "./ESIMWallet.sol";
import {Registry} from "../Registry.sol";
import {UpgradeableBeacon} from "../UpgradableBeacon.sol";

error OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();

/// @notice Contract for deploying a new eSIM wallet
contract ESIMWalletFactory is Initializable, OwnableUpgradeable {
    /// @notice Emitted when the eSIM wallet factory is deployed
    event ESIMWalletFactorydeployed(
        address indexed _upgradeManager,
        address indexed _eSIMWalletImplementation,
        address indexed beacon
    );

    /// @notice Emitted when a new eSIM wallet is deployed
    event ESIMWalletDeployed(
        address indexed _eSIMWalletAddress,
        bytes32[2] _owner,
        address indexed _deviceWalletAddress
    );

    /// @notice Address of the registry contract
    Registry public registry;

    /// @notice Implementation at the time of deployment
    address public eSIMWalletImplementation;

    /// @notice Beacon referenced by each deployment of a savETH vault
    address public beacon;

    /// @notice Set to true if eSIM wallet address is deployed using the factory, false otherwise
    mapping(address => bool) public isESIMWalletDeployed;

    modifier onlyRegistryOrDeviceWalletFactoryOrDeviceWallet() {
        bytes32[2] memory walletOwner = registry.isDeviceWalletValid(msg.sender);
        // DeviceWallet is invalid (/doesn't exist) if P256 Public Key's (X, Y) is set to (0, 0)
        if(
            msg.sender != address(registry) &&
            msg.sender != address(registry.deviceWalletFactory()) &&
            walletOwner[0] == bytes32(0) && walletOwner[1] == bytes32(0)
        ) {
            revert OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet();
        }
        _;
    }
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /// @dev Owner based upgrades
    function _authorizeUpgrade(address newImplementation)
    internal
    onlyOwner
    {}

    /// @param _registryContractAddress Address of the registry contract
    /// @param _upgradeManager Admin address responsible for upgrading contracts
    function initialize (address _registryContractAddress, address _upgradeManager) external initializer {
        require(_registryContractAddress != address(0), "Address cannot be zero");
        require(_upgradeManager != address(0), "Address cannot be zero");

        registry = Registry(_registryContractAddress);

        // eSIM wallet implementation (logic) contract during deployment
        eSIMWalletImplementation = address(new ESIMWallet());
        // Upgradable beacon for eSIM wallet implementation contract
        beacon = address(new UpgradeableBeacon(eSIMWalletImplementation, _upgradeManager));

        emit ESIMWalletFactorydeployed(
            _upgradeManager,
            eSIMWalletImplementation,
            beacon
        );

        _transferOwnership(_upgradeManager);
    }

    /// Function to deploy an eSIM wallet
    /// @dev can only be called by the respective deviceWallet contract
    /// @param _owner Owner of the eSIM wallet
    /// @return Address of the newly deployed eSIM wallet
    function deployESIMWallet(
        bytes32[2] memory _owner,
        uint256 _salt
    ) external onlyRegistryOrDeviceWalletFactoryOrDeviceWallet returns (address) {

        // msg.value will be sent along with the abi.encodeCall
        address eSIMWalletAddress = address(
            payable(
                new ERC1967Proxy{salt : bytes32(_salt)}(
                    address(eSIMWalletImplementation),
                    abi.encodeCall(
                        ESIMWallet.initialize, 
                        (address(this), msg.sender, _owner)
                    )
                )
            )
        );
        isESIMWalletDeployed[eSIMWalletAddress] = true;

        emit ESIMWalletDeployed(eSIMWalletAddress, _owner, msg.sender);

        return eSIMWalletAddress;
    }
}
