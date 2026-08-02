// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "test/foundry/invariant-testing/InvariantBase.sol";
import {Handler} from "test/foundry/invariant-testing/Handler.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

/// @notice Properties that must hold after any sequence of calls the protocol allows.
/// @dev The handler is the only target. Pointing the runner at the protocol contracts is the
///      usual way an invariant suite ends up green and worthless, because almost every random
///      call is refused by a modifier before it touches state.
///
///      Configuration is in the inline `forge-config` comments rather than `foundry.toml`, which
///      this repo keeps fixed for bytecode parity with hardhat.
contract ProtocolInvariantsTest is InvariantBase {

    /// @notice Share of the campaign budget the admin holds, the rest going to the attacker
    uint256 internal constant ADMIN_BUDGET = 600 ether;

    /// @notice How many times the distribution test drives each entry point
    uint256 internal constant DRIVE_ROUNDS = 40;

    /// @notice Successful executions each entry point has to reach in that drive
    uint256 internal constant MIN_SUCCESSES = 20;

    /// @notice Seeds reserved per round, wide enough for the largest batch plus one spare
    uint256 internal constant SEEDS_PER_ROUND = 8;

    Handler internal handler;

    /// @notice Deploys the protocol, wires the handler to it and funds the campaign
    function setUp() public {
        _deployProtocol();

        handler = new Handler(
            deviceWalletFactory,
            eSIMWalletFactory,
            registry,
            lazyWalletRegistry,
            address(entryPoint),
            ADMIN,
            UPGRADE_MANAGER,
            VAULT,
            ATTACKER
        );
        // The value on a pranked call leaves the pranked account, so the budget sits with the two
        // actors that pay for anything rather than with the handler. Both are inside the accounted
        // set, so the conservation sum is unchanged by where it starts
        vm.deal(ADMIN, ADMIN_BUDGET);
        vm.deal(ATTACKER, handler.TOTAL_ETH() - ADMIN_BUDGET);

        targetContract(address(handler));

        // Several modifiers admit `address(registry)` or `address(this)`, so a random sender that
        // lands on one of these passes access control by accident and reports a violation that
        // cannot happen onchain
        excludeSender(address(registry));
        excludeSender(address(lazyWalletRegistry));
        excludeSender(address(deviceWalletFactory));
        excludeSender(address(eSIMWalletFactory));
        excludeSender(address(entryPoint));
        excludeSender(address(handler));

        // The four actors are excluded for a different reason, and it is not optional. The runner
        // adjusts the balance of whichever address it picks as sender, so an actor used as a
        // sender has its balance moved by the harness rather than by the protocol. Every one of
        // them is a term in the conservation sum, and leaving them in reported a 355 ether loss
        // that no call in the sequence had caused
        excludeSender(ADMIN);
        excludeSender(UPGRADE_MANAGER);
        excludeSender(VAULT);
        excludeSender(ATTACKER);
    }

    // ------------------------------------------------------------------------------------------
    // ETH conservation
    // ------------------------------------------------------------------------------------------

    /// @notice No wei enters or leaves the accounted set
    /// @dev The handler is funded once and is the only source. Every address that can end up
    ///      holding protocol ETH is summed here, so a shortfall means wei reached somewhere this
    ///      list does not name and a surplus means it was created.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_ethIsConserved() public view {
        uint256 held = address(handler).balance + ADMIN.balance + UPGRADE_MANAGER.balance
            + VAULT.balance + ATTACKER.balance + address(deviceWalletFactory).balance
            + address(eSIMWalletFactory).balance + address(registry).balance
            + address(lazyWalletRegistry).balance + address(entryPoint).balance;

        uint256 count = handler.accountedAddressCount();
        for (uint256 i = 0; i < count; ++i) {
            held += handler.accountedAddresses(i).balance;
        }

        assertEq(held, handler.accountedETH(), "ETH left the accounted set");
    }

    /// @notice None of the four singletons ever holds ETH between transactions
    /// @dev Exactly zero, not merely small. None of them has a withdrawal path, so any balance is
    ///      stranded for good. The factory forwards or refunds everything it is sent, both
    ///      registries forward `msg.value` in full on the lazy deploy path, and none of the four
    ///      declares a `receive`, which is what stops a donation from creating a balance the
    ///      protocol can never move. The handler attempts that donation on every run rather than
    ///      taking it on trust.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_singletonsHoldNoETH() public view {
        assertFalse(
            handler.ghost_singletonAcceptedETH(),
            "A contract with no withdrawal path accepted ETH"
        );
        assertEq(address(deviceWalletFactory).balance, 0, "Device wallet factory is holding ETH");
        assertEq(address(eSIMWalletFactory).balance, 0, "eSIM wallet factory is holding ETH");
        assertEq(address(registry).balance, 0, "Registry is holding ETH");
        assertEq(address(lazyWalletRegistry).balance, 0, "Lazy wallet registry is holding ETH");
    }

    // ------------------------------------------------------------------------------------------
    // Associations
    // ------------------------------------------------------------------------------------------

    /// @notice All three contracts agree on which device wallet owns each eSIM wallet
    /// @dev The association is written in three places that no single call updates together: the
    ///      registry's mapping, the device wallet's own list, and the eSIM wallet's owner. They
    ///      are only consistent because every path that changes one changes the others in the
    ///      same transaction, which is exactly the kind of agreement a long sequence breaks.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_associationsAgree() public view {
        uint256 count = handler.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = handler.eSIMWallets(i);
            address device = registry.isESIMWalletValid(wallet);
            if (device == address(0)) continue;

            assertTrue(
                MockDeviceWallet(payable(device)).isValidESIMWallet(wallet),
                "Registry names a device wallet that does not claim the eSIM wallet"
            );
            assertEq(
                ESIMWallet(payable(wallet)).owner(),
                device,
                "Registry and the eSIM wallet disagree about the owner"
            );
        }
    }

    /// @notice An eSIM wallet is on standby exactly while no device wallet holds it
    /// @dev Two separate calls set these, so nothing in the code ties them together. The comment
    ///      at the standby toggle assumes the pairing rather than enforcing it, which makes this
    ///      the only thing checking it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_standbyMatchesDetachment() public view {
        uint256 count = handler.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = handler.eSIMWallets(i);
            if (!registry.isESIMWalletOnStandby(wallet)) continue;

            assertEq(
                registry.isESIMWalletValid(wallet),
                address(0),
                "An eSIM wallet is on standby while a device wallet still holds it"
            );
        }
    }

    /// @notice An eSIM wallet never ends up ownerless
    /// @dev Ownership cannot be renounced and cannot be transferred in one step, so there is no
    ///      sequence that should leave one with no owner. An ownerless wallet holds whatever ETH
    ///      it had with nobody able to move it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_eSIMWalletsKeepAnOwner() public view {
        uint256 count = handler.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            assertTrue(
                ESIMWallet(payable(handler.eSIMWallets(i))).owner() != address(0),
                "An eSIM wallet has no owner"
            );
        }
    }

    // ------------------------------------------------------------------------------------------
    // The campaign proves it ran
    // ------------------------------------------------------------------------------------------

    /// @notice Every entry point can reach the protocol and change its state
    /// @dev `fail_on_revert` is false, which is the only workable setting with this many access
    ///      control modifiers. It also hides the failure mode that makes a whole campaign
    ///      worthless: a handler whose calls all revert, which stays green while testing nothing.
    ///      This drives each entry point directly and asserts it got through.
    ///
    ///      Deliberately an ordinary test and not an assertion inside the campaign. Anything
    ///      checked per sequence is subject to the shrinker, which searches for the shortest
    ///      failing sequence and so will always find one that starves an entry point. Measured:
    ///      an `afterInvariant` version of this failed at `1 < 20` with the shrinker cutting a
    ///      500-call sequence down to exactly the guard boundary.
    function test_handlerReachesEveryEntryPoint() public {
        // A batch consumes up to three consecutive seeds and each seed becomes an identifier, so
        // the two deploy paths are given disjoint blocks. Overlapping them would have the second
        // path re-present an identifier the first already claimed, which is a real case the
        // campaign covers but not what this test is asking about
        for (uint256 round = 0; round < DRIVE_ROUNDS; ++round) {
            uint256 seed = round * SEEDS_PER_ROUND;
            handler.deployDeviceWalletBatch(round, seed, 1 ether);
            handler.createAccountPermissionless(seed + SEEDS_PER_ROUND - 1, round, false);
            handler.postCreateAccount(round);
            handler.donateETH(round, 1 ether);
            handler.donateToSingleton(round, 1 ether);
            handler.deployESIMWalletForDevice(round, true, seed + 2000);
            handler.toggleAccessToETH(round, true);
            handler.buyDataBundle(round, 1 gwei);
            handler.pullETH(round, 1 gwei);
            // Removal comes before the transfer pair on purpose. Requesting a transfer detaches
            // the wallet on its way through, so a removal after it has nothing left to remove
            handler.removeESIMWallet(round, true, false);
            handler.addESIMWallet(round, round);
            handler.requestTransferOwnership(round, round + 1);
            handler.acceptOwnershipTransfer(round);
        }

        _assertExercised("deployDeviceWalletBatch");
        _assertExercised("createAccountPermissionless");
        _assertExercised("postCreateAccount");
        _assertExercised("donateETH");
        _assertExercised("donateToSingleton");
        _assertExercised("deployESIMWalletForDevice");
        _assertExercised("toggleAccessToETH");
        _assertExercised("buyDataBundle");
        _assertExercised("pullETH");
        _assertExercised("requestTransferOwnership");
        _assertExercised("acceptOwnershipTransfer");
        _assertExercised("removeESIMWallet");
    }

    /// @notice Fails if an entry point never got through
    /// @param name Entry point to check
    function _assertExercised(bytes32 name) internal view {
        assertGe(
            handler.calls(name),
            MIN_SUCCESSES,
            string.concat("Entry point never reached the protocol: ", _name(name))
        );
    }

    /// @notice Renders a padded entry point name for a failure message
    /// @param name Entry point name, right-padded with zero bytes
    /// @return The name without its padding
    function _name(bytes32 name) internal pure returns (string memory) {
        uint256 length;
        while (length < 32 && name[length] != 0) ++length;
        bytes memory trimmed = new bytes(length);
        for (uint256 i = 0; i < length; ++i) trimmed[i] = name[i];
        return string(trimmed);
    }
}
