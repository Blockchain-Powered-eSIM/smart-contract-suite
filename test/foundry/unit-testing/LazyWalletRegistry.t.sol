// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

contract LazyWalletRegistryTest is DeployerBase {

    function test_batchPopulateHistory_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert("Only eSIM wallet admin");
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
        assertEq(storedData[0].dataBundleID, "DB_ID_2");
        assertEq(storedData[0].dataBundlePrice, 21);
    }

    /// @notice A rotated admin has to reach this registry, which the factory alone does not
    /// @dev The admin address used to be held in two places, and only the factory's copy could be
    ///      rotated, so retiring a key left it holding every function gated on this modifier.
    function test_batchPopulateHistory_followsTheRotatedAdmin() public {
        address retiredAdmin = registry.eSIMWalletAdmin();

        vm.prank(retiredAdmin);
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        vm.prank(retiredAdmin);
        vm.expectRevert("Only eSIM wallet admin");
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
        assertEq(storedData[1].dataBundleID, "DB_ID_2");
        assertEq(storedData[1].dataBundlePrice, 21);
    }

    /// Providing eSIM identifiers that have been associated with a different device identifier
    function test_batchPopulateHistory_incorrectIdentifier() public {
        // First populate the history
        test_batchPopulateHistory();

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert();
        lazyWalletRegistry.batchPopulateHistory(
            modifiedDeviceUniqueIdentifiers,
            modifiedESIMUniqueIdentifiers,
            modifiedDataBundleDetails
        );
        vm.stopPrank();
    }

    function test_switchESIMIdentifierToNewDeviceIdentifier_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert("Only eSIM wallet admin");
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            "eSIM_0_0",
            "Device_0",
            "Device_1"
        );
        vm.stopPrank();
    }

    function test_switchESIMIdentifierToNewDeviceIdentifier_unregistered() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Unknown _eSIMIdentifier");
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
        assertEq(newDeviceData[0].dataBundleID, customDataBundleDetails[1][0].dataBundleID);
        assertEq(newDeviceData[0].dataBundlePrice, customDataBundleDetails[1][0].dataBundlePrice);

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
        vm.expectRevert("Only eSIM wallet admin");
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            999,
            0
        );
        vm.stopPrank();
    }

    function test_deployLazyWalletAndSetESIMIdentifier_withoutESIMIdentifier() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("No eSIM identifier found");
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            999,
            0
        );
        vm.stopPrank();
    }

    function test_deployLazyWalletAndSetESIMIdentifier() public {
        test_batchPopulateHistory();

        string memory deviceIdentifier = customDeviceUniqueIdentifiers[0];

        vm.startPrank(eSIMWalletAdmin);
        vm.deal(eSIMWalletAdmin, 10 ether);
        (address deviceWalletAddress, address[] memory eSIMWallets) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier{value: 2 ether}(
            pubKey1,
            deviceIdentifier,
            999,
            2 ether
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
            assertEq(deviceWallet.canPullETH(address(eSIMWallet)), true, "ESIMWallet should be able to pull ETH");

            // Check storage variables in eSIM wallet
            assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
            assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
            assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
            assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
            assertNotEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should not have been empty");
            assertNotEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should not be empty");
        }
    }

    function test_batchPopulateHistory_afterDeployment() public {
        test_deployLazyWalletAndSetESIMIdentifier();

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Already deployed");
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

        assertEq(lazyWalletRegistry.isLazyWalletDeployed(deployedDeviceIdentifier), true, "Old device should be deployed");
        assertEq(lazyWalletRegistry.isLazyWalletDeployed(newDeviceIdentifier), false, "New device should not be deployed");

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

        assertEq(lazyWalletRegistry.isLazyWalletDeployed(oldDeviceIdentifier), false, "Old device should not be deployed");
        assertEq(lazyWalletRegistry.isLazyWalletDeployed(deployedDeviceIdentifier), true, "New device should be deployed");

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

    function test_isLazyWalletDeployed_unregisteredIdentfier() public view {
        bool isDeployed = lazyWalletRegistry.isLazyWalletDeployed(customDeviceUniqueIdentifiers[0]);
        assertEq(isDeployed, false);
    }

    function test_isLazyWalletDeployed_registeredIdentfier() public {
        test_batchPopulateHistory();

        bool isDeployed = lazyWalletRegistry.isLazyWalletDeployed(customDeviceUniqueIdentifiers[0]);
        assertEq(isDeployed, false);
    }

    function test_isLazyWalletDeployed_registeredIdentfier_addNewData() public {
        test_batchPopulateHistory_addNewData();

        bool isDeployed = lazyWalletRegistry.isLazyWalletDeployed(customDeviceUniqueIdentifiers[0]);
        assertEq(isDeployed, false);
    }

    function test_isLazyWalletDeployed() public {
        test_deployLazyWalletAndSetESIMIdentifier();

        bool isDeployed = lazyWalletRegistry.isLazyWalletDeployed(customDeviceUniqueIdentifiers[0]);
        assertEq(isDeployed, true);
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
            bundles[0][i] = DataBundleDetails("DB_CAP", 1);
        }

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }

    /// @notice A device that grows without limit eventually cannot be deployed at all, because
    /// deployLazyWalletAndSetESIMIdentifier deploys one eSIM wallet per identifier in a single
    /// transaction. Its identifiers stay bound to it, so nothing releases them either.
    function test_batchPopulateHistory_capsESIMIdentifiersPerDevice() public {
        _bindESIMs(customDeviceUniqueIdentifiers[0], 30, "capped_");

        assertEq(
            lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(customDeviceUniqueIdentifiers[0]).length,
            30,
            "The device must hold exactly the cap before the next insert"
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.TooManyESIMsForDevice.selector, customDeviceUniqueIdentifiers[0], 30)
        );
        _bindESIMs(customDeviceUniqueIdentifiers[0], 1, "overflow_");

        assertEq(
            lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(customDeviceUniqueIdentifiers[0]).length,
            30,
            "The rejected insert must leave the list at the cap"
        );
    }

    /// @notice A purchase against an eSIM the device already holds is not a new binding, so it
    /// must keep working once the device sits at the cap.
    function test_batchPopulateHistory_allowsMorePurchasesAtTheCap() public {
        _bindESIMs(customDeviceUniqueIdentifiers[0], 30, "capped_");
        _bindESIMs(customDeviceUniqueIdentifiers[0], 30, "capped_");

        DataBundleDetails[] memory stored = lazyWalletRegistry.getDeviceIdentifierToESIMDetails(
            customDeviceUniqueIdentifiers[0],
            "capped_0"
        );
        assertEq(stored.length, 2, "The second purchase against an existing eSIM must be recorded");
    }

    /// @notice The switch path grows the receiving device's list too, so it has to honour the same
    /// cap or a device can be filled past it one identifier at a time.
    function test_switchESIMIdentifierToNewDeviceIdentifier_honoursTheCap() public {
        _bindESIMs(customDeviceUniqueIdentifiers[0], 30, "capped_");
        _bindESIMs(customDeviceUniqueIdentifiers[1], 1, "mover_");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.TooManyESIMsForDevice.selector, customDeviceUniqueIdentifiers[0], 30)
        );
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            "mover_0",
            customDeviceUniqueIdentifiers[1],
            customDeviceUniqueIdentifiers[0]
        );

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier("mover_0"),
            customDeviceUniqueIdentifiers[1],
            "The rejected switch must leave the eSIM on its original device"
        );
    }

    /// @notice The cap bounds the linear scan the switch runs over the source device's whole list,
    /// and moving an eSIM off a full device has to keep working, since that is how a device at the
    /// cap makes room. Worst case: the identifier being moved sits last, so the scan runs the
    /// whole length.
    function test_switchESIMIdentifierToNewDeviceIdentifier_atTheCap() public {
        _bindESIMs(customDeviceUniqueIdentifiers[0], 30, "capped_");

        uint256 gasBefore = gasleft();
        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            "capped_29",
            customDeviceUniqueIdentifiers[0],
            customDeviceUniqueIdentifiers[1]
        );
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 500_000, "A switch off a device at the cap must stay well inside a block");
        assertEq(
            lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(customDeviceUniqueIdentifiers[0]).length,
            29,
            "The source device must have released the identifier"
        );
        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier("capped_29"),
            customDeviceUniqueIdentifiers[1],
            "The identifier must now name the receiving device"
        );
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
    function _bindESIMsNamed(string memory _device, string memory _eSIM) internal {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](1);
        eSIMs[0][0] = _eSIM;

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](1);
        bundles[0][0] = DataBundleDetails("DB_LEN", 1);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }
}
