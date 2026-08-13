// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";

/// @notice The two deployment routes cannot take an identifier the other is already using.
/// @dev A device wallet reaches the protocol either through `DeviceWalletFactory`, driven by the
///      admin, or through `LazyWalletRegistry`, which records what a fiat user bought before they
///      had a wallet. Nothing used to coordinate the two over identifiers, and the ordering hazard
///      that produced was one-way and unrecoverable.
///
///      Taking a reserved device identifier through the ordinary route closed every exit at once:
///      the lazy deployment, the history copy and the switch to another device all refuse an
///      identifier that has a wallet, so every eSIM bound to it was stranded protocol-wide rather
///      than only its history being stuck. Recovering needed an upgrade.
///
///      The eSIM half was quieter. An eSIM wallet's own identifier slot is set once, but nothing
///      compared it against any other wallet, so two live wallets could carry the same identifier
///      and nothing onchain could say which held the eSIM.
///
///      Each test here fails on the code as it stood before these guards. The regression cases,
///      which prove the lazy route can still claim what it reserved, are as much the point as the
///      refusals: a guard that refuses both routes is worse than no guard.
contract IdentifierCollisionTest is DeployerBase {

    /// @notice Records purchases for one device and its eSIM identifiers through the batch entry point
    /// @param _deviceIdentifier Device the purchases belong to
    /// @param _eSIMIdentifiers One eSIM identifier per purchase
    function _populate(string memory _deviceIdentifier, string[] memory _eSIMIdentifiers) internal {
        string[] memory devices = new string[](1);
        devices[0] = _deviceIdentifier;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = _eSIMIdentifiers;

        DataBundleDetails[][] memory details = new DataBundleDetails[][](1);
        details[0] = new DataBundleDetails[](_eSIMIdentifiers.length);
        for(uint256 i = 0; i < _eSIMIdentifiers.length; ++i) {
            details[0][i] = DataBundleDetails("DB_COLLISION", 1 ether);
        }

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, details);
    }

    /// @notice Wraps one identifier in the array `_populate` takes
    /// @param _eSIMIdentifier The identifier
    /// @return A single element array holding it
    function _one(string memory _eSIMIdentifier) internal pure returns (string[] memory) {
        string[] memory eSIMs = new string[](1);
        eSIMs[0] = _eSIMIdentifier;
        return eSIMs;
    }

    /// @notice Deploys one device wallet through the ordinary admin route
    /// @param _identifier Device identifier to deploy under
    /// @param _ownerKey P256 key owning the wallet
    /// @param _salt CREATE2 salt
    /// @return The device wallet and the eSIM wallet deployed alongside it
    function _deployOrdinary(
        string memory _identifier,
        bytes32[2] memory _ownerKey,
        uint256 _salt
    ) internal returns (DeviceWallet, address) {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = _ownerKey;
        salts[0] = _salt;

        vm.prank(eSIMWalletAdmin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers, keys, salts, new uint256[](1)
        )[0];

        return (DeviceWallet(payable(wallet.deviceWallet)), wallet.eSIMWallet);
    }

    // ---------------------------------------------------------------------------------------------
    // Device identifiers
    // ---------------------------------------------------------------------------------------------

    /// @notice An admin batch cannot take a device identifier a fiat user is waiting on
    /// @dev The second half matters as much as the first. Refusing the collision is only worth
    ///      something if the lazy user can still be deployed and still receives what they bought.
    function test_aReservedDeviceIdentifierSurvivesAnAdminDeployment() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        string[] memory eSIMs = new string[](2);
        eSIMs[0] = customESIMUniqueIdentifiers[0][0];
        eSIMs[1] = customESIMUniqueIdentifiers[0][1];
        _populate(device, eSIMs);

        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        identifiers[0] = device;
        keys[0] = pubKey1;
        salts[0] = 9101;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.DeviceIdentifierReservedForLazyWallet.selector, device)
        );
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(device),
            address(0),
            "A refused batch must leave the identifier free"
        );

        vm.prank(eSIMWalletAdmin);
        (address deviceWallet, address[] memory eSIMWallets,) =
            lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 9102, 0, 2);

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(device),
            deviceWallet,
            "The lazy route must still be able to claim its own identifier"
        );

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet(eSIMs[0], 50);

        assertEq(
            MockESIMWallet(payable(eSIMWallets[0])).getTransactionHistory().length,
            1,
            "The fiat user's purchase must reach their wallet"
        );
    }

    /// @notice The EntryPoint route cannot take a reserved identifier either
    /// @dev `createAccount` is permissionless and writes no registry state, so the wallet stands
    ///      there unrecorded until `postCreateAccount` adopts it. That adoption is where this route
    ///      gets checked, because `createAccount` itself runs inside ERC-4337 validation and may
    ///      not read the registry at all.
    function test_postCreateAccount_cannotClaimAReservedDeviceIdentifier() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _populate(device, _one(customESIMUniqueIdentifiers[0][0]));

        vm.prank(user2);
        address ordinaryWallet = address(deviceWalletFactory.createAccount(device, pubKey1, 9201));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.DeviceIdentifierReservedForLazyWallet.selector, device)
        );
        deviceWalletFactory.postCreateAccount(ordinaryWallet, device, pubKey1, 9201);

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(device),
            address(0),
            "A refused adoption must leave the identifier free"
        );
        assertFalse(
            registry.isDeviceWalletValid(ordinaryWallet),
            "A refused adoption must not record the wallet"
        );
    }

    /// @notice The lazy route is not blocked by the reservation it made itself
    /// @dev The most likely way to break this guard is to apply it to every caller. The lazy route
    ///      reaches the same factory function through the registry, so it is told apart by the
    ///      sender, and this is what fails if that ever stops working.
    function test_lazyDeployment_isNotBlockedByItsOwnReservation() public {
        string memory device = customDeviceUniqueIdentifiers[2];
        _populate(device, _one(customESIMUniqueIdentifiers[2][0]));

        vm.prank(eSIMWalletAdmin);
        (address deviceWallet,, uint256 remaining) =
            lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey3, device, 9301, 0, 1);

        assertTrue(deviceWallet != address(0), "The lazy deployment must produce a wallet");
        assertEq(remaining, 0, "Nothing may be left waiting");
        assertTrue(registry.isDeviceWalletValid(deviceWallet), "The wallet must be recorded");
    }

    // ---------------------------------------------------------------------------------------------
    // eSIM identifiers
    // ---------------------------------------------------------------------------------------------

    /// @notice An ordinary wallet cannot be given an eSIM identifier a fiat user is waiting on
    /// @dev The device identifier guard does not cover this. The claiming device is deployed under
    ///      an identifier of its own that nobody reserved, and only the eSIM identifier collides.
    function test_setESIMUniqueIdentifier_cannotClaimAnIdentifierReservedForALazyUser() public {
        string memory reservedESIM = customESIMUniqueIdentifiers[0][0];
        _populate(customDeviceUniqueIdentifiers[0], _one(reservedESIM));

        (DeviceWallet device, address eSIMWallet) =
            _deployOrdinary(customDeviceUniqueIdentifiers[1], pubKey2, 9401);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ESIMIdentifierReservedForLazyWallet.selector, reservedESIM)
        );
        device.setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, reservedESIM);

        assertEq(
            registry.eSIMWalletForIdentifier(reservedESIM),
            address(0),
            "A refused claim must leave the identifier unheld"
        );
        assertEq(
            MockESIMWallet(payable(eSIMWallet)).eSIMUniqueIdentifier(),
            "",
            "A refused claim must leave the wallet's own slot empty"
        );
    }

    /// @notice A lazy record cannot form under an eSIM identifier a wallet already holds
    /// @dev The other direction of the same collision. Purchases recorded here would be unreachable
    ///      for good, since the deployment refuses to hand a second wallet the same identifier.
    function test_populateHistory_refusesAnESIMIdentifierAlreadyLiveOnchain() public {
        string memory eSIMIdentifier = customESIMUniqueIdentifiers[0][0];

        (DeviceWallet device, address eSIMWallet) =
            _deployOrdinary(customDeviceUniqueIdentifiers[1], pubKey2, 9501);
        vm.prank(eSIMWalletAdmin);
        device.setESIMUniqueIdentifierForAnESIMWallet(eSIMWallet, eSIMIdentifier);

        string[] memory devices = new string[](1);
        devices[0] = customDeviceUniqueIdentifiers[0];
        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = _one(eSIMIdentifier);
        DataBundleDetails[][] memory details = new DataBundleDetails[][](1);
        details[0] = new DataBundleDetails[](1);
        details[0][0] = DataBundleDetails("DB_COLLISION", 1 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ESIMIdentifierAlreadyClaimed.selector, eSIMIdentifier, eSIMWallet)
        );
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, details);

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIMIdentifier),
            "",
            "A refused batch must leave the eSIM identifier unbound"
        );
    }

    /// @notice Two eSIM wallets cannot carry the same eSIM identifier
    /// @dev Both wallets here come through the ordinary route, so this is not about the lazy
    ///      registry at all. Each wallet's own slot is set once, which says nothing about the other.
    function test_twoWalletsCannotCarryTheSameESIMIdentifier() public {
        string memory eSIMIdentifier = customESIMUniqueIdentifiers[0][0];

        (DeviceWallet first, address firstESIM) =
            _deployOrdinary(customDeviceUniqueIdentifiers[0], pubKey1, 9601);
        (DeviceWallet second, address secondESIM) =
            _deployOrdinary(customDeviceUniqueIdentifiers[1], pubKey2, 9602);

        vm.prank(eSIMWalletAdmin);
        first.setESIMUniqueIdentifierForAnESIMWallet(firstESIM, eSIMIdentifier);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ESIMIdentifierAlreadyClaimed.selector, eSIMIdentifier, firstESIM)
        );
        second.setESIMUniqueIdentifierForAnESIMWallet(secondESIM, eSIMIdentifier);

        assertEq(
            registry.eSIMWalletForIdentifier(eSIMIdentifier),
            firstESIM,
            "The identifier must still resolve to the wallet that claimed it"
        );
        assertEq(
            MockESIMWallet(payable(secondESIM)).eSIMUniqueIdentifier(),
            "",
            "The refused wallet must keep an empty identifier slot"
        );
    }

    /// @notice The lazy route can claim the eSIM identifier it reserved
    /// @dev The regression guard for the eSIM half, matching the device half above.
    function test_theLazyRouteCanClaimTheIdentifierItReserved() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        string memory eSIMIdentifier = customESIMUniqueIdentifiers[0][0];
        _populate(device, _one(eSIMIdentifier));

        vm.prank(eSIMWalletAdmin);
        (, address[] memory eSIMWallets,) =
            lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 9701, 0, 1);

        assertEq(
            registry.eSIMWalletForIdentifier(eSIMIdentifier),
            eSIMWallets[0],
            "The reserved identifier must resolve to the wallet deployed for it"
        );
        assertEq(
            MockESIMWallet(payable(eSIMWallets[0])).eSIMUniqueIdentifier(),
            eSIMIdentifier,
            "The wallet must carry the identifier it was deployed for"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Who may claim
    // ---------------------------------------------------------------------------------------------

    /// @notice Only a device wallet may claim an eSIM identifier
    /// @dev The claim lives on the registry rather than only on the device wallet, so its own gate
    ///      is what stops anybody else reaching it.
    function test_claimESIMIdentifier_isRefusedFromANonDeviceWallet() public {
        (, address eSIMWallet) = _deployOrdinary(customDeviceUniqueIdentifiers[0], pubKey1, 9801);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        registry.claimESIMIdentifier(customESIMUniqueIdentifiers[0][0], eSIMWallet);
    }

    /// @notice A device wallet cannot claim an identifier for a wallet it does not own
    /// @dev A device wallet can reach the registry directly through `execute`, so the claim cannot
    ///      rely on `DeviceWallet` having checked anything first. Without the owner check here, one
    ///      device wallet could burn identifiers against another's wallets.
    function test_claimESIMIdentifier_isRefusedForAWalletTheCallerDoesNotOwn() public {
        (DeviceWallet attacker,) = _deployOrdinary(customDeviceUniqueIdentifiers[0], pubKey1, 9901);
        (, address victimESIM) = _deployOrdinary(customDeviceUniqueIdentifiers[1], pubKey2, 9902);

        vm.prank(address(attacker));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotTheESIMWalletOwnerOrItsDeviceWallet.selector, victimESIM)
        );
        registry.claimESIMIdentifier(customESIMUniqueIdentifiers[0][0], victimESIM);

        assertEq(
            registry.eSIMWalletForIdentifier(customESIMUniqueIdentifiers[0][0]),
            address(0),
            "A refused claim must leave the identifier unheld"
        );
    }
}
