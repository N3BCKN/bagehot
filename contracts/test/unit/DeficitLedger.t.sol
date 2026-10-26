// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StableToken} from "../../src/core/StableToken.sol";
import {AlreadySettled, InvalidParameter, SystemSettled, Unauthorized} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {DeficitLedger} from "../../src/safety/DeficitLedger.sol";
import {MockWETH} from "../utils/VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice DeficitLedger (spec §4.7, §5.6, §6.9, §6.11.3): construction and wiring, every hook's check
///         order (wired, caller, not settled), effects and events, `cover`, settlement, and ADR-0033's
///         requirement that `onInterest` never reverts up to the supply cap.
contract DeficitLedgerTest is Test {
    address internal constant VM = address(0xA1);
    address internal constant POOL = address(0xA2);
    address internal constant HOUSE = address(0xA3);
    address internal constant SHUTDOWN = address(0xA4);
    address internal alice = makeAddr("alice");

    MockWETH internal weth;
    StableToken internal token;
    DeficitLedger internal l;

    /// @dev Deployment A's wiring by default; `house` true for B's.
    function _deploy(bool house) internal {
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        l = new DeficitLedger(address(weth), address(token));
        address strategy = house ? HOUSE : POOL;
        l.wire(VM, strategy, house ? HOUSE : address(0), house ? address(0) : POOL, SHUTDOWN);
        // the VaultManager mints; the ledger burns (burner role)
        token.wire(VM, strategy, address(l), SHUTDOWN);
    }

    function setUp() public {
        _deploy(false);
    }

    function _mintTo(address to, uint256 amount) internal {
        vm.prank(VM);
        token.mint(to, amount);
    }

    // ------------------------------------------------------------------ construction and wiring

    function test_constructor_checks() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 0));
        new DeficitLedger(address(0), address(1));
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 1));
        new DeficitLedger(address(1), address(0));
    }

    function test_wire_checks_inOrder() public {
        DeficitLedger x = new DeficitLedger(address(weth), address(token));
        vm.prank(alice);
        vm.expectRevert(WiredBase.NotDeployer.selector);
        x.wire(VM, POOL, address(0), POOL, SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 0));
        x.wire(address(0), POOL, address(0), POOL, SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 1));
        x.wire(VM, address(0), address(0), POOL, SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 2));
        x.wire(VM, POOL, HOUSE, address(0), SHUTDOWN); // house must be the strategy
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 3));
        x.wire(VM, POOL, address(0), HOUSE, SHUTDOWN); // pool must be the strategy
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 3));
        x.wire(VM, POOL, address(0), address(0), SHUTDOWN); // neither
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 3));
        x.wire(VM, POOL, POOL, POOL, SHUTDOWN); // both
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 4));
        x.wire(VM, POOL, address(0), POOL, address(0));
        x.wire(VM, POOL, address(0), POOL, SHUTDOWN);
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        x.wire(VM, POOL, address(0), POOL, SHUTDOWN);
    }

    function test_everyMutator_notWired_reverts() public {
        DeficitLedger x = new DeficitLedger(address(weth), address(token));
        vm.expectRevert(WiredBase.NotWired.selector);
        x.onInterest(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.onPoolDust(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.recordDeficit(1, 1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.addAuctionDebt(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.onAuctionPayment(1, 1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.onAuctionShortfall(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.payTip(alice, 1);
        vm.expectRevert(WiredBase.NotWired.selector);
        x.cover();
        vm.expectRevert(WiredBase.NotWired.selector);
        x.onSettlement();
    }

    // ------------------------------------------------------------------ hooks: callers and effects

    function test_hooks_wrongCaller_revertUnauthorized() public {
        vm.startPrank(alice);
        vm.expectRevert(Unauthorized.selector);
        l.onInterest(1);
        vm.expectRevert(Unauthorized.selector);
        l.onPoolDust(1);
        vm.expectRevert(Unauthorized.selector);
        l.recordDeficit(1, 0);
        vm.expectRevert(Unauthorized.selector);
        l.addAuctionDebt(1); // no house in A: address(0) can never call
        vm.expectRevert(Unauthorized.selector);
        l.onSettlement();
        vm.stopPrank();
    }

    function test_onInterest_and_onPoolDust_growTheReserve() public {
        _mintTo(address(l), 7e18);
        vm.expectEmit(address(l));
        emit DeficitLedger.ReserveIncreased(5e18, 1);
        vm.prank(VM);
        l.onInterest(5e18);
        vm.expectEmit(address(l));
        emit DeficitLedger.ReserveIncreased(2e18, 3);
        vm.prank(POOL);
        l.onPoolDust(2e18);
        assertEq(l.reserve(), 7e18);
        assertEq(token.balanceOf(address(l)), l.reserve(), "I1: token == reserve");
    }

    function test_recordDeficit_booksDeficitAndCollateral() public {
        weth.mint(address(l), 3e18); // the VaultManager transferred it first
        vm.expectEmit(address(l));
        emit DeficitLedger.DeficitRecorded(1000e18, 3e18, 2);
        vm.prank(VM);
        l.recordDeficit(1000e18, 3e18);
        assertEq(l.deficit(), 1000e18);
        assertEq(l.recoveredColl(), 3e18);
        assertEq(weth.balanceOf(address(l)), l.recoveredColl(), "I1: WETH == recoveredColl");
    }

    function test_auctionHooks_B() public {
        _deploy(true);
        vm.startPrank(HOUSE);
        vm.expectEmit(address(l));
        emit DeficitLedger.AuctionDebtChanged(int256(500e18), 500e18);
        l.addAuctionDebt(500e18);
        vm.stopPrank();
        _mintTo(address(l), 25e18); // the house moved the penalty here
        vm.startPrank(HOUSE);
        vm.expectEmit(address(l));
        emit DeficitLedger.AuctionDebtChanged(-int256(300e18), 200e18);
        vm.expectEmit(address(l));
        emit DeficitLedger.ReserveIncreased(25e18, 2);
        l.onAuctionPayment(300e18, 25e18);
        vm.expectEmit(address(l));
        emit DeficitLedger.DeficitRecorded(200e18, 0, 1);
        l.onAuctionShortfall(200e18);
        l.payTip(alice, 5e18);
        vm.stopPrank();
        assertEq(l.auctionDebt(), 0);
        assertEq(l.deficit(), 200e18);
        assertEq(l.reserve(), 20e18);
        assertEq(token.balanceOf(alice), 5e18, "tip paid");
        assertEq(token.balanceOf(address(l)), l.reserve());
        // A's hooks are closed to the house
        vm.prank(HOUSE);
        vm.expectRevert(Unauthorized.selector);
        l.recordDeficit(1, 0);
    }

    // ------------------------------------------------------------------ cover (§6.9.2)

    function test_cover_burnsMinOfReserveAndDeficit() public {
        _mintTo(address(l), 100e18);
        vm.prank(VM);
        l.onInterest(100e18);
        vm.prank(VM);
        l.recordDeficit(30e18, 0);
        uint256 supply = token.totalSupply();
        vm.expectEmit(address(l));
        emit DeficitLedger.DeficitCovered(30e18, 70e18, 0);
        vm.prank(alice); // anyone
        assertEq(l.cover(), 30e18);
        assertEq(supply - token.totalSupply(), 30e18, "burned");
        vm.prank(VM);
        l.recordDeficit(200e18, 0);
        assertEq(l.cover(), 70e18, "the whole reserve when it is smaller");
        assertEq(l.deficit(), 130e18);
        assertEq(l.reserve(), 0);
        assertEq(l.cover(), 0, "nothing to cover: a no-op that still emits");
    }

    // ------------------------------------------------------------------ settlement (§6.11.3)

    function test_onSettlement_burnsReserve_auctionDebtToDeficit_collToShutdown() public {
        _deploy(true);
        _mintTo(address(l), 40e18);
        vm.prank(VM);
        l.onInterest(40e18);
        vm.prank(HOUSE);
        l.addAuctionDebt(500e18);
        vm.prank(VM);
        l.recordDeficit(10e18, 0);
        uint256 supply = token.totalSupply();
        vm.expectEmit(address(l));
        emit DeficitLedger.LedgerSettled(40e18, 510e18, 0);
        vm.prank(SHUTDOWN);
        assertEq(l.onSettlement(), 0);
        assertEq(supply - token.totalSupply(), 40e18, "the reserve is burned");
        assertEq(l.reserve(), 0);
        assertEq(l.auctionDebt(), 0);
        assertEq(l.deficit(), 510e18, "auction debt became deficit");
        assertTrue(l.settled());
        vm.prank(SHUTDOWN);
        vm.expectRevert(AlreadySettled.selector);
        l.onSettlement();
    }

    function test_onSettlement_sendsRecoveredCollateralToTheShutdownModule() public {
        weth.mint(address(l), 4e18);
        vm.prank(VM);
        l.recordDeficit(1000e18, 4e18);
        vm.prank(SHUTDOWN);
        assertEq(l.onSettlement(), 4e18);
        assertEq(weth.balanceOf(SHUTDOWN), 4e18, "joins the claim pool");
        assertEq(l.recoveredColl(), 0);
        assertEq(weth.balanceOf(address(l)), 0);
    }

    /// @dev After settlement every hook and `cover` revert SystemSettled — checked after the caller.
    function test_afterSettlement_hooksAndCoverRevert() public {
        vm.prank(SHUTDOWN);
        l.onSettlement();
        vm.prank(VM);
        vm.expectRevert(SystemSettled.selector);
        l.onInterest(1);
        vm.prank(POOL);
        vm.expectRevert(SystemSettled.selector);
        l.onPoolDust(1);
        vm.prank(VM);
        vm.expectRevert(SystemSettled.selector);
        l.recordDeficit(1, 0);
        vm.expectRevert(SystemSettled.selector);
        l.cover();
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // the caller check comes before the settled check
        l.onInterest(1);
    }

    // ------------------------------------------------------------------ ADR-0033 §3

    /// @dev P19-AC-CHG006-1 on the real ledger (P21): `onInterest` takes any amounts up to the supply cap,
    ///      with the tokens minted to match, and never reverts.
    function testFuzz_onInterest_neverRevertsUpToTheSupplyCap(uint256[6] memory amounts) public {
        uint256 cap = type(uint128).max;
        uint256 sum;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 a = i == amounts.length - 1 ? cap - sum : bound(amounts[i], 0, cap - sum);
            _mintTo(address(l), a);
            vm.prank(VM);
            l.onInterest(a);
            sum += a;
            assertEq(l.reserve(), sum);
            assertEq(token.balanceOf(address(l)), l.reserve());
        }
        assertEq(l.reserve(), cap, "reached the supply cap");
    }
}
