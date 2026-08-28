// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Registry} from "../../contracts/Registry.sol";
import {DeviceWallet} from "../../contracts/device-wallet/DeviceWallet.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter} from "../../contracts/payments/PaymentAdapter.sol";
import {ProtocolAdmin} from "../../contracts/admin/ProtocolAdmin.sol";

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

// Libraries
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

// Config
import {DeployConfig} from "../deploy/config/DeployConfig.sol";
import {DeploymentRecord} from "../deploy/config/DeploymentRecord.sol";

/// @notice Exercises a freshly deployed protocol on a local fork, the way a caller would
/// @dev Runs after `Deploy.s.sol`, `Configure.s.sol` and `TransferOwnership.s.sol` have been
///      pointed at the same fork. Reads every address out of the deployment record rather than
///      taking arguments, for the same reason the deploy scripts do.
///
///      This is a rehearsal, not a test. The suite already proves each of these paths against a
///      mock and against a pinned fork block. What no test covers is the three deploy scripts
///      producing a protocol that then works, because the tests stand the protocol up themselves.
///      Everything here therefore runs against what the scripts left behind and nothing is set up
///      locally.
///
///      Every check reverts rather than logging a failure. A rehearsal that prints "not ok" and
///      exits zero is how a broken deployment gets approved.
contract ForkRehearsal is Script {

    /// @notice A predicted address did not match what the factory derived or what got deployed
    error AddressMismatch(string what, address expected, address actual);

    /// @notice A check that had to hold after the deploy scripts ran did not
    error CheckFailed(string what);

    /// @notice The EntryPoint charged nothing for an operation it was supposed to accept
    error OperationNotCharged(uint256 depositBefore, uint256 depositAfter);

    /// @notice The wallet is expected to answer a signature, so the owner key is the harness key
    /// @dev Fixed inside `test/utils/ffi/webauthn-signer.js`. A rehearsal cannot use a random key,
    ///      because the assertion has to be produced by something holding the private half.
    bytes32[2] private ownerKey;

    /// @notice CREATE2 salt for the rehearsal wallet
    uint256 private constant SALT = 1;

    /// @notice Identifier the rehearsal device is reached by
    string private constant DEVICE_ID = "fork-rehearsal-device-1";

    /// @notice Gas the operation declares for signature verification
    /// @dev Measured at 41,807 on a fork where RIP-7212 answers. This is set to cover the other
    ///      branch instead: a chain without the precompile falls through to FreshCryptoLib at
    ///      227,256, a factor of 31, so an operation sized for the cheap path strands during
    ///      validation on any chain that does not carry it.
    ///
    ///      Declared limits are not a spending estimate. The EntryPoint checks the transaction
    ///      carries the whole declared amount before it starts, and reverts `AA95 out of gas` when
    ///      it does not, whatever the operation goes on to actually use.
    uint128 private constant VERIFICATION_GAS_LIMIT = 300_000;

    /// @notice Gas the operation declares for the call phase
    /// @dev The call data is empty, so nothing runs here. Kept non-zero because the EntryPoint
    ///      still enters the call frame.
    uint128 private constant CALL_GAS_LIMIT = 50_000;

    /// @notice Gas the operation pays for the EntryPoint's own overhead
    uint256 private constant PRE_VERIFICATION_GAS = 60_000;

    IEntryPoint private entryPoint;
    Registry private registry;
    DeviceWalletFactory private deviceWalletFactory;
    ESIMWalletFactory private eSIMWalletFactory;
    PaymentAdapter private paymentAdapter;
    address private protocolAdmin;

    /// @notice Runs every rehearsal step in order and reverts on the first thing that is wrong
    function run() external {
        DeployConfig.Config memory config = DeployConfig.load();

        _loadDeployment();

        _checkHandoverIsComplete(config);

        address predicted = _checkCounterfactualAddress();
        _deployThroughEntryPoint(config, predicted);
        _recordWallet(predicted);
        _runUserOperation(config, predicted);

        console.log("");
        console.log("Rehearsal complete. Every step passed.");
    }

    /// @notice Reads the protocol the three deploy scripts left behind
    /// @dev `readAddress` checks each one carries code, so a record naming an address on another
    ///      chain fails here rather than several calls later.
    function _loadDeployment() private {
        entryPoint = IEntryPoint(DeployConfig.ENTRY_POINT_V08);
        registry = Registry(DeploymentRecord.readAddress("RegistryProxy"));
        deviceWalletFactory =
            DeviceWalletFactory(DeploymentRecord.readAddress("DeviceWalletFactoryProxy"));
        eSIMWalletFactory =
            ESIMWalletFactory(DeploymentRecord.readAddress("ESIMWalletFactoryProxy"));
        paymentAdapter = PaymentAdapter(DeploymentRecord.readAddress("PaymentAdapterProxy"));
        protocolAdmin = DeploymentRecord.readRaw("admin.protocolAdmin");

        ownerKey = WebAuthnSigner.publicKey();

        console.log("Registry            ", address(registry));
        console.log("DeviceWalletFactory ", address(deviceWalletFactory));
        console.log("ESIMWalletFactory   ", address(eSIMWalletFactory));
        console.log("PaymentAdapter      ", address(paymentAdapter));
        console.log("ProtocolAdmin       ", protocolAdmin);
        console.log("");
    }

    /// @notice The deployer must hold nothing once `TransferOwnership.s.sol` has run
    /// @dev Checked here rather than trusted from that script's own log, because the whole point of
    ///      a rehearsal is that a later step reads the state an earlier one claims to have made.
    ///      This is launch gate 4.11, and `plan/06` calls it the most commonly forgotten step.
    function _checkHandoverIsComplete(DeployConfig.Config memory config) private view {
        if(registry.owner() != protocolAdmin) revert CheckFailed("Registry owner is not the timelock");
        if(deviceWalletFactory.owner() != protocolAdmin) {
            revert CheckFailed("DeviceWalletFactory owner is not the timelock");
        }
        if(eSIMWalletFactory.owner() != protocolAdmin) {
            revert CheckFailed("ESIMWalletFactory owner is not the timelock");
        }
        if(PaymentAdapter(paymentAdapter).owner() != protocolAdmin) {
            revert CheckFailed("PaymentAdapter owner is not the timelock");
        }
        if(registry.owner() == config.deployer) revert CheckFailed("Deployer still owns the registry");

        // The timelock's own floor, read back off the deployed contract rather than off the
        // constant the script passed in.
        if(ProtocolAdmin(payable(protocolAdmin)).getMinDelay() != DeployConfig.TIMELOCK_DELAY) {
            revert CheckFailed("Timelock delay is not what the deploy configured");
        }

        console.log("Ownership handover complete, all five singletons held by the timelock");
    }

    /// @notice Derives the wallet address offchain and checks the factory agrees
    /// @dev This is the initCode the SDK ships. Building it here from `type(BeaconProxy).creationCode`
    ///      and the beacon the factory reports is the same derivation `compute-initCode.js` does,
    ///      so a disagreement means the SDK bundle would strand every counterfactual address.
    ///      Launch gate 3.5.
    /// @return predicted Address the wallet is expected to land at
    function _checkCounterfactualAddress() private view returns (address predicted) {
        bytes memory initCode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(
                address(deviceWalletFactory.beacon()),
                abi.encodeCall(
                    DeviceWallet.init,
                    (address(registry), ownerKey, DEVICE_ID, address(eSIMWalletFactory))
                )
            )
        );

        predicted = Create2.computeAddress(
            bytes32(SALT),
            keccak256(initCode),
            address(deviceWalletFactory)
        );

        address onchain =
            deviceWalletFactory.getCounterFactualAddress(ownerKey, DEVICE_ID, SALT);
        if(onchain != predicted) {
            revert AddressMismatch("counterfactual address", predicted, onchain);
        }

        console.log("initCode hash      ", vm.toString(keccak256(initCode)));
        console.log("Counterfactual     ", predicted);
        console.log("Offchain derivation matches the factory");
        return predicted;
    }

    /// @notice Deploys the wallet the way a first user operation does, through the EntryPoint
    /// @dev `createAccount` is permissionless on purpose: it runs inside ERC-4337 validation, where
    ///      reading another contract's storage is barred, so it cannot consult the registry to
    ///      decide who may call. Calling it directly here is the same code path the EntryPoint's
    ///      `initCode` handling takes, without needing a bundler in the loop.
    function _deployThroughEntryPoint(DeployConfig.Config memory config, address predicted) private {
        if(predicted.code.length != 0) revert CheckFailed("Wallet address is already occupied");

        vm.startBroadcast(config.deployerPrivateKey);
        DeviceWallet deployed = deviceWalletFactory.createAccount{value: 0.05 ether}(
            DEVICE_ID,
            ownerKey,
            SALT
        );
        vm.stopBroadcast();

        if(address(deployed) != predicted) {
            revert AddressMismatch("deployed wallet", predicted, address(deployed));
        }
        if(predicted.code.length == 0) revert CheckFailed("Wallet did not land at the address");

        console.log("Wallet deployed at the predicted address, funded with 0.05 ether");
    }

    /// @notice Registers the wallet, which is what the admin does after a counterfactual deploy
    /// @dev Split from `createAccount` because that one may not touch the registry. Everything the
    ///      registry needs to know about the wallet arrives here instead, and the factory
    ///      re-derives the address from the arguments so a caller cannot register a wallet it did
    ///      not deploy.
    function _recordWallet(address wallet) private {
        // Signed by the admin key, not the deployer. `postCreateAccount` is `onlyAdminOrRegistry`
        // and the admin is read off the registry, so this is the one step in the rehearsal that
        // proves the admin wiring rather than the owner wiring.
        vm.startBroadcast(vm.envUint("ESIM_WALLET_ADMIN_PRIVATE_KEY"));
        deviceWalletFactory.postCreateAccount(wallet, DEVICE_ID, ownerKey, SALT);
        vm.stopBroadcast();

        if(registry.uniqueIdentifierToDeviceWallet(DEVICE_ID) != wallet) {
            revert CheckFailed("Registry does not know the wallet");
        }
        if(!registry.isDeviceWalletValid(wallet)) revert CheckFailed("Wallet is not registered valid");

        console.log("Wallet registered through postCreateAccount");
    }

    /// @notice Sends one signed user operation through the deployed EntryPoint
    /// @dev The assertion is that the deposit falls and the nonce advances, not that nothing
    ///      reverted. `handleOps` swallows a failing call and still charges for it, so absence of a
    ///      revert says nothing about whether the signature verified.
    function _runUserOperation(DeployConfig.Config memory config, address wallet) private {
        vm.startBroadcast(config.deployerPrivateKey);
        entryPoint.depositTo{value: 0.1 ether}(wallet);
        vm.stopBroadcast();

        uint48 validUntil = uint48(block.timestamp + 1 days);
        PackedUserOperation memory op;
        op.sender = wallet;
        op.nonce = entryPoint.getNonce(wallet, 0);
        // verificationGasLimit in the high half, callGasLimit in the low half
        op.accountGasLimits =
            bytes32((uint256(VERIFICATION_GAS_LIMIT) << 128) | uint256(CALL_GAS_LIMIT));
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(10 gwei));
        op.signature = _sign(op, validUntil);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        uint256 depositBefore = entryPoint.balanceOf(wallet);
        uint256 nonceBefore = entryPoint.getNonce(wallet, 0);

        // Broadcast from an EOA. v0.8 `handleOps` refuses a contract caller.
        vm.startBroadcast(config.deployerPrivateKey);
        entryPoint.handleOps(ops, payable(config.deployer));
        vm.stopBroadcast();

        uint256 depositAfter = entryPoint.balanceOf(wallet);
        if(depositAfter >= depositBefore) revert OperationNotCharged(depositBefore, depositAfter);
        if(entryPoint.getNonce(wallet, 0) != nonceBefore + 1) {
            revert CheckFailed("Nonce did not advance");
        }

        console.log("UserOperation accepted, deposit charged and nonce advanced");
    }

    /// @notice Signs an operation the way the wallet expects it
    /// @dev A 39 byte precursor holding the version, the expiry and the hash the EntryPoint itself
    ///      computed, hashed EIP-191, and that digest is what the WebAuthn assertion covers. Asking
    ///      the EntryPoint for the hash rather than deriving it is what makes this exercise v0.8's
    ///      EIP-712 form rather than a local guess at it.
    function _sign(PackedUserOperation memory op, uint48 validUntil)
        private
        returns (bytes memory)
    {
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        bytes memory challenge = abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n39",
                    uint8(1),
                    validUntil,
                    userOpHash
                )
            )
        );

        return abi.encodePacked(uint8(1), validUntil, WebAuthnSigner.sign(challenge));
    }
}
