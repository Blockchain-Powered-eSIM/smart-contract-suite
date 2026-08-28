// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

contract LazyWalletRegistryTest is DeployerBase {

    /// @dev Batch size large enough to deploy every eSIM the fixture binds in one call. The largest
    ///      device in `customESIMUniqueIdentifiers` holds six, so a request of twenty clamps to the
    ///      whole list and these tests see the pre-batching behaviour.
    uint256 private constant FULL_BATCH = 20;

    function test_batchPopulateHistory_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        vm.stopPrank();
    }

    function test_batchPopulateHistory() public {
        vm.startPrank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        vm.stopPrank();

        DataBundleDetails[] memory storedData = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            customESIMUniqueIdentifiers[0][1]
        );
        assertEq(storedData.length, 1, "DataBundleDetails array length should be 1");
        assertEq(storedData[0].id, "DB_ID_2");
        assertEq(storedData[0].priceUSDCents, 21);
    }

    /// @notice A rotated admin has to reach this registry, which the factory alone does not
    /// @dev The admin address used to be held in two places, and only the factory's copy could be
    ///      rotated, so retiring a key left it holding every function gated on this modifier.
    function test_batchPopulateHistory_followsTheRotatedAdmin() public {
        address retiredAdmin = registry.eSIMWalletAdmin();

        vm.prank(registry.owner());
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        vm.prank(retiredAdmin);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );

        vm.prank(user3);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );

        DataBundleDetails[] memory storedData = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            customESIMUniqueIdentifiers[0][1]
        );
        assertEq(storedData.length, 1, "The rotated admin's write must have landed");
    }

    function test_batchPopulateHistory_duplicateData() public {
        vm.startPrank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            duplicateESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        vm.stopPrank();

        DataBundleDetails[] memory storedData = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            duplicateESIMUniqueIdentifiers[0][1]
        );
        assertEq(storedData.length, 5, "DataBundleDetails array length should be 5");

        string[] memory listOfESIMIdentifiers = lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(customDeviceUniqueIdentifiers[0]);
        for(uint256 i=0; i<listOfESIMIdentifiers.length; ++i) {
            console.log(listOfESIMIdentifiers[i]);
        }
        assertEq(listOfESIMIdentifiers.length, 1);
        assertEq(listOfESIMIdentifiers[0], duplicateESIMUniqueIdentifiers[0][1]);
    }

    /// Populate the history again, to see if the details get updated with new data
    function test_batchPopulateHistory_addNewData() public {
        test_batchPopulateHistory();

        vm.startPrank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        vm.stopPrank();

        DataBundleDetails[] memory storedData = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            customESIMUniqueIdentifiers[0][1]
        );

        assertEq(storedData.length, 2, "DataBundleDetails array length should be 2");
        assertEq(storedData[1].id, "DB_ID_2");
        assertEq(storedData[1].priceUSDCents, 21);
    }

    /// Providing eSIM identifiers that have been associated with a different device identifier
    function test_batchPopulateHistory_incorrectIdentifier() public {
        // First populate the history
        test_batchPopulateHistory();

        string memory movedESIM = modifiedESIMUniqueIdentifiers[0][0];

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ESIMBoundToADifferentDevice.selector,
            movedESIM,
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(movedESIM)
        ));
        lazyWalletRegistry.batchPopulateHistory(
            modifiedDeviceUniqueIdentifiers,
            modifiedESIMUniqueIdentifiers,
            modifiedDataBundleDetails
        );
        vm.stopPrank();
    }

    function test_switchESIMIdentifierToNewDeviceIdentifier_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            "eSIM_0_0",
            "Device_0",
            "Device_1"
        );
        vm.stopPrank();
    }

    function test_switchESIMIdentifierToNewDeviceIdentifier_unregistered() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownESIMIdentifier.selector, "eSIM_0_0"));
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            "eSIM_0_0",
            "Device_0",
            "Device_1"
        );
        vm.stopPrank();
    }

    function test_switchESIMIdentifierToNewDeviceIdentifier() public {
        test_batchPopulateHistory();

        string memory eSIMIdentifier = customESIMUniqueIdentifiers[1][0];
        string memory oldDeviceIdentifier = customDeviceUniqueIdentifiers[1];
        string memory newDeviceIdentifier = customDeviceUniqueIdentifiers[0];

        vm.startPrank(eSIMWalletAdmin);
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            eSIMIdentifier,         // eSIM identifier
            oldDeviceIdentifier,    // old device identifier
            newDeviceIdentifier     // new device identifier
        );
        vm.stopPrank();

        string memory newStoredDeviceIdentifier = lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(
            eSIMIdentifier
        );
        assertEq(newStoredDeviceIdentifier, newDeviceIdentifier);
        
        DataBundleDetails[] memory oldDeviceData = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            oldDeviceIdentifier,
            eSIMIdentifier
        );
        assertEq(oldDeviceData.length, 0, "Data bundles should have been deleted from old device identifier");
        
        DataBundleDetails[] memory newDeviceData = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            newDeviceIdentifier,
            eSIMIdentifier
        );
        assertEq(newDeviceData.length, 1, "Data bundles should have been added to the new device identifier");
        assertEq(newDeviceData[0].id, customDataBundleDetails[1][0].id);
        assertEq(newDeviceData[0].priceUSDCents, customDataBundleDetails[1][0].priceUSDCents);

        string[] memory oldDeviceListOfESIMs = lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(
            oldDeviceIdentifier
        );
        for(uint256 i=0; i<oldDeviceListOfESIMs.length; ++i) {
            assertNotEq(oldDeviceListOfESIMs[i], "");
            assertNotEq(oldDeviceListOfESIMs[i], eSIMIdentifier);
        }

        uint256 occurrence = 0;
        string[] memory newDeviceListOfESIMs = lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(
            newDeviceIdentifier
        );
        for(uint256 i=0; i<newDeviceListOfESIMs.length; ++i) {
            if(keccak256(bytes(newDeviceListOfESIMs[i])) == keccak256(bytes(eSIMIdentifier))) {
                ++occurrence;
            }
        }
        assertEq(occurrence, 1, "eSIM identifier should have added once");
    }

    function test_deployLazyWalletAndSetESIMIdentifier_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            999,
            0,
            FULL_BATCH
        );
        vm.stopPrank();
    }

    function test_deployLazyWalletAndSetESIMIdentifier_withoutESIMIdentifier() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.NoESIMIdentifiersForDevice.selector, customDeviceUniqueIdentifiers[0]));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            999,
            0,
            FULL_BATCH
        );
        vm.stopPrank();
    }

    function test_deployLazyWalletAndSetESIMIdentifier() public {
        test_batchPopulateHistory();

        string memory deviceIdentifier = customDeviceUniqueIdentifiers[0];

        vm.startPrank(eSIMWalletAdmin);
        vm.deal(eSIMWalletAdmin, 10 ether);
        (address deviceWalletAddress, address[] memory eSIMWallets,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier{value: 2 ether}(
            pubKey1,
            deviceIdentifier,
            999,
            2 ether,
            FULL_BATCH
        );
        vm.stopPrank();

        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletAddress));
        assertEq(address(deviceWallet).balance, 2 ether, "The wallet should hold the deposit itself");
        assertEq(
            entryPoint.balanceOf(deviceWalletAddress),
            0,
            "The entry point should hold no deposit for the wallet"
        );

        // Check storage variables in registry
        bytes32[2] memory storedKey = registry.getDeviceWalletToOwner(deviceWalletAddress);
        assertEq(storedKey[0], pubKey1[0], "X co-ordinate should match");
        assertEq(storedKey[1], pubKey1[1], "Y co-ordinate should match");
        assertEq(registry.isDeviceWalletValid(deviceWalletAddress), true, "Device wallet should have been deployed");
        assertEq(registry.uniqueIdentifierToDeviceWallet(deviceIdentifier), deviceWalletAddress, "Device wallet addres should have matched");
        bytes32 keyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));
        assertEq(registry.registeredP256Keys(keyHash), deviceWalletAddress, "P256 key hash should have been tied to the device wallet address");

        // Check storage variables in device wallet
        bytes32[2] memory ownerKey = MockDeviceWallet(payable(deviceWalletAddress)).getOwner();
        assertEq(ownerKey[0], pubKey1[0], "X co-ordinate doesn't match");
        assertEq(ownerKey[1], pubKey1[1], "Y co-ordinate doesn't match");
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");

        for(uint256 i=0; i<eSIMWallets.length; ++i) {
            MockESIMWallet eSIMWallet = MockESIMWallet(payable(eSIMWallets[i]));

            // Check storage variables in registry
            assertEq(registry.isESIMWalletValid(address(eSIMWallet)), deviceWalletAddress, "Device wallet not associated correctly");
            assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet)), false, "ESIM wallet should not be set to standby");

            // Check storage variables in device wallet
            assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet)), true, "ESIMWallet should have been set to valid");
            assertEq(deviceWallet.canPullFunds(address(eSIMWallet)), false, "A lazy deploy must not hand out ETH access");

            // Check storage variables in eSIM wallet
            assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
            assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
            assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
            assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
            assertEq(eSIMWallet.getTransactionHistory().length, 0, "Deployment should not carry any purchase history");
            assertNotEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should not be empty");
        }
    }

    /// @notice The lazy deploy path never leaves ETH behind for the registry to refund
    /// @dev The registry is msg.sender on this path and declares neither a receive nor a
    ///      fallback, so a refund reaching it would revert and take the whole deployment down.
    ///      Nothing refunds today because the identifier is always fresh here, but nothing in the
    ///      type system enforces that. This pins the property so a future change to the call graph
    ///      fails a test instead of silently reopening the path.
    function test_deployLazyWallet_spendsItsWholeDeposit() public {
        test_batchPopulateHistory();

        uint256 registryBalanceBefore = address(registry).balance;

        vm.deal(eSIMWalletAdmin, 3 ether);
        vm.prank(eSIMWalletAdmin);
        (address deviceWalletAddress,,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier{value: 3 ether}(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            998,
            3 ether,
            FULL_BATCH
        );

        assertEq(address(registry).balance, registryBalanceBefore, "the registry must never hold a refund from the deploy");
        assertEq(deviceWalletAddress.balance, 3 ether, "the device wallet must hold the whole deposit");
    }

    /// @notice A funded lazy deployment survives anyone deploying its wallet first.
    /// @dev createAccount is permissionless and the address it lands on depends only on the owner
    ///      key, the device identifier and the salt, all three of which sit in the admin's pending
    ///      transaction. Deploying that address first makes the factory adopt it rather than build
    ///      a new one. The deposit has to reach the adopted wallet: left behind it would be
    ///      refunded to the caller, and on this path the caller is the Registry proxy, which
    ///      declares neither a receive nor a fallback, so the refund would revert and take the
    ///      whole deployment with it.
    function test_deployLazyWalletAndSetESIMIdentifier_fundedDeploySurvivesAFrontRun() public {
        test_batchPopulateHistory();

        string memory deviceIdentifier = customDeviceUniqueIdentifiers[0];
        uint256 salt = 8801;

        // Anyone reading the pending transaction can deploy the same address
        vm.prank(user2);
        address frontRunWallet = address(deviceWalletFactory.createAccount(
            deviceIdentifier,
            pubKey1,
            salt
        ));
        assertEq(
            registry.isDeviceWalletValid(frontRunWallet),
            false,
            "The front-run wallet must hold no registry record"
        );

        vm.deal(eSIMWalletAdmin, 2 ether);
        vm.prank(eSIMWalletAdmin);
        (address deviceWalletAddress,,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier{value: 2 ether}(
            pubKey1,
            deviceIdentifier,
            salt,
            2 ether,
            FULL_BATCH
        );

        assertEq(deviceWalletAddress, frontRunWallet, "The deployment must adopt the front-run wallet");
        assertEq(
            registry.uniqueIdentifierToDeviceWallet(deviceIdentifier),
            frontRunWallet,
            "The identifier must resolve to the adopted wallet"
        );
        assertEq(frontRunWallet.balance, 2 ether, "The adopted wallet must hold the deposit");
        assertEq(address(deviceWalletFactory).balance, 0, "The factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 0, "Nothing should have come back to the admin");
    }

    /// @notice The same front-run leaves an unfunded deployment untouched.
    /// @dev Worth keeping apart from the funded case because a zero deposit never reaches the
    ///      funding call at all, so it covers the adoption itself rather than where the ETH goes.
    function test_deployLazyWalletAndSetESIMIdentifier_unfundedDeploySurvivesAFrontRun() public {
        test_batchPopulateHistory();

        string memory deviceIdentifier = customDeviceUniqueIdentifiers[0];
        uint256 salt = 8802;

        vm.prank(user2);
        address frontRunWallet = address(deviceWalletFactory.createAccount(
            deviceIdentifier,
            pubKey1,
            salt
        ));

        vm.prank(eSIMWalletAdmin);
        (address deviceWalletAddress,,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            deviceIdentifier,
            salt,
            0,
            FULL_BATCH
        );

        assertEq(deviceWalletAddress, frontRunWallet, "The deployment must adopt the front-run wallet");
        assertEq(
            registry.uniqueIdentifierToDeviceWallet(deviceIdentifier),
            frontRunWallet,
            "The identifier must resolve to the adopted wallet"
        );
    }

    function test_batchPopulateHistory_afterDeployment() public {
        test_deployLazyWalletAndSetESIMIdentifier();

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.LazyWalletAlreadyDeployed.selector, customDeviceUniqueIdentifiers[0]));
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        vm.stopPrank();
    }

    /// @notice An eSIM cannot be switched away from a device whose wallet already exists onchain
    /// @dev The deployed eSIM wallet stays owned by the old device wallet, and the switch would
    ///      delete that device's purchase history while nothing reads back into the onchain graph.
    function test_switchESIMIdentifierToNewDeviceIdentifier_revertsWhenOldDeviceDeployed() public {
        test_deployLazyWalletAndSetESIMIdentifier();

        string memory eSIMIdentifier = customESIMUniqueIdentifiers[0][0];
        string memory deployedDeviceIdentifier = customDeviceUniqueIdentifiers[0];
        string memory newDeviceIdentifier = customDeviceUniqueIdentifiers[1];

        assertEq(registry.isDeviceIdentifierAlreadyUsed(deployedDeviceIdentifier), true, "Old device should be deployed");
        assertEq(registry.isDeviceIdentifierAlreadyUsed(newDeviceIdentifier), false, "New device should not be deployed");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.LazyWalletAlreadyDeployed.selector, deployedDeviceIdentifier)
        );
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            eSIMIdentifier,
            deployedDeviceIdentifier,
            newDeviceIdentifier
        );

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIMIdentifier),
            deployedDeviceIdentifier,
            "eSIM should still be associated with the deployed device"
        );
        assertNotEq(
            lazyWalletRegistry.getDeviceIdentifierToESIMDetails(deployedDeviceIdentifier, eSIMIdentifier).length,
            0,
            "Purchase history should not have been deleted from the deployed device"
        );
    }

    /// @notice An eSIM cannot be switched onto a device whose wallet already exists onchain
    /// @dev Deploying that device again is already refused, so the eSIM would never receive a wallet
    ///      under it and its record would be orphaned.
    function test_switchESIMIdentifierToNewDeviceIdentifier_revertsWhenNewDeviceDeployed() public {
        test_deployLazyWalletAndSetESIMIdentifier();

        string memory eSIMIdentifier = customESIMUniqueIdentifiers[1][0];
        string memory oldDeviceIdentifier = customDeviceUniqueIdentifiers[1];
        string memory deployedDeviceIdentifier = customDeviceUniqueIdentifiers[0];

        assertEq(registry.isDeviceIdentifierAlreadyUsed(oldDeviceIdentifier), false, "Old device should not be deployed");
        assertEq(registry.isDeviceIdentifierAlreadyUsed(deployedDeviceIdentifier), true, "New device should be deployed");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.LazyWalletAlreadyDeployed.selector, deployedDeviceIdentifier)
        );
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            eSIMIdentifier,
            oldDeviceIdentifier,
            deployedDeviceIdentifier
        );

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIMIdentifier),
            oldDeviceIdentifier,
            "eSIM should still be associated with the old device"
        );
        assertNotEq(
            lazyWalletRegistry.getDeviceIdentifierToESIMDetails(oldDeviceIdentifier, eSIMIdentifier).length,
            0,
            "Purchase history should not have been moved off the old device"
        );
    }

    /// @notice An identifier nobody has touched is free
    function test_isDeviceIdentifierAlreadyUsed_unregisteredIdentfier() public view {
        bool isUsed = registry.isDeviceIdentifierAlreadyUsed(customDeviceUniqueIdentifiers[0]);
        assertEq(isUsed, false);
    }

    /// @notice Recording purchases against an identifier does not make it used
    function test_isDeviceIdentifierAlreadyUsed_registeredIdentfier() public {
        test_batchPopulateHistory();

        bool isUsed = registry.isDeviceIdentifierAlreadyUsed(customDeviceUniqueIdentifiers[0]);
        assertEq(isUsed, false);
    }

    /// @notice A second round of purchases against the same identifier does not either
    function test_isDeviceIdentifierAlreadyUsed_registeredIdentfier_addNewData() public {
        test_batchPopulateHistory_addNewData();

        bool isUsed = registry.isDeviceIdentifierAlreadyUsed(customDeviceUniqueIdentifiers[0]);
        assertEq(isUsed, false);
    }

    /// @notice Deploying the wallet is what marks the identifier used
    function test_isDeviceIdentifierAlreadyUsed() public {
        test_deployLazyWalletAndSetESIMIdentifier();

        bool isUsed = registry.isDeviceIdentifierAlreadyUsed(customDeviceUniqueIdentifiers[0]);
        assertEq(isUsed, true);
    }

    /// @notice Binds `_count` freshly named eSIM identifiers to one device in a single admin call
    /// @param _device Device identifier to bind against
    /// @param _count Number of eSIM identifiers to create
    /// @param _prefix Prepended to the index so separate calls cannot collide
    function _bindESIMs(string memory _device, uint256 _count, string memory _prefix) internal {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](_count);

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](_count);

        for(uint256 i=0; i<_count; ++i) {
            eSIMs[0][i] = string.concat(_prefix, vm.toString(i));
            bundles[0][i] = bundle("DB_CAP", TEST_PRICE_CENTS);
        }

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }

    /// @notice An eSIM identifier is a UUID v4 in string form. An unbounded one inflates every
    /// keccak in the linear scan the switch path runs over the whole list.
    function test_batchPopulateHistory_rejectsAnOverLongESIMIdentifier() public {
        string memory tooLong = new string(65);

        vm.expectRevert(abi.encodeWithSelector(Errors.IdentifierTooLong.selector, tooLong, 64));
        _bindESIMsNamed(customDeviceUniqueIdentifiers[0], tooLong);

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(tooLong),
            "",
            "The rejected identifier must not have been bound"
        );
    }

    /// @notice The device identifier is bounded on the same insert, for the same reason
    function test_batchPopulateHistory_rejectsAnOverLongDeviceIdentifier() public {
        string memory tooLong = new string(65);

        vm.expectRevert(abi.encodeWithSelector(Errors.IdentifierTooLong.selector, tooLong, 64));
        _bindESIMsNamed(tooLong, "eSIM_long_device");

        assertEq(
            lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(tooLong).length,
            0,
            "The rejected device must hold nothing"
        );
    }

    /// @notice An identifier exactly at the limit is accepted, so the bound is inclusive
    function test_batchPopulateHistory_acceptsAnIdentifierAtTheLimit() public {
        string memory atLimit = new string(64);

        _bindESIMsNamed(customDeviceUniqueIdentifiers[0], atLimit);

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(atLimit),
            customDeviceUniqueIdentifiers[0],
            "An identifier at the limit must bind"
        );
    }

    /// @notice Binds one named eSIM identifier to one named device in a single admin call
    /// @param _device Device identifier to bind against
    /// @param _eSIM eSIM identifier to bind
    /// @notice Gives one eSIM `_purchases` history entries, named so the tail is identifiable.
    function _addPurchases(string memory _device, string memory _eSIM, uint256 _purchases) internal {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](1);
        eSIMs[0][0] = _eSIM;

        for(uint256 i=0; i<_purchases; ++i) {
            DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
            bundles[0] = new DataBundleDetails[](1);
            bundles[0][0] = bundle(bytes32(bytes(string.concat("DB_", vm.toString(i)))), uint64(i + 1));

            vm.prank(eSIMWalletAdmin);
            lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
        }
    }

    /// @notice Deploys the device and hands back the history its first eSIM wallet received.
    function _deployAndReadCarriedHistory(
        string memory _device,
        uint256 _salt
    ) internal returns (DataBundleDetails[] memory) {
        vm.prank(eSIMWalletAdmin);
        (, address[] memory eSIMWallets,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            _device,
            _salt,
            0,
            FULL_BATCH
        );

        return MockESIMWallet(payable(eSIMWallets[0])).getTransactionHistory();
    }

    /// @notice Deployment carries no purchase history, however long the record is
    /// @dev The record used to be trimmed to the last five entries so that a deployment could carry
    ///      it, which lost everything before that. History is copied in afterwards now, so the whole
    ///      record survives and the deployment stops growing with it.
    function test_deployLazyWalletAndSetESIMIdentifier_carriesNoHistory() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _addPurchases(device, "trim_esim", 8);

        DataBundleDetails[] memory carried = _deployAndReadCarriedHistory(device, 4242);

        assertEq(carried.length, 0, "Deployment must leave the wallet's history empty");
        assertEq(
            lazyWalletRegistry.getDeviceIdentifierToESIMDetails(device, "trim_esim").length,
            8,
            "The registry must still hold every entry"
        );
    }

    /// @notice A full batch stays cheap enough that a failed one is worth retrying
    /// @dev The cap is set for retry cost rather than the block limit, so this is the figure that
    ///      justifies it. The deployment chains sit at 30,000,000 at their tightest.
    function test_setHistoryForLazyWallet_staysCheapAtAFullBatch() public {
        _lazyDeployOneESIM("batch_esim", 50, 5110);

        vm.prank(eSIMWalletAdmin);
        uint256 gasBefore = gasleft();
        lazyWalletRegistry.setHistoryForLazyWallet("batch_esim", 50);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 4_000_000, "A full batch must stay well inside a block");
    }

    /// @notice The device wallet works the moment the first batch lands, with eSIMs still outstanding
    /// @dev This is the decision the batching rests on. Holding the device inert until the last eSIM
    ///      arrived would mean one dropped transaction leaves the user with nothing rather than with
    ///      most of what they bought, so the wallets that exist have to be complete on their own.
    function test_deployLazyWalletAndSetESIMIdentifier_leavesTheDeviceUsableMidDeployment() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 5, "partial_");

        vm.prank(eSIMWalletAdmin);
        (address deviceWalletAddress, address[] memory eSIMWallets, uint256 remaining) =
            lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 6001, 0, 2);

        assertEq(eSIMWallets.length, 2, "The first batch must deploy exactly what it was asked for");
        assertEq(remaining, 3, "Three eSIM wallets must still be outstanding");
        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), 2, "The cursor must sit at two");

        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletAddress));
        assertEq(registry.isDeviceWalletValid(deviceWalletAddress), true, "The device wallet must be live");

        for(uint256 i=0; i<eSIMWallets.length; ++i) {
            MockESIMWallet eSIMWallet = MockESIMWallet(payable(eSIMWallets[i]));

            assertEq(registry.isESIMWalletValid(eSIMWallets[i]), deviceWalletAddress, "Each wallet must be bound");
            assertEq(deviceWallet.isValidESIMWallet(eSIMWallets[i]), true, "Each wallet must be valid on the device");
            assertEq(deviceWallet.canPullFunds(eSIMWallets[i]), false, "No wallet may arrive with ETH access");
            assertEq(
                eSIMWallet.eSIMUniqueIdentifier(),
                string.concat("partial_", vm.toString(i)),
                "Each wallet must carry its own identifier"
            );
        }

        // The wallets that do not exist yet hold nothing, rather than resolving to something wrong
        assertEq(
            lazyWalletRegistry.lazyDeployedESIMWallet("partial_2"),
            address(0),
            "An undeployed identifier must resolve to nothing"
        );
    }

    /// @notice An eSIM whose wallet exists can be given its history before the rest are deployed
    /// @dev The history cursor is per eSIM and the deploy cursor is per device, so the two do not
    ///      wait on each other. A user whose first eSIM landed sees its purchases straight away.
    function test_setHistoryForLazyWallet_worksWhileTheDeviceIsStillDeploying() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 4, "midflight_");
        _addPurchases(device, "midflight_0", 3);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 6101, 0, 1);

        vm.prank(eSIMWalletAdmin);
        (uint256 copied, uint256 remaining) = lazyWalletRegistry.setHistoryForLazyWallet("midflight_0", 50);

        assertEq(copied, 4, "Every entry the eSIM holds must be copied");
        assertEq(remaining, 0, "Nothing must be left waiting");
        assertEq(
            MockESIMWallet(payable(lazyWalletRegistry.lazyDeployedESIMWallet("midflight_0")))
                .getTransactionHistory().length,
            4,
            "The wallet must hold its history while its siblings are still undeployed"
        );

        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), 1, "The deploy cursor must not have moved");
    }

    /// @notice An eSIM cannot be moved to another device while the rest are still being deployed
    /// @dev Switching mid-deployment would take an identifier out from under a cursor walking the
    ///      list, leaving a wallet bound to a device whose history record no longer names it. The
    ///      first batch creates the device wallet, which is what makes the existing guard cover the
    ///      whole window rather than only the moment the last batch lands.
    function test_switchESIMIdentifierToNewDeviceIdentifier_refusedWhileTheDeviceIsStillDeploying() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 4, "locked_");

        vm.prank(eSIMWalletAdmin);
        (,, uint256 remaining) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 6201, 0, 1);
        assertEq(remaining, 3, "The device must still be mid-deployment");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.LazyWalletAlreadyDeployed.selector, device));
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier("locked_3", device, "some_other_device");
    }

    /// @notice New purchase history cannot be recorded while the rest are still being deployed
    /// @dev The cursor walks the identifier list, so an identifier appended after the first batch
    ///      would either be skipped or shift the positions of the ones behind it.
    function test_batchPopulateHistory_refusedWhileTheDeviceIsStillDeploying() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 4, "frozen_");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 6301, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.LazyWalletAlreadyDeployed.selector, device));
        _bindESIMs(device, 1, "appended_");
    }

    /// @notice The continuation refuses once every eSIM has a wallet
    /// @dev The terminal condition is a revert rather than a quiet no-op, so a caller looping until
    ///      it is done stops on something it can read instead of spinning.
    function test_deployMoreESIMWalletsForLazyDevice_revertsOnceEveryWalletExists() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 3, "done_");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 6401, 0, 3);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.AllESIMWalletsDeployed.selector, device));
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 1);
    }

    /// @notice A batch larger than what is left deploys only what is left and says so
    /// @dev Clamping is right here and refusing is right for a request above the cap. The caller
    ///      asked for more wallets than the device has, and the return value reports what it got.
    function test_deployMoreESIMWalletsForLazyDevice_clampsToWhatIsLeft() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 5, "clamp_");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 6501, 0, 3);

        vm.prank(eSIMWalletAdmin);
        (address[] memory eSIMWallets, uint256 remaining) =
            lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 20);

        assertEq(eSIMWallets.length, 2, "Only the outstanding wallets may be deployed");
        assertEq(remaining, 0, "Nothing must be left waiting");
        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), 5, "The cursor must reach the list length");
    }

    /// @notice A device whose first batch never ran cannot be continued
    /// @dev The marker is the deploy cursor and not the registry's device wallet record. The record
    ///      would read true for a device the ordinary route deployed, and handing that device a
    ///      fiat user's eSIM wallets would hand it their purchase history with them. That collision
    ///      is refused at the door now, so the two can no longer disagree, and the cursor is still
    ///      what this reads.
    function test_deployMoreESIMWalletsForLazyDevice_refusesADeviceWithNoFirstBatch() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 3, "hijack_");

        assertEq(registry.uniqueIdentifierToDeviceWallet(device), address(0), "No wallet may exist yet");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.LazyWalletNotDeployed.selector, device));
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 1);
    }

    /// @notice A full batch of eSIM wallets stays cheap enough that a failed one is worth retrying
    /// @dev The cap is set for retry cost rather than the block limit, so this is the figure that
    ///      justifies it. The deployment chains sit at 30,000,000 at their tightest.
    ///
    ///      The real cost is 10,025,567, about 500,000 per eSIM wallet, and the bound sits above it
    ///      so that `forge coverage --ir-minimum` passes too, where instrumentation adds about a
    ///      fifth. It still fails on a regression that stops enforcing the cap, which would put the
    ///      whole forty five eSIM deployment below back into one call at roughly 22,500,000.
    function test_deployLazyWalletAndSetESIMIdentifier_staysCheapAtAFullBatch() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 20, "full_batch_");

        vm.prank(eSIMWalletAdmin);
        uint256 gasBefore = gasleft();
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, device, 4245, 0, 20);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 14_000_000, "A full batch must stay well inside a block");
    }

    /// @notice A device with more eSIMs than one block could ever carry still deploys, over batches
    /// @dev Forty five is past the point where the old single-transaction deployment stopped fitting
    ///      in a 30,000,000 block, which is the whole reason the batching exists. Every batch is
    ///      asserted individually so a regression that quietly makes one enormous call shows up as a
    ///      gas failure rather than as a pass. Measured at 9,278,767 then 8,693,555 then 2,183,738.
    function test_deployLazyWalletAndSetESIMIdentifier_reachesFortyFiveESIMsOverBatches() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 45, "worst_");

        vm.prank(eSIMWalletAdmin);
        uint256 gasBefore = gasleft();
        (address deviceWallet,, uint256 remaining) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            4245,
            0,
            20
        );
        assertLt(gasBefore - gasleft(), 14_000_000, "The first batch must fit inside a block");
        assertEq(remaining, 25, "Twenty five eSIM wallets must be left after the first batch");

        while(remaining > 0) {
            vm.prank(eSIMWalletAdmin);
            gasBefore = gasleft();
            (, remaining) = lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 20);
            assertLt(gasBefore - gasleft(), 14_000_000, "Every later batch must fit inside a block");
        }

        assertEq(lazyWalletRegistry.eSIMWalletsDeployed(device), 45, "Every eSIM must end up with a wallet");
        _assertEveryESIMHasItsOwnWallet(45, deviceWallet);
    }

    /// @notice Every identifier resolves to a distinct wallet the device wallet owns
    /// @dev Distinctness is the part worth asserting. A salt that restarted rather than continuing
    ///      between batches would either revert on a used address or, if the guard were ever lost,
    ///      hand two identifiers the same wallet.
    function _assertEveryESIMHasItsOwnWallet(
        uint256 _count,
        address _deviceWallet
    ) private view {
        address[] memory seen = new address[](_count);

        for(uint256 i=0; i<_count; ++i) {
            string memory eSIM = string.concat("worst_", vm.toString(i));
            address eSIMWallet = lazyWalletRegistry.lazyDeployedESIMWallet(eSIM);

            assertNotEq(eSIMWallet, address(0), "Every identifier must resolve to a wallet");
            assertEq(
                registry.isESIMWalletValid(eSIMWallet),
                _deviceWallet,
                "Every wallet must be bound to the device wallet"
            );
            assertEq(
                MockESIMWallet(payable(eSIMWallet)).eSIMUniqueIdentifier(),
                eSIM,
                "Every wallet must carry its own identifier"
            );

            for(uint256 j=0; j<i; ++j) {
                assertNotEq(seen[j], eSIMWallet, "No two identifiers may share a wallet");
            }
            seen[i] = eSIMWallet;
        }
    }

    /// @notice Binds one eSIM with `_purchases` entries, deploys the device, returns its wallet.
    function _lazyDeployOneESIM(
        string memory _eSIM,
        uint256 _purchases,
        uint256 _salt
    ) internal returns (MockESIMWallet) {
        string memory device = customDeviceUniqueIdentifiers[0];
        _addPurchases(device, _eSIM, _purchases);

        vm.prank(eSIMWalletAdmin);
        (, address[] memory eSIMWallets,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            _salt,
            0,
            FULL_BATCH
        );

        return MockESIMWallet(payable(eSIMWallets[0]));
    }

    /// @notice The whole stored history reaches the wallet, in order, across as many calls as it takes
    /// @dev Deployment carries none of it, so this path is the only thing that puts a lazy user's
    ///      purchases in front of them. Entries arriving out of order or short would misstate what
    ///      they spent.
    function test_setHistoryForLazyWallet_copiesTheWholeHistoryInOrder() public {
        MockESIMWallet eSIMWallet = _lazyDeployOneESIM("copy_esim", 7, 5101);

        vm.prank(eSIMWalletAdmin);
        (uint256 firstCopied, uint256 firstRemaining) = lazyWalletRegistry.setHistoryForLazyWallet("copy_esim", 5);
        assertEq(firstCopied, 5, "The first call must copy a full batch");
        assertEq(firstRemaining, 2, "Two entries must be left over");

        vm.prank(eSIMWalletAdmin);
        (uint256 secondCopied, uint256 secondRemaining) = lazyWalletRegistry.setHistoryForLazyWallet("copy_esim", 5);
        assertEq(secondCopied, 2, "The second call must copy only what is left");
        assertEq(secondRemaining, 0, "Nothing must be left after the second call");

        DataBundleDetails[] memory stored = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            "copy_esim"
        );
        DataBundleDetails[] memory inWallet = eSIMWallet.getTransactionHistory();

        assertEq(inWallet.length, stored.length, "The wallet must end up holding every stored entry");
        for(uint256 i=0; i<stored.length; ++i) {
            assertEq(inWallet[i].id, stored[i].id);
            assertEq(inWallet[i].priceUSDCents, stored[i].priceUSDCents);
        }
        assertEq(lazyWalletRegistry.historyEntriesCopied("copy_esim"), 7, "The cursor must sit at the end");
    }

    /// @notice A call with nothing left to copy reverts rather than passing quietly
    /// @dev A caller loops on this until it stops, so the end of the history has to be something it
    ///      can read. Succeeding as a no-op would spin instead.
    function test_setHistoryForLazyWallet_revertsOnceTheHistoryIsCopied() public {
        _lazyDeployOneESIM("done_esim", 3, 5102);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet("done_esim", 50);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.HistoryAlreadyCopied.selector, "done_esim"));
        lazyWalletRegistry.setHistoryForLazyWallet("done_esim", 50);
    }

    /// @notice A batch larger than the per-call cap is refused, not silently trimmed
    /// @dev Trimming would leave the caller believing it wrote more than it did, and its own idea
    ///      of where it had reached would then run ahead of the cursor.
    function test_setHistoryForLazyWallet_rejectsABatchAboveTheCap() public {
        _lazyDeployOneESIM("cap_esim", 3, 5103);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyHistoryEntries.selector, 51, 50));
        lazyWalletRegistry.setHistoryForLazyWallet("cap_esim", 51);
    }

    /// @notice A batch of zero is refused too, since it could only ever be a caller mistake
    function test_setHistoryForLazyWallet_rejectsAnEmptyBatch() public {
        _lazyDeployOneESIM("zero_esim", 3, 5104);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyHistoryEntries.selector, 0, 50));
        lazyWalletRegistry.setHistoryForLazyWallet("zero_esim", 0);
    }

    /// @notice An eSIM with no wallet deployed through this registry has nowhere to send history
    function test_setHistoryForLazyWallet_rejectsAnESIMItNeverDeployed() public {
        _addPurchases(customDeviceUniqueIdentifiers[0], "undeployed_esim", 3);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.ESIMWalletNotLazyDeployed.selector, "undeployed_esim"));
        lazyWalletRegistry.setHistoryForLazyWallet("undeployed_esim", 50);
    }

    /// @notice History reaches the wallet this registry deployed, not one that claims the same identifier
    /// @dev Nothing makes an eSIM identifier unique across eSIM wallets, so a wallet deployed
    ///      through the ordinary route can set itself a lazy user's identifier. Matching on the
    ///      identifier alone would hand it their purchase history and leave them with none, and the
    ///      identifier comes from an ICCID rather than from anything secret.
    function test_setHistoryForLazyWallet_ignoresAWalletClaimingTheSameIdentifier() public {
        MockESIMWallet victim = _lazyDeployOneESIM("victim_esim", 4, 5105);

        string[] memory deviceIdentifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        deviceIdentifiers[0] = customDeviceUniqueIdentifiers[1];
        keys[0] = listOfOwnerKeys[1];
        salts[0] = 5106;

        vm.prank(eSIMWalletAdmin);
        Wallets memory impostorWallets = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceIdentifiers,
            keys,
            salts,
            new uint256[](1)
        )[0];

        MockESIMWallet impostor = MockESIMWallet(payable(impostorWallets.eSIMWallet));

        // Its owner cannot write the slot, and the admin route refuses a claimed identifier, so
        // there is no way for a second wallet to answer to the same string.
        vm.prank(impostorWallets.deviceWallet);
        vm.expectRevert(Errors.OnlyRegistry.selector);
        impostor.setESIMUniqueIdentifier("victim_esim");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ESIMIdentifierAlreadyClaimed.selector,
                "victim_esim",
                address(victim)
            )
        );
        registry.assignESIMIdentifier(address(impostor), "victim_esim");

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet("victim_esim", 50);

        assertEq(victim.getTransactionHistory().length, 4, "The lazy wallet must receive its own history");
        assertEq(impostor.getTransactionHistory().length, 0, "The claiming wallet must receive nothing");
    }

    /// @notice A wallet handed to another device wallet still receives the rest of its history
    /// @dev The copy is tied to the wallet address recorded at deployment rather than to whichever
    ///      device holds it, so moving it mid-copy cannot strand the entries still waiting.
    function test_setHistoryForLazyWallet_survivesAnOwnershipTransfer() public {
        MockESIMWallet eSIMWallet = _lazyDeployOneESIM("moved_esim", 6, 5107);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet("moved_esim", 2);

        string[] memory deviceIdentifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        deviceIdentifiers[0] = customDeviceUniqueIdentifiers[1];
        keys[0] = listOfOwnerKeys[1];
        salts[0] = 5108;

        vm.prank(eSIMWalletAdmin);
        Wallets memory newHome = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceIdentifiers,
            keys,
            salts,
            new uint256[](1)
        )[0];

        vm.prank(eSIMWallet.owner());
        eSIMWallet.requestTransferOwnership(newHome.deviceWallet);
        vm.prank(newHome.deviceWallet);
        eSIMWallet.acceptOwnershipTransfer();

        vm.prank(eSIMWalletAdmin);
        (, uint256 remaining) = lazyWalletRegistry.setHistoryForLazyWallet("moved_esim", 50);

        assertEq(remaining, 0, "The rest of the history must still be copyable");
        assertEq(eSIMWallet.getTransactionHistory().length, 6, "The moved wallet must hold its whole history");
    }

    /// @notice Only the admin may copy history
    function test_setHistoryForLazyWallet_rejectsACallerOtherThanTheAdmin() public {
        _lazyDeployOneESIM("admin_esim", 3, 5109);

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.setHistoryForLazyWallet("admin_esim", 50);
    }

    function _bindESIMsNamed(string memory _device, string memory _eSIM) internal {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](1);
        eSIMs[0][0] = _eSIM;

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](1);
        bundles[0][0] = bundle("DB_LEN", TEST_PRICE_CENTS);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }
}
