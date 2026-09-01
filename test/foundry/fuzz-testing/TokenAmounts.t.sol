// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";

/// @notice Which price ceiling applies, over arbitrary caps and prices.
/// @dev The cap resolution is the part worth fuzzing rather than enumerating: the wallet's own cap
///      wins when set, and the registry default applies when it is not. Zero on the wallet still
///      means "follow the registry", but the registry itself can never hold zero: `initialize` and
///      `setDefaultPriceCapUSDCents` both refuse it, so a real ceiling always applies somewhere.
///
///      The ceiling now bounds what gets spent rather than only what gets recorded, because the
///      adapter works the amount out from the same price the cap is checked against.
///
///      The last two cases are about the other two amounts on that path: what a pull moves, and the
///      access flag a bind is never allowed to set.
contract TokenAmountsTest is FuzzBase {

    /// @dev $10,000,000 in cents
    uint64 private constant MAX_FUZZED_CENTS = 1_000_000_000;

    function setUp() public override {
        super.setUp();
        _deployFuzzWallets();

        vm.prank(eSIMWalletAdmin);
        registry.assignESIMIdentifier(address(fuzzESIMWallet), "ESIM_FUZZ");
    }

    // ---------------------------------------------------------------------------------------------
    // Which ceiling applies
    // ---------------------------------------------------------------------------------------------

    /// @notice A price above the wallet's own cap is refused, and nothing moves
    /// @dev The revert has to carry both numbers, because the caller cannot otherwise tell which of
    ///      the two levels refused it.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundleWithToken_refusesAPriceAboveTheWalletCap(uint64 _cap, uint64 _price) public {
        uint64 cap = uint64(bound(_cap, 1, MAX_FUZZED_CENTS - 1));
        uint64 price = uint64(bound(_price, uint256(cap) + 1, MAX_FUZZED_CENTS));

        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setPriceCapUSDCents(cap);

        fundSettlementToken(address(fuzzDeviceWallet), settlementAmount(price));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, cap));
        fuzzESIMWallet.buyDataBundleWithToken(
            bundle("DB_FUZZ", price),
            ASSET_USDC,
            settlementAmount(price),
            nextRef()
        );

        assertEq(settlementERC20.balanceOf(vault), 0, "A refused purchase must pay nothing");
    }

    /// @notice With no cap on the wallet, the registry default is what refuses
    /// @dev The fallback only fires when the wallet's own cap is zero, so this is what says the two
    ///      levels are read in the right order rather than the default being ignored once a wallet
    ///      exists.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundleWithToken_fallsBackToTheRegistryCap(uint64 _cap, uint64 _price) public {
        uint64 cap = uint64(bound(_cap, 1, MAX_FUZZED_CENTS - 1));
        uint64 price = uint64(bound(_price, uint256(cap) + 1, MAX_FUZZED_CENTS));

        vm.prank(registry.owner());
        registry.setDefaultPriceCapUSDCents(cap);

        assertEq(fuzzESIMWallet.priceCapUSDCents(), 0, "The wallet must have no cap of its own");

        fundSettlementToken(address(fuzzDeviceWallet), settlementAmount(price));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, cap));
        fuzzESIMWallet.buyDataBundleWithToken(
            bundle("DB_FUZZ", price),
            ASSET_USDC,
            settlementAmount(price),
            nextRef()
        );
    }

    /// @notice The wallet's own cap wins over the registry default, in both directions
    /// @dev Including the direction where the wallet's cap is the looser of the two. A resolution
    ///      that took the minimum of the two would pass a test that only ever set the wallet
    ///      tighter, and would silently cap wallets the device owner meant to raise.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundleWithToken_theWalletCapOverridesTheDefault(
        uint64 _walletCap,
        uint64 _price
    ) public {
        uint64 walletCap = uint64(bound(_walletCap, 2, MAX_FUZZED_CENTS));
        uint64 price = uint64(bound(_price, 1, walletCap));

        // The registry default is set tighter than the price, so a purchase that succeeds proves
        // the wallet's own cap is what was read
        vm.prank(registry.owner());
        registry.setDefaultPriceCapUSDCents(1);

        vm.prank(address(fuzzDeviceWallet));
        fuzzESIMWallet.setPriceCapUSDCents(walletCap);

        uint256 needed = settlementAmount(price);
        fundSettlementToken(address(fuzzDeviceWallet), needed);

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundleWithToken(bundle("DB_FUZZ", price), ASSET_USDC, needed, nextRef());

        assertEq(
            settlementERC20.balanceOf(vault),
            needed,
            "The wallet's own cap must be the one that applies"
        );
    }

    /// @notice A price within the registry default set at deployment succeeds without either
    /// wallet or admin ever configuring a cap of their own
    /// @dev The wallet-level zero still means "follow the registry", but the registry itself can
    /// never hold zero, so this is the uncapped-looking path that is actually always bounded.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_buyDataBundleWithToken_withinTheDeployTimeDefaultSucceeds(uint64 _price) public {
        uint64 price = uint64(bound(_price, 1, defaultPriceCapUSDCents));

        assertEq(fuzzESIMWallet.priceCapUSDCents(), 0, "The wallet must have no cap of its own");
        assertEq(
            registry.defaultPriceCapUSDCents(),
            defaultPriceCapUSDCents,
            "The registry must hold the cap it was deployed with"
        );

        uint256 needed = settlementAmount(price);
        fundSettlementToken(address(fuzzDeviceWallet), needed);

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundleWithToken(bundle("DB_FUZZ", price), ASSET_USDC, needed, nextRef());

        assertEq(
            settlementERC20.balanceOf(vault),
            needed,
            "A price within the default must not be refused"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // What a pull moves
    // ---------------------------------------------------------------------------------------------

    /// @notice A pull the device wallet can cover moves exactly that amount and no more
    /// @dev Swept over arbitrary balances because the unit tests pin single amounts. A partial
    ///      transfer would leave the eSIM wallet holding tokens the device wallet still counts.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_pullToken_movesExactlyTheAmountRequested(uint256 _balance, uint256 _amount) public {
        uint256 balance = bound(_balance, 1, type(uint128).max);
        uint256 amount = bound(_amount, 1, balance);

        fundSettlementToken(address(fuzzDeviceWallet), balance);
        uint256 walletBefore = settlementERC20.balanceOf(address(fuzzESIMWallet));

        vm.prank(address(fuzzESIMWallet));
        fuzzDeviceWallet.pullToken(settlementToken, amount);

        assertEq(
            settlementERC20.balanceOf(address(fuzzDeviceWallet)),
            balance - amount,
            "The device wallet must lose exactly the amount"
        );
        assertEq(
            settlementERC20.balanceOf(address(fuzzESIMWallet)) - walletBefore,
            amount,
            "The eSIM wallet must gain exactly the amount"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Who gets access to the money
    // ---------------------------------------------------------------------------------------------

    /// @notice No caller binds a wallet with the right to spend, whoever they are
    /// @dev Access control runs first, so an unauthorised caller is turned away before the flag is
    ///      read, and an authorised one is refused on the flag itself. Either way the wallet ends
    ///      up without the access.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_noCallerEverBindsWithFundsAccess(uint256 _caller) public {
        address[5] memory callers = [
            eSIMWalletAdmin,
            address(registry),
            address(deviceWalletFactory),
            address(fuzzDeviceWallet),
            user1
        ];
        address caller = callers[bound(_caller, 0, callers.length - 1)];

        // Released and rebound rather than deployed fresh, to avoid a salt collision with the
        // wallets the base fixture already placed
        address wallet = address(fuzzESIMWallet);
        vm.prank(address(fuzzDeviceWallet));
        fuzzDeviceWallet.removeESIMWallet(wallet, false);

        vm.prank(caller);
        try fuzzDeviceWallet.addESIMWallet(wallet, true) {
            fail("A bind carrying funds access must never succeed");
        } catch {}

        assertFalse(
            fuzzDeviceWallet.canPullFunds(wallet),
            "A refused bind must leave the wallet without the right to spend"
        );
    }
}
