// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

import "test/utils/DeployerBase.sol";

/// @notice An account that refuses every payment sent to it
contract ETHRefuser {
    fallback() external payable {
        revert("No ETH accepted");
    }
}

/// @notice Covers the reject arms on `DeviceWallet` that the existing suite reaches past on its way
///         to a happy path.
/// @dev The ETH access and removal behaviour is covered in `DeviceWallet.t.sol`. What is here is
///      the initialiser, the two admin gates, and the arms that refuse an address the wallet has
///      never bound.
contract DeviceWalletGuardsTest is DeployerBase {

    DeviceWallet wallet;
    address eSIMWallet;

    /// @notice Deploys one device wallet with its first eSIM wallet
    function _deployWallet(string memory _identifier, bytes32[2] memory _ownerKey, uint256 _salt) internal {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = _ownerKey;
        salts[0] = _salt;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets =
            deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        wallet = DeviceWallet(payable(wallets[0].deviceWallet));
        eSIMWallet = wallets[0].eSIMWallet;
    }

    /// @notice Deploys a wallet proxy straight against the beacon, so the initialiser arguments can
    ///         be chosen freely rather than being supplied by the factory
    /// @dev The beacon address is an argument rather than read here, because reading it is an
    ///      external call and would be what an expectRevert set up by the caller lands on.
    /// @param _beacon The beacon the proxy reads its logic from
    /// @param _registry The registry address to initialise with
    /// @param _identifier The device identifier to initialise with
    function _initialiseDirectly(address _beacon, address _registry, string memory _identifier) internal {
        new BeaconProxy(
            _beacon,
            abi.encodeCall(DeviceWallet.init, (_registry, pubKey1, _identifier, address(eSIMWalletFactory)))
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice A wallet cannot be initialised without a registry
    /// @dev Every authorisation check on this contract reads the registry, so a zero would leave a
    ///      wallet that reverts on every gated call and can never be pointed at one.
    function test_init_rejectsAZeroRegistry() public {
        address beacon = address(deviceWalletFactory.beacon());

        vm.expectRevert("Registry contract cannot be zero");
        _initialiseDirectly(beacon, address(0), customDeviceUniqueIdentifiers[0]);
    }

    /// @notice A wallet cannot be initialised without a device identifier
    function test_init_rejectsAnEmptyDeviceIdentifier() public {
        address beacon = address(deviceWalletFactory.beacon());

        vm.expectRevert("Device identifier cannot be zero");
        _initialiseDirectly(beacon, address(registry), "");
    }

    // ---------------------------------------------------------------------------------------------
    // Admin gates
    // ---------------------------------------------------------------------------------------------

    /// @notice Only the admin may add another eSIM wallet to a device wallet
    /// @dev The wallet owner cannot do this either. Adding an eSIM is an operator action, because
    ///      the eSIM itself is provisioned offchain.
    function test_deployESIMWallet_rejectsACallerOtherThanTheAdmin() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8001);

        vm.prank(address(wallet));
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        wallet.deployESIMWallet(true, 8002);
    }

    /// @notice An eSIM identifier cannot be written onto a wallet this device does not hold
    /// @dev The check reads the registry rather than this wallet's own map, which is what stops the
    ///      admin naming an eSIM wallet belonging to another device.
    function test_setESIMUniqueIdentifierForAnESIMWallet_rejectsAnUnknownESIMWallet() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8003);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert("Unknown eSIM wallet address");
        wallet.setESIMUniqueIdentifierForAnESIMWallet(user1, "eSIM_unknown");
    }

    // ---------------------------------------------------------------------------------------------
    // Amounts
    // ---------------------------------------------------------------------------------------------

    /// @notice A zero pull is refused rather than emitting a transfer of nothing
    function test_pullETH_rejectsAZeroAmount() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8004);
        vm.deal(address(wallet), 1 ether);

        vm.prank(eSIMWallet);
        vm.expectRevert("_amount 0");
        wallet.pullETH(0);
    }

    /// @notice A zero payment is refused on the direct-to-vault path too
    function test_payETHForDataBundles_rejectsAZeroAmount() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8005);
        vm.deal(address(wallet), 1 ether);

        vm.prank(eSIMWallet);
        vm.expectRevert("_amount 0");
        wallet.payETHForDataBundles(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Addresses the wallet has never bound
    // ---------------------------------------------------------------------------------------------

    /// @notice ETH access cannot be granted to an address the wallet has never bound
    /// @dev Without this an arbitrary address could be given canPullETH, and the pull path checks
    ///      only that flag and the binding it is set alongside.
    function test_toggleAccessToETH_rejectsAnUnknownESIMWallet() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8006);

        vm.prank(address(wallet));
        vm.expectRevert("Unknown _eSIMWalletAddress");
        wallet.toggleAccessToETH(user1, true);

        assertEq(wallet.canPullETH(user1), false, "A refused grant must leave the address without access");
    }

    /// @notice An eSIM wallet this device does not hold cannot be removed from it
    /// @dev Removal writes the registry, so accepting an unknown address would let a device wallet
    ///      put another device's eSIM wallet on standby.
    function test_removeESIMWallet_rejectsAnUnknownESIMWallet() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8007);

        vm.prank(address(wallet));
        vm.expectRevert("Unknown eSIM wallet");
        wallet.removeESIMWallet(user1, false);
    }

    /// @notice The eSIM wallet the device does hold stays bound after a refused removal
    /// @dev Pairs with the test above: the guard has to refuse the unknown address without
    ///      disturbing the binding that is genuinely there.
    function test_removeESIMWallet_refusedRemovalLeavesTheRealBindingIntact() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8008);

        vm.prank(address(wallet));
        vm.expectRevert("Unknown eSIM wallet");
        wallet.removeESIMWallet(user1, false);

        assertEq(wallet.isValidESIMWallet(eSIMWallet), true, "The bound eSIM wallet must still be bound");
        assertEq(
            registry.isESIMWalletValid(eSIMWallet),
            address(wallet),
            "The registry must still associate the eSIM wallet with this device"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // ETH that cannot be delivered
    // ---------------------------------------------------------------------------------------------

    /// @notice A payment the vault refuses takes the whole call down rather than being written off
    /// @dev The low-level call returns false instead of reverting, so without the check the wallet
    ///      would emit nothing, return normally, and report a data bundle as paid for while the ETH
    ///      stayed put. The vault is an EOA today, but it is a settable address and could become a
    ///      contract that reverts on receipt.
    function test_payETHForDataBundles_revertsWhenTheVaultRefusesTheETH() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8009);
        vm.deal(address(wallet), 1 ether);
        vm.etch(vault, address(new ETHRefuser()).code);

        vm.prank(eSIMWallet);
        vm.expectRevert(Errors.FailedToTransfer.selector);
        wallet.payETHForDataBundles(1 ether);

        assertEq(address(wallet).balance, 1 ether, "A refused payment must leave the balance alone");
    }

    /// @notice A removal completes even when the eSIM wallet cannot hand its ETH back
    /// @dev The callback is wrapped in try/catch on purpose. Every eSIM wallet shares one beacon,
    ///      so the logic reached here is not fixed for the life of the protocol, and a wallet whose
    ///      implementation reverts must not be able to pin itself to a device by refusing to leave.
    ///      The bindings are cleared before the callback runs, so the catch arm loses nothing.
    function test_removeESIMWallet_completesWhenTheETHCallbackReverts() public {
        _deployWallet(customDeviceUniqueIdentifiers[0], pubKey1, 8010);
        vm.deal(eSIMWallet, 1 ether);

        vm.mockCallRevert(
            eSIMWallet,
            abi.encodeWithSelector(ESIMWallet.sendETHToDeviceWallet.selector),
            "the wallet refuses to release its ETH"
        );

        vm.expectEmit(false, false, false, false, address(wallet));
        emit NoETHToCallback();

        vm.prank(address(wallet));
        wallet.removeESIMWallet(eSIMWallet, true);

        assertEq(wallet.isValidESIMWallet(eSIMWallet), false, "The eSIM wallet must be unbound from the device");
        assertEq(registry.isESIMWalletValid(eSIMWallet), address(0), "The registry association must be cleared");
    }

    /// @dev Mirrors `DeviceWallet.NoETHToCallback`, so `expectEmit` has a selector to match
    event NoETHToCallback();
}
