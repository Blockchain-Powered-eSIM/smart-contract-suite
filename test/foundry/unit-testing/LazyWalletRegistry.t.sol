// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/LazyWalletRegistry.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";

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

    function test_isLazyWalletDeployed() public view {
        bool isDeployed = lazyWalletRegistry.isLazyWalletDeployed(customDeviceUniqueIdentifiers[0]);
        assertEq(isDeployed, false);
    }

    /**
        function switchESIMIdentifierToNewDeviceIdentifier(
            string calldata _eSIMIdentifier,
            string calldata _oldDeviceIdentifier,
            string calldata _newDeviceIdentifier
        ) external onlyESIMWalletAdmin returns (bool) {
     */
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
            eSIMIdentifier,  // eSIM identifier
            oldDeviceIdentifier,   // old device identifier
            newDeviceIdentifier    // new device identifier
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
}
