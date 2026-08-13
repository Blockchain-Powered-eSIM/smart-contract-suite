// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "contracts/CustomStructs.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";

/// @notice An account that refuses every payment sent to it
contract ETHRefuser {
    fallback() external payable {
        revert("No ETH accepted");
    }
}

/// @notice Covers the reject arms on `ESIMWallet` and the one price cap transition the existing
///         suite does not make.
/// @dev The purchase and ownership transfer behaviour is covered in `ESIMWallet.t.sol`.
contract ESIMWalletGuardsTest is DeployerBase {

    uint256 constant REGISTRY_CAP = 1 ether;
    uint256 constant WALLET_CAP = 3 ether;
    uint256 constant PRICE_BETWEEN_THE_TWO = 2 ether;

    DeviceWallet deviceWallet;
    ESIMWallet eSIMWallet;

    /// @notice Deploys one device wallet with its first eSIM wallet
    /// @param _salt The CREATE2 salt to deploy under
    function _deployWallets(uint256 _salt) internal {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = _salt;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets =
            deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        deviceWallet = DeviceWallet(payable(wallets[0].deviceWallet));
        eSIMWallet = ESIMWallet(payable(wallets[0].eSIMWallet));

        // A bind never carries ETH access, so the owner grants it here. The purchases below are
        // funded from the device wallet, which the pull path reaches only once this has run.
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(address(eSIMWallet), true);
    }

    /// @notice Deploys an eSIM wallet proxy straight against the beacon, so the initialiser
    ///         arguments can be chosen freely
    /// @param _beacon The beacon the proxy reads its logic from
    /// @param _factory The factory address to initialise with
    /// @param _deviceWallet The device wallet address to initialise with
    function _initialiseDirectly(address _beacon, address _factory, address _deviceWallet) internal {
        new BeaconProxy(_beacon, abi.encodeCall(ESIMWallet.initialize, (_factory, _deviceWallet)));
    }

    /// @notice Buys a bundle at the given price as the admin
    /// @param _price The price to charge
    function _buyAt(uint256 _price) internal {
        vm.prank(eSIMWalletAdmin);
        eSIMWallet.buyDataBundle(DataBundleDetails("DB_ID_CAP", _price));
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice An eSIM wallet cannot be initialised without its factory
    function test_initialize_rejectsAZeroFactory() public {
        address beacon = address(eSIMWalletFactory.beacon());

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_eSIMWalletFactoryAddress"));
        _initialiseDirectly(beacon, address(0), address(this));
    }

    /// @notice An eSIM wallet cannot be initialised without a device wallet
    /// @dev The device wallet is also made the owner, so a zero here would deploy a wallet nobody
    ///      owns and every gated call would revert.
    function test_initialize_rejectsAZeroDeviceWallet() public {
        address beacon = address(eSIMWalletFactory.beacon());

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_deviceWalletAddress"));
        _initialiseDirectly(beacon, address(eSIMWalletFactory), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Purchase inputs
    // ---------------------------------------------------------------------------------------------

    /// @notice A purchase with no bundle named is refused
    /// @dev The identifier is what the offchain side reconciles the payment against, so an empty
    ///      one records a payment nothing can be matched to.
    function test_buyDataBundle_rejectsAnEmptyDataBundleID() public {
        _deployWallets(9001);
        vm.deal(address(deviceWallet), 1 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyDataBundleID.selector);
        eSIMWallet.buyDataBundle(DataBundleDetails("", 1));
    }

    /// @notice A purchase for nothing is refused
    function test_buyDataBundle_rejectsAZeroPrice() public {
        _deployWallets(9002);
        vm.deal(address(deviceWallet), 1 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.ZeroDataBundlePrice.selector);
        eSIMWallet.buyDataBundle(DataBundleDetails("DB_ID_1", 0));
    }

    // ---------------------------------------------------------------------------------------------
    // Pre-deployment history
    // ---------------------------------------------------------------------------------------------

    /// @notice Only the registry may write the history a wallet carries in from before it existed
    /// @dev The admin is refused as well as an arbitrary caller. History is what the offchain side
    ///      reconciles against, and this write can only happen once.
    function test_populateHistory_rejectsACallerOtherThanTheRegistry() public {
        _deployWallets(9003);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyRegistry.selector);
        eSIMWallet.populateHistory(new DataBundleDetails[](1));
    }

    // ---------------------------------------------------------------------------------------------
    // Price cap
    // ---------------------------------------------------------------------------------------------

    /// @notice Clearing a wallet's own ceiling hands it back to the registry's
    /// @dev Zero means "no ceiling of my own" rather than "a ceiling of zero", because every wallet
    ///      deployed before the cap existed reads zero and has to keep working. This is the
    ///      transition that says so: the same price is accepted under the wallet's own ceiling and
    ///      refused once that ceiling is cleared.
    function test_setDataBundlePriceCap_clearingItReturnsToTheRegistryDefault() public {
        _deployWallets(9004);
        vm.deal(address(deviceWallet), 10 ether);

        vm.prank(upgradeManager);
        registry.setDefaultDataBundlePriceCap(REGISTRY_CAP);
        vm.prank(address(deviceWallet));
        eSIMWallet.setDataBundlePriceCap(WALLET_CAP);

        _buyAt(PRICE_BETWEEN_THE_TWO);

        vm.prank(address(deviceWallet));
        eSIMWallet.setDataBundlePriceCap(0);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, PRICE_BETWEEN_THE_TWO, REGISTRY_CAP)
        );
        eSIMWallet.buyDataBundle(DataBundleDetails("DB_ID_CAP", PRICE_BETWEEN_THE_TWO));
    }

    // ---------------------------------------------------------------------------------------------
    // ETH callback
    // ---------------------------------------------------------------------------------------------

    /// @notice The wallet cannot be asked to send back more ETH than it holds
    /// @dev The device wallet asks for the eSIM wallet's whole balance during removal, so this is
    ///      the arm that catches the balance moving between reading it and spending it.
    function test_sendETHToDeviceWallet_rejectsAnAmountAboveTheBalance() public {
        _deployWallets(9005);
        vm.deal(address(eSIMWallet), 1 ether);

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 1 ether, 1 ether + 1));
        eSIMWallet.sendETHToDeviceWallet(1 ether + 1);

        assertEq(address(eSIMWallet).balance, 1 ether, "A refused callback must leave the balance alone");
    }

    /// @notice A callback the device wallet cannot receive reverts rather than reporting success
    /// @dev The low-level call returns false instead of reverting, so without the check the eSIM
    ///      wallet would return the amount as if it had been sent and the removal on the other side
    ///      would emit `ETHCalledBack` for ETH that never moved. The device wallet declares a
    ///      `receive`, so reaching this needs its code replaced, which is what a beacon upgrade to
    ///      a broken implementation would amount to.
    function test_sendETHToDeviceWallet_revertsWhenTheDeviceWalletRefusesTheETH() public {
        _deployWallets(9006);
        vm.deal(address(eSIMWallet), 1 ether);
        address deviceWalletAddress = address(deviceWallet);
        vm.etch(deviceWalletAddress, address(new ETHRefuser()).code);

        vm.prank(deviceWalletAddress);
        vm.expectRevert(Errors.FailedToTransfer.selector);
        eSIMWallet.sendETHToDeviceWallet(1 ether);

        assertEq(address(eSIMWallet).balance, 1 ether, "A refused callback must leave the balance alone");
    }
}
