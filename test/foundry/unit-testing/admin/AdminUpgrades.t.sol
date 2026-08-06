// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Registry} from "contracts/Registry.sol";
import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";

import "test/utils/AdminBase.sol";
import {MockDeviceWalletV2} from "test/utils/mocks/MockDeviceWalletV2.sol";
import {MockESIMWalletV2} from "test/utils/mocks/MockESIMWalletV2.sol";

/// @notice Every upgrade the admin contract is the authority for, driven through it.
/// @dev Two layers move here and they move differently. The four singletons are UUPS proxies the
///      admin owns outright. The wallets are beacon proxies whose beacons belong to the two
///      factories, so a wallet upgrade is a factory call and reaches every wallet at once.
contract AdminUpgradesTest is AdminBase {

    /// @dev keccak256("eip1967.proxy.implementation") - 1
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _implementationOf(address _proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, IMPLEMENTATION_SLOT))));
    }

    function test_upgrade_registryThroughTheDelay() public {
        address next = address(new Registry());

        _runThroughTheDelay(
            address(registry),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (next, "")),
            bytes32(0)
        );

        assertEq(_implementationOf(address(registry)), next);
    }

    function test_upgrade_lazyWalletRegistryThroughTheDelay() public {
        address next = address(new LazyWalletRegistry());

        _runThroughTheDelay(
            address(lazyWalletRegistry),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (next, "")),
            bytes32(0)
        );

        assertEq(_implementationOf(address(lazyWalletRegistry)), next);
    }

    /// @dev The former owner is an ordinary account now and must be refused like any other.
    function test_upgrade_rejectsTheAccountThatUsedToOwnTheProxy() public {
        address next = address(new Registry());

        vm.prank(upgradeManager);
        vm.expectRevert();
        UUPSUpgradeable(address(registry)).upgradeToAndCall(next, "");

        assertNotEq(_implementationOf(address(registry)), next);
    }

    function test_upgrade_rejectsAProposerActingDirectly() public {
        address next = address(new Registry());

        vm.prank(proposer);
        vm.expectRevert();
        UUPSUpgradeable(address(registry)).upgradeToAndCall(next, "");
    }

    /// @dev A guardian holds no more authority over a proxy than anyone else. The only thing the
    ///      role buys is skipping the wait, and it has to go through the admin contract to use it.
    function test_upgrade_rejectsAGuardianActingDirectly() public {
        address next = address(new Registry());

        vm.prank(guardian);
        vm.expectRevert();
        UUPSUpgradeable(address(registry)).upgradeToAndCall(next, "");
    }

    /// @dev The case the batch form exists for. Four proxies, one operation, so a transaction that
    ///      fails partway leaves the deployment on one version rather than two.
    function test_upgrade_movesAllFourSingletonsInOneOperation() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads, address[] memory nexts) =
            _fourUpgrades();

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        _assertAllFourMoved(nexts);
    }

    /// @dev No account reaches an upgrade without the wait, the guardian included. An upgrade is
    ///      the change worth announcing most, and the emergency lever is the pause rather than a
    ///      fast path to new code: the hot key freezes the protocol in one transaction and the
    ///      replacement implementation then gets the same review as any other.
    function test_upgrade_hasNoRouteThatSkipsTheDelay() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads,) = _fourUpgrades();

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        address[3] memory callers = [guardian, proposer, outsider];
        for(uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert();
            protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        }

        assertEq(registry.owner(), address(protocolAdmin), "nothing may have moved");
    }

    /// @dev One beacon call moves every device wallet that exists. There is no per-wallet opt out,
    ///      so this is a protocol wide change no matter how it is scheduled.
    function test_upgrade_deviceWalletBeaconReachesExistingWallets() public {
        address wallet = _deployDeviceWallet();
        address next = address(new MockDeviceWalletV2(typeCastEntryPoint, p256Verifier));

        _runThroughTheDelay(
            address(deviceWalletFactory),
            abi.encodeCall(deviceWalletFactory.updateDeviceWalletImplementation, (next)),
            bytes32(0)
        );

        assertEq(deviceWalletFactory.beacon().implementation(), next);
        assertEq(
            MockDeviceWalletV2(payable(wallet)).addTwoNumbers(2, 3),
            5,
            "the wallet must be answering with the new implementation"
        );
    }

    function test_upgrade_eSIMWalletBeaconReachesExistingWallets() public {
        address next = address(new MockESIMWalletV2());

        _runThroughTheDelay(
            address(eSIMWalletFactory),
            abi.encodeCall(eSIMWalletFactory.updateESIMWalletImplementation, (next)),
            bytes32(0)
        );

        assertEq(eSIMWalletFactory.beacon().implementation(), next);
    }

    function test_upgrade_beaconRejectsTheFormerOwnerOfTheFactory() public {
        address next = address(new MockESIMWalletV2());

        vm.prank(upgradeManager);
        vm.expectRevert();
        eSIMWalletFactory.updateESIMWalletImplementation(next);
    }

    /// @dev Both beacons in one operation, so the two wallet layers cannot be left on mismatched
    ///      versions between two transactions.
    function test_upgrade_movesBothBeaconsInOneOperation() public {
        address nextDevice = address(new MockDeviceWalletV2(typeCastEntryPoint, p256Verifier));
        address nextESIM = address(new MockESIMWalletV2());

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);

        targets[0] = address(deviceWalletFactory);
        payloads[0] = abi.encodeCall(deviceWalletFactory.updateDeviceWalletImplementation, (nextDevice));
        targets[1] = address(eSIMWalletFactory);
        payloads[1] = abi.encodeCall(eSIMWalletFactory.updateESIMWalletImplementation, (nextESIM));

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(deviceWalletFactory.beacon().implementation(), nextDevice);
        assertEq(eSIMWalletFactory.beacon().implementation(), nextESIM);
    }

    /// @dev Cancelling has to reach an upgrade like anything else. This is the whole value of the
    ///      delay: an announced upgrade that turns out to be wrong can be stopped before it lands.
    function test_upgrade_canBeCancelledBeforeTheDelayExpires() public {
        address next = address(new Registry());
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (next, ""));
        address before = _implementationOf(address(registry));

        bytes32 id = _schedule(address(registry), data, bytes32(0));

        // One key behind the proposer multisig, acting alone
        vm.prank(canceller);
        protocolAdmin.cancel(id);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        vm.expectRevert();
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));

        assertEq(_implementationOf(address(registry)), before);
    }

    function _deployDeviceWallet() private returns (address) {
        vm.prank(address(typeCastEntryPoint));
        address wallet = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 701)
        );

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(wallet, customDeviceUniqueIdentifiers[0], pubKey1);

        return wallet;
    }

    function _fourUpgrades()
        private
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads,
            address[] memory nexts
        )
    {
        targets = _ownedContracts();
        values = new uint256[](4);
        payloads = new bytes[](4);
        nexts = new address[](4);

        nexts[0] = address(new Registry());
        nexts[1] = address(new LazyWalletRegistry());
        nexts[2] = address(new DeviceWalletFactory());
        nexts[3] = address(new ESIMWalletFactory());

        for(uint256 i = 0; i < 4; ++i) {
            payloads[i] = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (nexts[i], ""));
        }
    }

    /// @dev Split out because four assertions in a row run the stack up under the via-IR optimizer.
    function _assertAllFourMoved(address[] memory _nexts) private view {
        address[] memory targets = _ownedContracts();

        for(uint256 i = 0; i < targets.length; ++i) {
            assertEq(_implementationOf(targets[i]), _nexts[i]);
        }
    }
}
