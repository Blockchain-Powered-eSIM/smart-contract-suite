// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {Errors} from "../../../contracts/Errors.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Types
import {DataBundleDetails, Settlement, Wallets} from "../../../contracts/CustomStructs.sol";

// Contracts
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Registry} from "../../../contracts/Registry.sol";
import {DeviceWallet} from "../../../contracts/device-wallet/DeviceWallet.sol";
import {DeviceWalletFactory} from "../../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWallet} from "../../../contracts/esim-wallet/ESIMWallet.sol";
import {PaymentAdapter} from "../../../contracts/payments/PaymentAdapter.sol";

// Runs against a Base mainnet fork where the default admin allowance has already been set to zero
// through the timelock. Skips on any other chain or before that change.
// Owner calls are made by pranking the device wallet, which is what `execute` does once the
// passkey signature checks out. Signature checking is not touched by this change.
contract AdminAllowanceZeroForkTest is Test {

    string private constant RECORD = "deployments/base-8453-entrypoint-v8.json";
    bytes32 private constant USDC_SYMBOL = bytes32("USDC");

    // P-256 generator point, a valid curve point for the owner key
    bytes32 private constant GX = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296;
    bytes32 private constant GY = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5;

    uint64 private constant PRICE = 500;

    Registry private registry;
    DeviceWalletFactory private deviceWalletFactory;
    PaymentAdapter private adapter;
    IERC20 private usdc;
    address private admin;
    address private vault;

    DeviceWallet private deviceWallet;
    ESIMWallet private eSIMWallet;

    function setUp() public {
        if(block.chainid != 8453) vm.skip(true);

        string memory record = vm.readFile(RECORD);
        registry = Registry(vm.parseJsonAddress(record, ".contracts.RegistryProxy.address"));
        if(registry.defaultAdminAllowanceUSDCents() != 0) vm.skip(true);

        deviceWalletFactory = DeviceWalletFactory(
            vm.parseJsonAddress(record, ".contracts.DeviceWalletFactoryProxy.address")
        );
        adapter = PaymentAdapter(registry.paymentAdapter());
        usdc = IERC20(adapter.resolveAsset(USDC_SYMBOL).token);
        admin = registry.eSIMWalletAdmin();
        vault = registry.vault();

        (deviceWallet, eSIMWallet) = _deployWallets();
        deal(address(usdc), address(deviceWallet), 100e6);
    }

    function test_newWallet_startsWithZeroAllowance() public view {
        assertEq(registry.defaultAdminAllowanceUSDCents(), 0);
        assertEq(eSIMWallet.adminAllowanceUSDCents(), 0);
    }

    function test_userBuys_withFundsAccess() public {
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet), true);

        uint256 vaultBefore = usdc.balanceOf(vault);
        _buyAs(address(deviceWallet), PRICE, "user-access");

        assertEq(usdc.balanceOf(vault) - vaultBefore, 5e6);
        assertEq(usdc.balanceOf(address(deviceWallet)), 95e6);
        assertEq(_historyLength(), 1);
    }

    function test_userBuys_byTransferThenBuy() public {
        // What one `executeBatch` does: send the price over, then buy, no standing access
        vm.startPrank(address(deviceWallet));
        usdc.transfer(address(eSIMWallet), 5e6);
        vm.stopPrank();

        uint256 vaultBefore = usdc.balanceOf(vault);
        _buyAs(address(deviceWallet), PRICE, "user-batch");

        assertEq(usdc.balanceOf(vault) - vaultBefore, 5e6);
        assertEq(usdc.balanceOf(address(eSIMWallet)), 0);
        assertEq(_historyLength(), 1);
    }

    function test_adminCannotBuy_evenWithFundsAccess() public {
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet), true);

        _expectAdminRefused(PRICE, 0);
        _buyAs(admin, PRICE, "admin-access");
        assertEq(usdc.balanceOf(address(deviceWallet)), 100e6);
    }

    function test_adminCannotBuy_withTokensInESIMWallet() public {
        deal(address(usdc), address(eSIMWallet), 5e6);

        _expectAdminRefused(PRICE, 0);
        _buyAs(admin, PRICE, "admin-held");
        assertEq(usdc.balanceOf(address(eSIMWallet)), 5e6);
    }

    function test_adminCannotBuy_cheapestBundle() public {
        deal(address(usdc), address(eSIMWallet), 1e6);

        _expectAdminRefused(1, 0);
        _buyAs(admin, 1, "admin-one-cent");
    }

    function test_userOptsIn_thenAdminLimitedToIt_thenUserRevokes() public {
        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet), true);
        eSIMWallet.setAdminAllowanceUSDCents(PRICE);
        vm.stopPrank();

        _buyAs(admin, PRICE, "admin-opted-in");
        assertEq(eSIMWallet.adminAllowanceUSDCents(), 0);

        _expectAdminRefused(1, 0);
        _buyAs(admin, 1, "admin-over");

        vm.prank(address(deviceWallet));
        eSIMWallet.setAdminAllowanceUSDCents(1000);
        vm.prank(address(deviceWallet));
        eSIMWallet.setAdminAllowanceUSDCents(0);

        _expectAdminRefused(PRICE, 0);
        _buyAs(admin, PRICE, "admin-revoked");
    }

    function test_onlyOwnerSetsAllowance() public {
        vm.prank(admin);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        eSIMWallet.setAdminAllowanceUSDCents(type(uint64).max);
    }

    function test_userPurchase_stillHeldToPriceCap() public {
        uint64 cap = registry.defaultPriceCapUSDCents();
        deal(address(usdc), address(eSIMWallet), 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, cap + 1, cap));
        _buyAs(address(deviceWallet), cap + 1, "user-over-cap");
    }

    function test_userPurchase_referenceSpentOnce() public {
        deal(address(usdc), address(eSIMWallet), 10e6);
        _buyAs(address(deviceWallet), PRICE, "user-replay");

        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentReferenceAlreadyUsed.selector, keccak256("user-replay")));
        _buyAs(address(deviceWallet), PRICE, "user-replay");
    }

    // A real wallet deployed before the change, named by EXISTING_ESIM_WALLET. It keeps the
    // allowance it was created with; only its owner can lower it.
    function test_existingWallet_keepsItsAllowance() public {
        address existing = vm.envOr("EXISTING_ESIM_WALLET", address(0));
        if(existing == address(0)) vm.skip(true);

        ESIMWallet wallet = ESIMWallet(payable(existing));
        uint64 allowance = wallet.adminAllowanceUSDCents();
        console.log("existing wallet allowance (cents):", allowance);
        if(allowance == 0) return;

        deal(address(usdc), existing, 5e6);
        vm.prank(admin);
        wallet.buyDataBundleWithToken(_bundle(PRICE), USDC_SYMBOL, type(uint256).max, keccak256("admin-existing"));
        assertEq(wallet.adminAllowanceUSDCents(), allowance - PRICE);
    }

    function _deployWallets() private returns (DeviceWallet, ESIMWallet) {
        string[] memory identifiers = new string[](1);
        identifiers[0] = "admin-allowance-fork-check";
        bytes32[2][] memory keys = new bytes32[2][](1);
        keys[0] = [GX, GY];
        uint256[] memory salts = new uint256[](1);
        salts[0] = uint256(keccak256("admin-allowance-fork-check"));
        uint256[] memory deposits = new uint256[](1);

        vm.prank(admin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);

        return (DeviceWallet(payable(wallets[0].deviceWallet)), ESIMWallet(payable(wallets[0].eSIMWallet)));
    }

    function _buyAs(address caller, uint64 price, string memory orderId) private {
        vm.prank(caller);
        eSIMWallet.buyDataBundleWithToken(_bundle(price), USDC_SYMBOL, type(uint256).max, keccak256(bytes(orderId)));
    }

    function _expectAdminRefused(uint64 price, uint64 remaining) private {
        vm.expectRevert(abi.encodeWithSelector(Errors.AdminAllowanceExceeded.selector, price, remaining));
    }

    function _bundle(uint64 price) private pure returns (DataBundleDetails memory) {
        return DataBundleDetails({id: keccak256("bundle"), priceUSDCents: price, settlement: Settlement.DeviceWallet});
    }

    function _historyLength() private view returns (uint256 length) {
        while(true) {
            try eSIMWallet.transactionHistory(length) returns (bytes32, uint64, Settlement) {
                ++length;
            } catch {
                return length;
            }
        }
    }
}
