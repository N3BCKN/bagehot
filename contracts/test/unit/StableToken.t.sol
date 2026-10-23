// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StableToken} from "../../src/core/StableToken.sol";
import {InvalidParameter, Unauthorized} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice StableToken: wiring, the three privileged functions and their callers (spec §3.4, §5.9,
///         §9), the supply cap, and the unrestricted ERC-20 surface.
contract StableTokenTest is Test {
    StableToken internal token;

    address internal constant VAULT = address(0x1001);
    address internal constant STRATEGY = address(0x1002);
    address internal constant LEDGER = address(0x1003);
    address internal constant SHUTDOWN = address(0x1004);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    uint256 internal constant CAP = type(uint128).max;

    function setUp() public {
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
    }

    function _wire() internal {
        token.wire(VAULT, STRATEGY, LEDGER, SHUTDOWN);
    }

    function _isRole(address a) internal pure returns (bool) {
        return a == VAULT || a == STRATEGY || a == LEDGER || a == SHUTDOWN;
    }

    // ---------------------------------------------------------------- construction and wiring

    function test_constructor_setsMetadataAndNothingElse() public view {
        assertEq(token.name(), "Bagehot USD TEST");
        assertEq(token.symbol(), "bUSDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.deployer(), address(this));
        assertFalse(token.wired());
        assertEq(token.SUPPLY_CAP(), CAP);
    }

    function test_wire_storesRolesAndEmitsInArgumentOrder() public {
        address[] memory expected = new address[](4);
        (expected[0], expected[1], expected[2], expected[3]) = (VAULT, STRATEGY, LEDGER, SHUTDOWN);
        vm.expectEmit(address(token));
        emit WiredBase.Wired(expected);
        _wire();
        assertTrue(token.wired());
        assertEq(token.vaultManager(), VAULT);
        assertEq(token.strategy(), STRATEGY);
        assertEq(token.deficitLedger(), LEDGER);
        assertEq(token.shutdownModule(), SHUTDOWN);
    }

    function test_wire_twiceReverts() public {
        _wire();
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        token.wire(ALICE, ALICE, ALICE, ALICE);
        assertEq(token.vaultManager(), VAULT);
    }

    function testFuzz_wire_onlyDeployer(address caller) public {
        vm.prank(caller);
        if (caller == address(this)) {
            _wire();
            assertTrue(token.wired());
            return;
        }
        vm.expectRevert(WiredBase.NotDeployer.selector);
        token.wire(VAULT, STRATEGY, LEDGER, SHUTDOWN);
        assertFalse(token.wired());
    }

    /// @dev Cited by invariants.md I11. With all-zero arguments, NotDeployer still comes first
    ///      (§3.4: the caller check precedes the argument checks).
    function test_wire_nonDeployerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(WiredBase.NotDeployer.selector);
        token.wire(address(0), address(0), address(0), address(0));
        vm.prank(ALICE);
        vm.expectRevert(WiredBase.NotDeployer.selector);
        token.wire(VAULT, STRATEGY, LEDGER, SHUTDOWN);
        assertFalse(token.wired());
    }

    function test_wire_secondCallWithZeroArgumentsGetsAlreadyWired() public {
        _wire();
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        token.wire(address(0), address(0), address(0), address(0));
    }

    /// @dev §3.4 does not forbid repeated addresses; the roles are then the union. Documented, not
    ///      endorsed: the deploy script (P18) asserts each role is the intended peer contract.
    function test_wire_duplicateAddressesGiveTheUnionOfRoles() public {
        token.wire(VAULT, VAULT, LEDGER, LEDGER);
        vm.startPrank(VAULT);
        token.mint(ALICE, 3);
        token.burnFrom(ALICE, 1);
        token.moveFrom(ALICE, BOB, 1);
        vm.stopPrank();
        vm.prank(LEDGER);
        token.burnFrom(ALICE, 1);
        vm.prank(LEDGER);
        vm.expectRevert(Unauthorized.selector);
        token.moveFrom(BOB, ALICE, 1);
        assertEq(token.totalSupply(), 1);
    }

    /// @dev Every subset of zero arguments: the first zero in argument order is reported (§3.4).
    function test_wire_zeroArgumentsReportTheFirstIndex() public {
        for (uint256 mask = 1; mask < 16; ++mask) {
            address[4] memory a = [VAULT, STRATEGY, LEDGER, SHUTDOWN]; // fresh array each mask
            uint8 first = type(uint8).max;
            for (uint8 i = 0; i < 4; ++i) {
                if (mask & (1 << i) != 0) {
                    a[i] = address(0);
                    if (first == type(uint8).max) first = i;
                }
            }
            vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, first));
            token.wire(a[0], a[1], a[2], a[3]);
        }
        assertFalse(token.wired());
    }

    // ---------------------------------------------------------------- before wiring

    /// @dev `wired` is checked before the caller, so even the would-be roles get NotWired.
    function testFuzz_privilegedFunctionsRevertBeforeWiring(address caller) public {
        vm.startPrank(caller);
        vm.expectRevert(WiredBase.NotWired.selector);
        token.mint(ALICE, 1);
        vm.expectRevert(WiredBase.NotWired.selector);
        token.burnFrom(ALICE, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        token.moveFrom(ALICE, BOB, 0);
        vm.stopPrank();
    }

    function test_erc20SurfaceWorksBeforeWiring() public {
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 5));
        assertEq(token.allowance(ALICE, BOB), 5);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
    }

    // ---------------------------------------------------------------- mint

    function test_mint_byVaultManager() public {
        _wire();
        vm.expectEmit(address(token));
        emit IERC20.Transfer(address(0), ALICE, 7e18);
        vm.prank(VAULT);
        token.mint(ALICE, 7e18);
        assertEq(token.balanceOf(ALICE), 7e18);
        assertEq(token.totalSupply(), 7e18);
    }

    function testFuzz_mint_anyoneElseUnauthorized(address caller) public {
        _wire();
        vm.prank(caller);
        if (caller == VAULT) {
            token.mint(ALICE, 1);
            assertEq(token.totalSupply(), 1);
            return;
        }
        vm.expectRevert(Unauthorized.selector);
        token.mint(ALICE, 1);
    }

    function test_mint_otherRolesUnauthorized() public {
        _wire();
        address[3] memory others = [STRATEGY, LEDGER, SHUTDOWN];
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(Unauthorized.selector);
            token.mint(ALICE, 1);
        }
    }

    function test_mint_upToTheCapExactly() public {
        _wire();
        vm.startPrank(VAULT);
        token.mint(ALICE, CAP - 1);
        token.mint(BOB, 1);
        assertEq(token.totalSupply(), CAP);
        vm.expectRevert(StableToken.SupplyCapExceeded.selector);
        token.mint(BOB, 1);
        token.mint(BOB, 0); // a zero mint at the cap is within it
        vm.stopPrank();
        assertEq(token.totalSupply(), CAP);
    }

    /// @dev Over the whole uint256 domain: either within the cap and minted, or SupplyCapExceeded —
    ///      never an arithmetic panic, even for amounts near 2^256.
    function testFuzz_mint_capIsExactAndNeverPanics(uint256 first, uint256 second) public {
        _wire();
        first = bound(first, 0, CAP);
        vm.startPrank(VAULT);
        token.mint(ALICE, first);
        if (second > CAP - first) {
            vm.expectRevert(StableToken.SupplyCapExceeded.selector);
            token.mint(BOB, second);
            assertEq(token.totalSupply(), first);
        } else {
            token.mint(BOB, second);
            assertEq(token.totalSupply(), first + second);
        }
        vm.stopPrank();
    }

    function test_mint_toZeroAddressRevertsWithOzError() public {
        _wire();
        vm.prank(VAULT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1);
    }

    // ---------------------------------------------------------------- burnFrom

    function test_burnFrom_byEachBurnerWithoutAllowance() public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 40);
        address[4] memory burners = [VAULT, STRATEGY, LEDGER, SHUTDOWN];
        for (uint256 i = 0; i < 4; ++i) {
            vm.expectEmit(address(token));
            emit IERC20.Transfer(ALICE, address(0), 10);
            vm.prank(burners[i]);
            token.burnFrom(ALICE, 10);
            assertEq(token.balanceOf(ALICE), 40 - 10 * (i + 1));
        }
        assertEq(token.totalSupply(), 0);
    }

    /// @dev burnFrom and moveFrom neither need nor spend an allowance: a preset one is untouched.
    function test_burnFromAndMoveFrom_leaveAllowancesUntouched() public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 10);
        vm.startPrank(ALICE);
        token.approve(LEDGER, 3);
        token.approve(STRATEGY, 4);
        vm.stopPrank();
        vm.prank(LEDGER);
        token.burnFrom(ALICE, 5);
        vm.prank(STRATEGY);
        token.moveFrom(ALICE, BOB, 5);
        assertEq(token.allowance(ALICE, LEDGER), 3);
        assertEq(token.allowance(ALICE, STRATEGY), 4);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_burnFrom_nonBurnerUnauthorized(address caller) public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 1);
        vm.prank(caller);
        if (_isRole(caller)) {
            token.burnFrom(ALICE, 1);
            assertEq(token.totalSupply(), 0);
            return;
        }
        vm.expectRevert(Unauthorized.selector);
        token.burnFrom(ALICE, 1);
    }

    function test_burnFrom_aboveBalanceRevertsWithOzError() public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 5);
        vm.prank(LEDGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5, 6));
        token.burnFrom(ALICE, 6);
    }

    // ---------------------------------------------------------------- moveFrom

    function test_moveFrom_byStrategyWithoutAllowance() public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 9);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(ALICE, BOB, 4);
        vm.prank(STRATEGY);
        token.moveFrom(ALICE, BOB, 4);
        assertEq(token.balanceOf(ALICE), 5);
        assertEq(token.balanceOf(BOB), 4);
        assertEq(token.totalSupply(), 9);
    }

    function testFuzz_moveFrom_onlyStrategy(address caller) public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 1);
        vm.prank(caller);
        if (caller == STRATEGY) {
            token.moveFrom(ALICE, BOB, 1);
            assertEq(token.balanceOf(BOB), 1);
            return;
        }
        vm.expectRevert(Unauthorized.selector);
        token.moveFrom(ALICE, BOB, 1);
    }

    function test_moveFrom_otherBurnersUnauthorized() public {
        _wire();
        address[3] memory others = [VAULT, LEDGER, SHUTDOWN];
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(Unauthorized.selector);
            token.moveFrom(ALICE, BOB, 0);
        }
    }

    function test_moveFrom_aboveBalanceAndToZeroRevertWithOzErrors() public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 3);
        vm.startPrank(STRATEGY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 3, 4));
        token.moveFrom(ALICE, BOB, 4);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.moveFrom(ALICE, address(0), 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- ERC-20 after wiring

    function test_transferFromStillNeedsAnAllowanceForEveryoneElse() public {
        _wire();
        vm.prank(VAULT);
        token.mint(ALICE, 10);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        // the roles' privileges cover only their own functions, not transferFrom
        vm.prank(STRATEGY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, STRATEGY, 0, 1)
        );
        token.transferFrom(ALICE, BOB, 1);
    }
}
