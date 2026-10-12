// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenPropertiesTest is Test {
    LaunchToken internal token;
    address internal alice = makeAddr("token holder");
    address internal bob = makeAddr("token spender");
    address internal carol = makeAddr("token recipient");

    function setUp() public {
        vm.prank(alice);
        token = new LaunchToken();
    }

    function test_zeroSelfAndEntireSupplyTransfersRemainPlain() public {
        uint256 supply = 1e27;
        vm.startPrank(alice);
        assertTrue(token.transfer(bob, 0));
        assertTrue(token.transfer(alice, supply));
        assertEq(token.balanceOf(alice), supply);
        assertTrue(token.transfer(bob, supply));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), supply);
        vm.prank(bob);
        assertTrue(token.transfer(alice, supply));
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(alice), supply);
    }

    function test_zeroRecipientAndZeroSpenderRevertWithoutBurning() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_infiniteApprovalDoesNotDecreaseAndCanBeRevoked() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1e27);
        assertEq(token.balanceOf(carol), 1e27);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(carol);
        token.transfer(alice, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        assertEq(token.balanceOf(alice), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactAllowanceMovesNoFeesAndCannotBeReused(uint256 amount) public {
        amount = bound(amount, 1, 1e27);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, amount));
        assertEq(token.balanceOf(carol), amount);
        assertEq(token.balanceOf(alice), 1e27 - amount);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_insufficientBalanceAndInvalidReceiverRestoreSpentAllowance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e27, 1e27 + 1));
        token.transferFrom(alice, carol, 1e27 + 1);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1);
        assertEq(token.balanceOf(alice), 1e27);
    }
}

contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(LaunchToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        balances[actors_[0]] = 1e27;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        amount = unlimited ? type(uint256).max : bound(amount, 0, 1e27);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        allowances[owner][spender] = amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount, bool overdraw) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        amount = overdraw ? balances[from] + 1 : bound(amount, 0, balances[from]);
        vm.prank(from);
        if (overdraw) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balances[from], amount)
            );
            token.transfer(to, amount);
        } else {
            assertTrue(token.transfer(to, amount));
            balances[from] -= amount;
            balances[to] += amount;
        }
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        amount = bound(amount, 0, 1e27 + 1);
        uint256 allowed = allowances[owner][spender];
        bytes memory expected;
        if (allowed < amount) {
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        } else if (balances[owner] < amount) {
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balances[owner], amount);
        }
        vm.prank(spender);
        if (expected.length != 0) {
            vm.expectRevert(expected);
            token.transferFrom(owner, to, amount);
        } else {
            assertTrue(token.transferFrom(owner, to, amount));
            balances[owner] -= amount;
            balances[to] += amount;
            if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
        }
    }

    /// @dev Forces successful delegated spending too; arbitrary allowances often cannot cover it.
    function spendApproved(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 limit = balances[owner];
        if (allowances[owner][spender] < limit) limit = allowances[owner][spender];
        transferFrom(ownerSeed, spenderSeed, toSeed, bound(amount, 0, limit));
    }

    function assertLedger() external view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = actors[i];
            assertEq(token.balanceOf(actor), balances[actor]);
            sum += token.balanceOf(actor);
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actor, actors[j]), allowances[actor][actors[j]]);
            }
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
    }
}

contract LaunchTokenInvariantTest is Test {
    LaunchTokenHandler internal handler;

    function setUp() public {
        address[4] memory actors = [makeAddr("token A"), makeAddr("token B"), makeAddr("token C"), makeAddr("token D")];
        vm.prank(actors[0]);
        LaunchToken token = new LaunchToken();
        handler = new LaunchTokenHandler(token, actors);
        handler.approve(0, 1, 1e26, false);
        handler.spendApproved(0, 1, 2, 1e25);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.spendApproved.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_fixedSupplyBalancesAndAllowances() public view {
        handler.assertLedger();
    }
}
