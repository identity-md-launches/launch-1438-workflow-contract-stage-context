// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeadDrop} from "src/DeadDrop.sol";
import {AdversarialERC20} from "./mocks/AdversarialERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract DeadDropTokenFailuresTest is Test {
    address internal constant BURN = address(0xdead);
    address internal alice = makeAddr("fault sender");
    address internal bob = makeAddr("fault recipient");
    address internal closed = makeAddr("fault closed inbox");
    AdversarialERC20 internal imd;
    AdversarialERC20 internal drop;
    MockPoolManager internal pm;
    DeadDrop internal dd;

    function setUp() public {
        imd = new AdversarialERC20();
        drop = new AdversarialERC20();
        pm = new MockPoolManager();
        dd = new DeadDrop(address(this), address(drop), address(imd), address(pm), makeAddr("test hook"));
        pm.setPool(dd.poolKey());
        pm.track(address(imd));
        pm.track(address(drop));
        drop.mint(address(pm), 1_000e18);
        imd.mint(alice, 100e18);
        vm.startPrank(alice);
        dd.openDrop(keccak256("sender key"), 0);
        imd.approve(address(dd), 100e18);
        vm.stopPrank();
        vm.prank(bob);
        dd.openDrop(keccak256("recipient key"), 0);
        vm.warp(1_800_000_000);
    }

    function _leave() internal {
        vm.prank(alice);
        dd.leave(bob, hex"01", 2e18, 0);
    }

    function _snapshot() internal view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                dd.noteCount(),
                dd.answeredCount(),
                dd.knockCount(),
                dd.knocks(closed),
                dd.totalImdSpent(),
                dd.totalDropBurned(),
                dd.earned(bob)
            )
        );
        address[5] memory accounts = [alice, bob, address(dd), address(pm), BURN];
        for (uint256 i; i < accounts.length; ++i) {
            state = keccak256(abi.encode(state, imd.balanceOf(accounts[i]), drop.balanceOf(accounts[i])));
        }
        (address from, uint64 at, bool answered, bool refunded, address to, uint256 escrow) = dd.notes(1);
        state = keccak256(abi.encode(state, from, at, answered, refunded, to, escrow));
        state = keccak256(
            abi.encode(
                state,
                imd.allowance(alice, address(dd)),
                pm.swapCount(),
                pm.unlocked(),
                pm.currencyDelta(address(imd)),
                pm.currencyDelta(address(drop))
            )
        );
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_falseOrRevertingTokenRollsBackLeaveAndKnock(uint8 leg, bool tokenReverts, bool knocking) public {
        leg = uint8(bound(leg, 0, 2));
        _leave(); // A failure must not disturb funds that belong to an earlier note.
        AdversarialERC20 selected = leg == 2 ? drop : imd;
        address from = leg == 0 ? alice : address(dd);
        address to = leg == 0 ? address(dd) : (leg == 1 ? address(pm) : BURN);
        selected.configure(
            tokenReverts ? AdversarialERC20.Behavior.RevertTransfer : AdversarialERC20.Behavior.ReturnFalse, from, to
        );
        bytes32 beforeState = _snapshot();
        bytes memory expected = tokenReverts
            ? abi.encodeWithSelector(AdversarialERC20.TokenTransferRejected.selector)
            : abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(selected));
        vm.expectRevert(expected);
        vm.prank(alice);
        if (knocking) dd.knock(closed, 0);
        else dd.leave(bob, hex"02", 2e18, 0);
        assertEq(_snapshot(), beforeState, "no partial token or note effects");
        selected.configure(AdversarialERC20.Behavior.Normal, from, to);
        vm.prank(alice);
        if (knocking) dd.knock(closed, 0);
        else assertEq(dd.leave(bob, hex"02", 2e18, 0), 2);
    }

    function test_failedAnswerTransferRestoresClaimAndCanBeRetried() public {
        _leave();
        drop.configure(AdversarialERC20.Behavior.ReturnFalse, address(dd), bob);
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(drop)));
        dd.answer(1, hex"02");
        assertEq(_snapshot(), beforeState);
        drop.configure(AdversarialERC20.Behavior.Normal, address(dd), bob);
        vm.prank(bob);
        dd.answer(1, hex"02");
        assertEq(drop.balanceOf(bob), 2e18);
        assertEq(dd.earned(bob), 2e18);
        assertEq(dd.answeredCount(), 1);
        assertEq(drop.balanceOf(address(dd)), 0);
    }

    function test_failedRefundTransferRestoresClaimAndCanBeRetried() public {
        _leave();
        vm.warp(vm.getBlockTimestamp() + 14 days);
        drop.configure(AdversarialERC20.Behavior.RevertTransfer, address(dd), alice);
        bytes32 beforeState = _snapshot();
        vm.prank(alice);
        vm.expectRevert(AdversarialERC20.TokenTransferRejected.selector);
        dd.takeBack(1);
        assertEq(_snapshot(), beforeState);
        drop.configure(AdversarialERC20.Behavior.Normal, address(dd), alice);
        vm.prank(alice);
        dd.takeBack(1);
        assertEq(drop.balanceOf(alice), 2e18);
        assertEq(drop.balanceOf(BURN), 0.1e18);
        assertEq(drop.balanceOf(address(dd)), 0);
        assertEq(dd.earned(alice), 0);
    }

    function test_noReturnTokensAreAcceptedBySafeTransfers() public {
        imd.configure(AdversarialERC20.Behavior.NoReturn, alice, address(dd));
        drop.configure(AdversarialERC20.Behavior.NoReturn, address(dd), BURN);
        _leave();
        imd.configure(AdversarialERC20.Behavior.NoReturn, address(dd), address(pm));
        vm.prank(alice);
        dd.knock(closed, 0);
        drop.configure(AdversarialERC20.Behavior.NoReturn, address(dd), bob);
        vm.prank(bob);
        dd.answer(1, hex"01");
        assertEq(drop.balanceOf(bob), 2e18);
        assertEq(drop.balanceOf(BURN), 0.2e18);
        assertEq(imd.balanceOf(address(pm)), 2.2e18);
        assertEq(drop.balanceOf(address(dd)), 0);
    }

    function test_feeOnSettlementCannotLeaveUnpaidPoolDebt() public {
        imd.configure(AdversarialERC20.Behavior.Fee, address(dd), address(pm));
        bytes32 beforeState = _snapshot();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockPoolManager.CurrencyNotSettled.selector, address(imd), -int256(0.021e18))
        );
        dd.leave(bob, hex"01", 2e18, 0);
        assertEq(_snapshot(), beforeState);
        assertEq(imd.totalSupply(), 100e18, "even token fee destruction rolls back");
    }

    function test_strangerCannotInvokeCallbackDuringTheContractsOwnUnlock() public {
        // This callback runs while _unlocking is true, during IMD settlement.
        // Checking only that flag, without authenticating the manager, is insufficient.
        imd.configure(AdversarialERC20.Behavior.Reenter, address(dd), address(pm));
        imd.setCallback(address(dd), abi.encodeCall(dd.unlockCallback, (abi.encode(uint256(2.1e18)))));
        _leave();
        assertEq(imd.callbackCount(), 1);
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(DeadDrop.NotPoolManager.selector));
        assertEq(dd.noteCount(), 1);
        assertEq(drop.balanceOf(address(dd)), 2e18);
        assertEq(drop.balanceOf(BURN), 0.1e18);
        assertEq(pm.swapCount(), 1);
        assertEq(pm.currencyDelta(address(imd)), 0);
        assertEq(pm.currencyDelta(address(drop)), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_allValueEntryPointsBlockTokenReentry(uint8 leg, uint8 entry) public {
        leg = uint8(bound(leg, 0, 4));
        entry = uint8(bound(entry, 0, 3));
        _leave();
        bytes memory attack;
        if (entry == 0) attack = abi.encodeCall(dd.leave, (bob, hex"01", 0, 0));
        else if (entry == 1) attack = abi.encodeCall(dd.answer, (1, hex"02"));
        else if (entry == 2) attack = abi.encodeCall(dd.takeBack, (1));
        else attack = abi.encodeCall(dd.knock, (closed, 0));
        AdversarialERC20 selected = leg < 2 ? imd : drop;
        address from = leg == 0 ? alice : address(dd);
        address to;
        if (leg == 0) to = address(dd);
        else if (leg == 1) to = address(pm);
        else if (leg == 2) to = BURN;
        else if (leg == 3) to = bob;
        else to = alice;
        selected.configure(AdversarialERC20.Behavior.Reenter, from, to);
        selected.setCallback(address(dd), attack);
        if (leg < 3) {
            _leave();
            assertEq(dd.noteCount(), 2);
            assertEq(drop.balanceOf(address(dd)), 4e18);
        } else if (leg == 3) {
            vm.prank(bob);
            dd.answer(1, hex"03");
            assertEq(drop.balanceOf(bob), 2e18);
            assertEq(dd.answeredCount(), 1);
        } else {
            vm.warp(vm.getBlockTimestamp() + 14 days);
            vm.prank(alice);
            dd.takeBack(1);
            assertEq(drop.balanceOf(alice), 2e18);
            assertEq(dd.answeredCount(), 0);
        }
        assertEq(selected.callbackCount(), 1, "the adversarial callback must actually execute");
        assertFalse(selected.callbackSucceeded());
        assertEq(
            selected.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(dd.knockCount(), 0, "reentry cannot buy or withdraw anything");
        assertEq(imd.balanceOf(address(dd)), 0);
        assertFalse(pm.unlocked());
    }
}
