// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "test/foundry/invariant-testing/base/InvariantBase.sol";

import {MockDeviceWalletV2} from "test/utils/mocks/MockDeviceWalletV2.sol";
import {MockESIMWalletV2} from "test/utils/mocks/MockESIMWalletV2.sol";

import {ProtocolState} from "test/foundry/invariant-testing/base/ProtocolState.sol";
import {HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";
import {AdminHandler} from "test/foundry/invariant-testing/handler/AdminHandler.sol";
import {WalletHandler} from "test/foundry/invariant-testing/handler/WalletHandler.sol";
import {AttackerHandler} from "test/foundry/invariant-testing/handler/AttackerHandler.sol";
import {UpgradeManagerHandler} from
    "test/foundry/invariant-testing/handler/UpgradeManagerHandler.sol";

/// @notice The campaign every invariant file runs against.
/// @dev Each invariant function is its own campaign with its own `setUp`, so splitting the
///      invariants across files costs no extra sequences. What it would cost is a copy of this
///      wiring per file, which is why it lives here.
abstract contract CampaignBase is InvariantBase {

    /// @notice Share of the campaign budget the sitting admin holds
    uint256 internal constant ADMIN_BUDGET = 500 ether;

    /// @notice Share held by the address the admin role rotates onto
    uint256 internal constant ADMIN_SUCCESSOR_BUDGET = 100 ether;

    ProtocolState internal state;
    AdminHandler internal adminHandler;
    WalletHandler internal walletHandler;
    AttackerHandler internal attackerHandler;
    UpgradeManagerHandler internal upgradeManagerHandler;

    /// @notice Deploys the protocol, wires the three handlers to it and funds the campaign
    function setUp() public virtual {
        _deployProtocol();

        state = new ProtocolState();

        HandlerConfig memory config = HandlerConfig({
            state: state,
            deviceWalletFactory: deviceWalletFactory,
            eSIMWalletFactory: eSIMWalletFactory,
            registry: registry,
            lazyWalletRegistry: lazyWalletRegistry,
            entryPoint: address(entryPoint),
            admin: ADMIN,
            adminSuccessor: ADMIN_SUCCESSOR,
            upgradeManager: UPGRADE_MANAGER,
            vault: VAULT,
            attacker: ATTACKER
        });

        adminHandler = new AdminHandler(config);
        walletHandler = new WalletHandler(config);
        attackerHandler = new AttackerHandler(config);

        // The second implementations are built here rather than inside the handler so the beacon
        // swap starts from the same wallet logic the campaign deployed against
        upgradeManagerHandler = new UpgradeManagerHandler(
            config,
            address(new MockDeviceWalletV2(IEntryPoint(address(entryPoint)), p256Verifier)),
            address(new MockESIMWalletV2())
        );

        // The value on a pranked call leaves the pranked account, so the budget sits with the two
        // actors that pay for anything rather than with a handler. Both are inside the accounted
        // set, so the conservation sum is unchanged by where it starts
        vm.deal(ADMIN, ADMIN_BUDGET);
        vm.deal(ADMIN_SUCCESSOR, ADMIN_SUCCESSOR_BUDGET);
        vm.deal(ATTACKER, state.TOTAL_ETH() - ADMIN_BUDGET - ADMIN_SUCCESSOR_BUDGET);

        targetContract(address(adminHandler));
        targetContract(address(walletHandler));
        targetContract(address(attackerHandler));
        targetContract(address(upgradeManagerHandler));

        // Several modifiers admit `address(registry)` or `address(this)`, so a random sender that
        // lands on one of these passes access control by accident and reports a violation that
        // cannot happen onchain
        excludeSender(address(registry));
        excludeSender(address(lazyWalletRegistry));
        excludeSender(address(deviceWalletFactory));
        excludeSender(address(eSIMWalletFactory));
        excludeSender(address(entryPoint));
        excludeSender(address(state));
        excludeSender(address(adminHandler));
        excludeSender(address(walletHandler));
        excludeSender(address(attackerHandler));
        excludeSender(address(upgradeManagerHandler));

        // The four actors are excluded for a different reason, and it is not optional. The runner
        // adjusts the balance of whichever address it picks as sender, so an actor used as a
        // sender has its balance moved by the harness rather than by the protocol. Every one of
        // them is a term in the conservation sum, and leaving them in reported a 355 ether loss
        // that no call in the sequence had caused
        excludeSender(ADMIN);
        excludeSender(ADMIN_SUCCESSOR);
        excludeSender(UPGRADE_MANAGER);
        excludeSender(VAULT);
        excludeSender(ATTACKER);
    }

    /// @notice Every wei the campaign can see, wherever it currently sits
    /// @dev Each handler is summed. Only the attacker's holds a balance today, since donations are
    ///      refused by the singletons and bounce back, but a handler that ends up with wei is
    ///      holding campaign ETH either way and leaving it out would read as a loss.
    /// @return Total balance across every address the campaign has touched
    function _heldETH() internal view returns (uint256) {
        uint256 held = address(adminHandler).balance + address(walletHandler).balance
            + address(attackerHandler).balance + address(upgradeManagerHandler).balance
            + ADMIN.balance + ADMIN_SUCCESSOR.balance
            + UPGRADE_MANAGER.balance
            + VAULT.balance + ATTACKER.balance + address(deviceWalletFactory).balance
            + address(eSIMWalletFactory).balance + address(registry).balance
            + address(lazyWalletRegistry).balance + address(entryPoint).balance;

        uint256 count = state.accountedAddressCount();
        for (uint256 i = 0; i < count; ++i) {
            held += state.accountedAddresses(i).balance;
        }

        return held;
    }
}
