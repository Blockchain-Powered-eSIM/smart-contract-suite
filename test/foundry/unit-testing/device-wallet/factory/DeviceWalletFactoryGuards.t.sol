// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";

/// @notice An account that refuses every payment sent to it
contract ETHRefuser {
    fallback() external payable {
        revert("No ETH accepted");
    }
}

/// @notice Covers the input guards and reject arms on `DeviceWalletFactory`, which carries the
///         largest block of untested branches in the protocol.
/// @dev The happy paths and the front-run adoption case live in `DeviceWalletFactory.t.sol`. This
///      file is only the refusals, plus the two lookups that return an existing wallet rather than
///      deploying a second one.
contract DeviceWalletFactoryGuardsTest is DeployerBase {

    /// @notice Deploys one wallet through the admin path so the guards below have something to
    ///         collide with
    /// @param _identifier The device identifier to register
    /// @param _ownerKey The owner key to register
    /// @param _salt The CREATE2 salt
    /// @return The wallets deployed
    function _deployOne(string memory _identifier, bytes32[2] memory _ownerKey, uint256 _salt)
        internal
        returns (Wallets memory)
    {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = _ownerKey;
        salts[0] = _salt;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        return deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits)[0];
    }

    /// @notice Deploys a factory that has never been given a registry address
    /// @return The unwired factory
    function _factoryWithoutRegistry() internal returns (DeviceWalletFactory) {
        DeviceWalletFactory implementation = new DeviceWalletFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                implementation.initialize,
                (address(deviceWalletImpl), upgradeManager, address(eSIMWalletFactory), typeCastEntryPoint, p256Verifier)
            )
        );
        return DeviceWalletFactory(address(proxy));
    }

    /// @notice Calls initialize with one argument replaced, expecting the given revert string
    /// @param _upgradeManager The upgrade manager address to pass
    /// @param _error The encoded error expected
    function _expectInitializeToRevert(address _upgradeManager, bytes memory _error) internal {
        DeviceWalletFactory implementation = new DeviceWalletFactory();

        vm.expectRevert(_error);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                implementation.initialize,
                (address(deviceWalletImpl), _upgradeManager, address(eSIMWalletFactory), typeCastEntryPoint, p256Verifier)
            )
        );
    }

    /// @notice Calls initialize with one of the three wiring addresses replaced
    /// @param _eSIMWalletFactory The eSIM wallet factory address to pass
    /// @param _entryPoint The entry point to pass
    /// @param _verifier The P256 verifier to pass
    /// @param _parameter The name the revert should carry
    function _expectWiringToRevert(
        address _eSIMWalletFactory,
        IEntryPoint _entryPoint,
        P256Verifier _verifier,
        string memory _parameter
    ) internal {
        DeviceWalletFactory implementation = new DeviceWalletFactory();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, _parameter));
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                implementation.initialize,
                (address(deviceWalletImpl), upgradeManager, _eSIMWalletFactory, _entryPoint, _verifier)
            )
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------------------------------

    /// @notice A factory without an owner cannot be initialized
    /// @dev The owner is the only caller that can upgrade this contract or the beacon under it.
    function test_initialize_rejectsAZeroUpgradeManager() public {
        _expectInitializeToRevert(address(0), abi.encodeWithSelector(Errors.ZeroAddress.selector, "_upgradeManager"));
    }

    /// @notice The three wiring addresses cannot be zero either
    /// @dev None of the three has a setter, so recovering from a zero here needs an upgrade. The
    ///      entry point and the verifier are worse than the others: both are baked into the wallet
    ///      implementation at construction, so every wallet the factory then deploys is broken.
    function test_initialize_rejectsAZeroEntryPoint() public {
        _expectWiringToRevert(address(eSIMWalletFactory), IEntryPoint(payable(address(0))), p256Verifier, "_entryPoint");
    }

    /// @notice A factory cannot be initialised without a signature verifier
    function test_initialize_rejectsAZeroVerifier() public {
        _expectWiringToRevert(address(eSIMWalletFactory), typeCastEntryPoint, P256Verifier(address(0)), "_verifier");
    }

    /// @notice A factory cannot be initialised without an eSIM wallet factory
    function test_initialize_rejectsAZeroESIMWalletFactory() public {
        _expectWiringToRevert(address(0), typeCastEntryPoint, p256Verifier, "_eSIMWalletFactoryAddress");
    }

    /// @notice The registry address cannot be set to zero
    /// @dev It can only be set once, so a zero would close the admin path permanently.
    function test_addRegistryAddress_rejectsTheZeroAddress() public {
        DeviceWalletFactory factory = _factoryWithoutRegistry();

        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_registryContractAddress"));
        factory.addRegistryAddress(address(0));
    }

    /// @notice Before a registry is wired up the factory reports no admin, and admin functions stay
    ///         closed rather than reverting inside a call to address(0)
    function test_eSIMWalletAdmin_isEmptyUntilTheRegistryIsAdded() public {
        DeviceWalletFactory factory = _factoryWithoutRegistry();

        assertEq(factory.eSIMWalletAdmin(), address(0), "An unwired factory must report no admin");

        bytes32[2] memory ownerKey;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyAdminOrRegistry.selector);
        factory.postCreateAccount(user1, "Device_1", ownerKey, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Beacon implementation
    // ---------------------------------------------------------------------------------------------

    /// @notice The beacon cannot be pointed at nothing
    /// @dev Every device wallet reads its logic through this one beacon, so a zero here bricks all
    ///      of them at once.
    function test_updateDeviceWalletImplementation_rejectsTheZeroAddress() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_newDeviceImpl"));
        deviceWalletFactory.updateDeviceWalletImplementation(address(0));
    }

    /// @notice Pointing the beacon at what it already holds is refused
    function test_updateDeviceWalletImplementation_rejectsTheCurrentImplementation() public {
        address current = deviceWalletFactory.getCurrentDeviceWalletImplementation();

        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.ImplementationUnchanged.selector, current));
        deviceWalletFactory.updateDeviceWalletImplementation(current);

        assertEq(
            deviceWalletFactory.getCurrentDeviceWalletImplementation(),
            current,
            "A refused update must leave the beacon alone"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Batch input shape
    // ---------------------------------------------------------------------------------------------

    /// @notice Calls the batch deployer with arrays of the given lengths, expecting a revert
    /// @param _identifierCount Length of the identifier array
    /// @param _keyCount Length of the key array
    /// @param _saltCount Length of the salt array
    /// @param _depositCount Length of the deposit array
    /// @param _error The encoded error expected
    function _expectBatchToRevert(
        uint256 _identifierCount,
        uint256 _keyCount,
        uint256 _saltCount,
        uint256 _depositCount,
        bytes memory _error
    ) internal {
        string[] memory identifiers = new string[](_identifierCount);
        for (uint256 i = 0; i < _identifierCount; ++i) {
            identifiers[i] = customDeviceUniqueIdentifiers[i];
        }
        bytes32[2][] memory keys = new bytes32[2][](_keyCount);
        for (uint256 i = 0; i < _keyCount; ++i) {
            keys[i] = listOfOwnerKeys[i];
        }

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(_error);
        deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers, keys, new uint256[](_saltCount), new uint256[](_depositCount)
        );
    }

    /// @notice A batch with nothing in it is refused rather than silently returning nothing
    function test_deployDeviceWalletForUsers_rejectsAnEmptyBatch() public {
        _expectBatchToRevert(0, 0, 0, 0, abi.encodeWithSelector(Errors.EmptyBatch.selector));
    }

    /// @notice Fewer owner keys than identifiers is refused
    /// @dev Each of the three length checks is separate, so each needs its own test. A missing one
    ///      would read past the end of its array and pair an identifier with another device's key.
    function test_deployDeviceWalletForUsers_rejectsAShortKeyArray() public {
        _expectBatchToRevert(2, 1, 2, 2, abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 2, 1));
    }

    /// @notice Fewer salts than identifiers is refused
    function test_deployDeviceWalletForUsers_rejectsAShortSaltArray() public {
        _expectBatchToRevert(2, 2, 1, 2, abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 2, 1));
    }

    /// @notice Fewer deposits than identifiers is refused
    function test_deployDeviceWalletForUsers_rejectsAShortDepositArray() public {
        _expectBatchToRevert(2, 2, 2, 1, abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 2, 1));
    }

    /// @notice A device identifier cannot be empty
    /// @dev The identifier is the key the registry stores the wallet under, and an empty one would
    ///      take the slot every later empty identifier resolves to.
    function test_deployDeviceWalletForUsers_rejectsAnEmptyDeviceIdentifier() public {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        identifiers[0] = "";
        keys[0] = pubKey1;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyDeviceIdentifier.selector);
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, new uint256[](1), new uint256[](1));
    }

    /// @notice createAccount applies the same identifier check, on a path no admin gate protects
    function test_createAccount_rejectsAnEmptyDeviceIdentifier() public {
        vm.expectRevert(Errors.EmptyDeviceIdentifier.selector);
        deviceWalletFactory.createAccount("", pubKey1, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // ETH accounting
    // ---------------------------------------------------------------------------------------------

    /// @notice A batch cannot promise a wallet more ETH than the caller sent
    /// @dev The budget is checked per entry, so an early entry cannot spend what a later one was
    ///      meant to receive.
    function test_deployDeviceWalletForUsers_rejectsADepositAboveTheETHSent() public {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = 5001;
        deposits[0] = 2 ether;

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 1 ether, 2 ether));
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(identifiers, keys, salts, deposits);
    }

    /// @notice A caller that cannot accept its own refund takes the whole batch down
    /// @dev Better than the alternative. The factory has no way to send ETH anywhere afterwards, so
    ///      a swallowed refund would sit in the factory permanently.
    function test_deployDeviceWalletForUsers_revertsWhenTheRefundIsRefused() public {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = 5002;
        deposits[0] = 0;

        vm.etch(eSIMWalletAdmin, address(new ETHRefuser()).code);
        vm.deal(eSIMWalletAdmin, 1 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.FailedToTransfer.selector);
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(identifiers, keys, salts, deposits);
    }

    // ---------------------------------------------------------------------------------------------
    // Collisions with an already registered wallet
    // ---------------------------------------------------------------------------------------------

    /// @notice A known device identifier presented with a different owner key is refused
    /// @dev Returning the existing wallet here would hand it to whoever asked for it under a key
    ///      its owner never held.
    function test_deployDeviceWalletForUsers_rejectsAKnownIdentifierUnderADifferentKey() public {
        _deployOne(customDeviceUniqueIdentifiers[0], pubKey1, 6001);

        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey2;
        salts[0] = 6002;

        address existing = registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.DeviceWalletAlreadyExists.selector, customDeviceUniqueIdentifiers[0], existing
        ));
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));
    }

    /// @notice A known owner key presented under a different device identifier is refused
    /// @dev The key check is separate from the identifier check, so this arm needs its own test.
    function test_deployDeviceWalletForUsers_rejectsAKnownKeyUnderADifferentIdentifier() public {
        _deployOne(customDeviceUniqueIdentifiers[0], pubKey1, 6003);

        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        identifiers[0] = customDeviceUniqueIdentifiers[1];
        keys[0] = pubKey1;
        salts[0] = 6004;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.OwnerKeyAlreadyRegistered.selector, keccak256(abi.encode(pubKey1[0], pubKey1[1]))
        ));
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));
    }

    /// @notice The pre-flight check reports the wallet already holding a device identifier
    /// @dev Offchain callers use this to decide whether to send a deployment at all, so it has to
    ///      answer with the wallet rather than reverting.
    function test_preCreateAccountValidation_reportsTheWalletHoldingTheIdentifier() public {
        Wallets memory deployed = _deployOne(customDeviceUniqueIdentifiers[0], pubKey1, 6005);

        assertEq(
            deviceWalletFactory.preCreateAccountValidation(customDeviceUniqueIdentifiers[0], pubKey2),
            deployed.deviceWallet,
            "The wallet holding the identifier must be reported"
        );
    }

    /// @notice The pre-flight check reports the wallet already holding an owner key
    function test_preCreateAccountValidation_reportsTheWalletHoldingTheOwnerKey() public {
        Wallets memory deployed = _deployOne(customDeviceUniqueIdentifiers[0], pubKey1, 6006);

        assertEq(
            deviceWalletFactory.preCreateAccountValidation(customDeviceUniqueIdentifiers[1], pubKey1),
            deployed.deviceWallet,
            "The wallet holding the owner key must be reported"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Post deployment registration
    // ---------------------------------------------------------------------------------------------

    /// @notice A wallet whose details are already recorded cannot be recorded again
    /// @dev A second registration would overwrite the registry's record of a live wallet.
    function test_postCreateAccount_rejectsAWalletAlreadyRecorded() public {
        Wallets memory deployed = _deployOne(customDeviceUniqueIdentifiers[0], pubKey1, 7001);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DeviceWalletInfoAlreadyAdded.selector, deployed.deviceWallet));
        deviceWalletFactory.postCreateAccount(deployed.deviceWallet, customDeviceUniqueIdentifiers[1], pubKey2, 7001);
    }

    /// @notice Registration with an empty device identifier is refused
    function test_postCreateAccount_rejectsAnEmptyDeviceIdentifier() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyDeviceIdentifier.selector);
        deviceWalletFactory.postCreateAccount(user1, "", pubKey1, 0);
    }

    /// @notice Registration with a key that is not a point on the curve is refused
    /// @dev The same predicate both deploy paths apply. A wallet recorded under a key that can
    ///      never verify a signature holds an identifier and a key hash the protocol cannot
    ///      release, and this path used to be the one that skipped the check.
    function test_postCreateAccount_rejectsAnOffCurveOwnerKey() public {
        vm.prank(user1);
        address wallet = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 7101)
        );

        bytes32[2] memory offCurve = [bytes32(uint256(1)), bytes32(uint256(1))];

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.postCreateAccount(wallet, customDeviceUniqueIdentifiers[0], offCurve, 7101);
    }

    /// @notice A key the wallet does not hold cannot be recorded against it
    /// @dev The owner key is a constructor argument of the proxy, so it is folded into the CREATE2
    ///      address. Presenting a different one derives a different address and is refused.
    ///      Without this the registry names a key the wallet cannot sign with, and the key the
    ///      wallet does hold is left unreserved for a second wallet to claim.
    function test_postCreateAccount_rejectsAKeyTheWalletDoesNotHold() public {
        vm.prank(user1);
        address wallet = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 7201)
        );

        address derived = deviceWalletFactory.getCounterFactualAddress(
            pubKey2,
            customDeviceUniqueIdentifiers[0],
            7201
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DeviceWalletMismatch.selector, wallet, derived));
        deviceWalletFactory.postCreateAccount(wallet, customDeviceUniqueIdentifiers[0], pubKey2, 7201);

        assertEq(
            registry.getDeviceWalletToOwner(wallet)[0],
            bytes32(0),
            "A refused registration must leave the registry with no record of the wallet"
        );
    }

    /// @notice An identifier the wallet does not carry cannot be recorded against it
    /// @dev The identifier is folded into the address the same way. A wrong one here is
    ///      unrecoverable, since the registry then refuses the correct binding as a duplicate.
    function test_postCreateAccount_rejectsAnIdentifierTheWalletDoesNotCarry() public {
        vm.prank(user1);
        address wallet = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 7301)
        );

        address derived = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[1],
            7301
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DeviceWalletMismatch.selector, wallet, derived));
        deviceWalletFactory.postCreateAccount(wallet, customDeviceUniqueIdentifiers[1], pubKey1, 7301);

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[1]),
            address(0),
            "A refused registration must leave the identifier unclaimed"
        );
    }

    /// @notice The salt has to be the one the wallet was deployed with
    /// @dev Everything else matching still derives a different address, which is what makes the
    ///      salt worth carrying through the backend rather than being guessed at.
    function test_postCreateAccount_rejectsTheWrongSalt() public {
        vm.prank(user1);
        address wallet = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 7401)
        );

        address derived = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            7402
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DeviceWalletMismatch.selector, wallet, derived));
        deviceWalletFactory.postCreateAccount(wallet, customDeviceUniqueIdentifiers[0], pubKey1, 7402);
    }

    /// @notice An arbitrary address cannot be recorded as a device wallet
    /// @dev `isDeviceWalletValid` is an authorisation gate on the registry, the eSIM wallet factory
    ///      and the eSIM wallet transfer path, so an address that was never a device wallet
    ///      carrying it is a hole in all three.
    function test_postCreateAccount_rejectsAnAddressThatIsNotADeviceWallet() public {
        address derived = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            7501
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DeviceWalletMismatch.selector, user1, derived));
        deviceWalletFactory.postCreateAccount(user1, customDeviceUniqueIdentifiers[0], pubKey1, 7501);

        assertFalse(
            registry.isDeviceWalletValid(user1),
            "An externally owned account must not be recorded as a device wallet"
        );
    }

    /// @notice A counterfactual address nothing has been deployed to is refused
    /// @dev The derivation alone answers for an address whether or not it holds code. Recording an
    ///      empty one would reserve the identifier and the key against a wallet that does not
    ///      exist and might never be deployed.
    function test_postCreateAccount_rejectsAnAddressWithNoCode() public {
        address derived = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            7601
        );
        assertEq(derived.code.length, 0, "The address must be empty for this to be the case under test");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DeviceWalletNotDeployed.selector, derived));
        deviceWalletFactory.postCreateAccount(derived, customDeviceUniqueIdentifiers[0], pubKey1, 7601);
    }

    /// @notice The matching arguments still register the wallet
    /// @dev The counterpart to every refusal above. The added derivation has to leave the path it
    ///      guards working, and the registry has to end up holding what the wallet itself holds.
    function test_postCreateAccount_recordsAWalletWithMatchingArguments() public {
        vm.prank(user1);
        address wallet = address(
            deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], pubKey1, 7701)
        );

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(wallet, customDeviceUniqueIdentifiers[0], pubKey1, 7701);

        assertTrue(deviceWalletFactory.deviceWalletInfoAdded(wallet), "The wallet must carry the record flag");
        assertTrue(registry.isDeviceWalletValid(wallet), "The registry must accept the wallet as valid");
        assertEq(
            registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]),
            wallet,
            "The identifier must resolve to the wallet"
        );
        assertEq(
            registry.getDeviceWalletToOwner(wallet)[0],
            pubKey1[0],
            "The registry must name the key the wallet holds"
        );
        assertEq(
            registry.getDeviceWalletToOwner(wallet)[1],
            pubKey1[1],
            "The registry must name the key the wallet holds"
        );
    }
}
