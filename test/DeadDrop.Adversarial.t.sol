// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeadDropFixture} from "./support/DeadDropFixture.sol";
import {DeadDrop} from "src/DeadDrop.sol";
import {PoolKey} from "src/interfaces/IPoolManager.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DeadDropAdversarialTest is DeadDropFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitConservesOutputAndRoundsOnlyTowardBurn(
        uint256 tip,
        uint256 output,
        uint256 newStamp,
        bool refund
    ) public virtual {
        tip = bound(tip, 0, uint256(uint128(type(int128).max)) - 1e18);
        output = bound(output, 0, POOL_DROP);
        newStamp = bound(newStamp, 0.01e18, 1e18);
        vm.prank(owner);
        dd.setStamp(newStamp);
        uint256 total = newStamp + tip;
        imd.mint(alice, total);
        // A quote with an exactly controllable output, independent of the allocation under test.
        pm.setRate(output, total);
        uint256 id = _leave(alice, bob, tip);
        (,,,,, uint256 escrow) = dd.notes(id);
        uint256 burned = drop.balanceOf(BURN);
        assertEq(escrow + burned, output, "no output lost or manufactured");
        assertEq(drop.balanceOf(address(dd)), escrow, "escrow is actually backed");
        assertEq(drop.balanceOf(address(pm)), POOL_DROP - output);
        assertEq(imd.balanceOf(address(pm)), total);
        assertEq(imd.balanceOf(address(dd)), 0);
        // Cross multiplication checks the floor interval without duplicating the division.
        assertLe(escrow * total, output * tip, "recipient cannot receive rounding dust");
        assertLt(output * tip, (escrow + 1) * total, "less than one DROP unit of dust");
        assertEq(dd.totalDropBurned(), burned);
        assertEq(dd.totalImdSpent(), total);
        if (refund) {
            vm.warp(vm.getBlockTimestamp() + 14 days);
            vm.prank(alice);
            dd.takeBack(id);
            assertEq(drop.balanceOf(alice), escrow);
            assertEq(dd.earned(alice), 0, "refund is not earnings");
        } else {
            vm.prank(bob);
            dd.answer(id, hex"02");
            assertEq(drop.balanceOf(bob), escrow);
            assertEq(dd.earned(bob), escrow);
        }
        assertEq(drop.balanceOf(address(dd)), 0);
        assertEq(drop.balanceOf(BURN), burned, "stamp never returned");
        assertEq(drop.totalSupply(), 1e27);
    }

    function test_oneUnitOutputAndOneWeiTipHaveNoHiddenDust() public {
        pm.setRate(1, INITIAL_STAMP + 1);
        _leave(alice, bob, 1);
        assertEq(drop.balanceOf(BURN), 1);
        assertEq(drop.balanceOf(address(dd)), 0);
        (,,,,, uint256 escrow) = dd.notes(1);
        assertEq(escrow, 0);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(alice);
        dd.takeBack(1);
        (,,, bool refunded,,) = dd.notes(1);
        assertTrue(refunded, "zero escrow still has a terminal state");
        assertEq(dd.answeredCount(), 0);
    }

    function test_freeNoteCanRefundZeroEscrow() public {
        _leave(alice, bob, 0);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(alice);
        dd.takeBack(1);
        assertEq(drop.balanceOf(address(dd)), 0);
        assertEq(drop.balanceOf(BURN), INITIAL_STAMP);
        assertEq(drop.balanceOf(alice), 0);
        (,,, bool refunded,,) = dd.notes(1);
        assertTrue(refunded);
    }

    function test_largestSignedPoolInputSettlesWithoutTruncation() public {
        uint256 input = uint256(uint128(type(int128).max));
        imd.mint(alice, input);
        pm.setRate(POOL_DROP, input);
        uint256 id = _leave(alice, bob, input - INITIAL_STAMP);
        assertEq(pm.lastAmountIn(), input);
        assertEq(drop.balanceOf(address(pm)), 0, "entire available DROP output");
        (,,,,, uint256 escrow) = dd.notes(id);
        assertEq(drop.balanceOf(BURN) + escrow, POOL_DROP);
        assertEq(imd.balanceOf(address(pm)), input);
        vm.prank(bob);
        dd.answer(id, hex"ff");
        assertEq(drop.balanceOf(bob), escrow);
    }

    function test_noteAndReplyAcceptMaximumLengthAndEmitExactOpaqueBytes() public {
        bytes memory message = new bytes(1024);
        message[0] = 0xff;
        message[511] = 0x80;
        message[1023] = 0x01;
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.Left(1, alice, bob, 1, 1, message);
        vm.prank(alice);
        dd.leave(bob, message, 1, INITIAL_STAMP + 1);
        vm.expectEmit(true, false, false, true, address(dd));
        emit DeadDrop.Answered(1, message);
        vm.prank(bob);
        dd.answer(1, message);
        assertEq(drop.balanceOf(bob), 1);
    }

    function test_keyAndPriceChangesCannotRewriteAnExistingNote() public {
        uint256 id = _leave(alice, bob, 7e18);
        uint256 deadline = dd.takeBackAt(id);
        vm.prank(bob);
        dd.openDrop(keccak256("rotated recipient key"), type(uint256).max);
        vm.prank(alice);
        dd.openDrop(keccak256("rotated sender key"), type(uint256).max);
        vm.prank(owner);
        dd.setStamp(1e18);
        assertEq(dd.takeBackAt(id), deadline);
        vm.warp(deadline + 1);
        vm.prank(bob);
        dd.answer(id, hex"01");
        assertEq(drop.balanceOf(bob), 7e18, "answers remain possible after the refund deadline");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.AlreadyAnswered.selector, id));
        dd.takeBack(id);
    }

    function test_priceIncreaseRejectsAStaleTipBeforeTokenInteraction() public {
        vm.prank(bob);
        dd.setPrice(3e18);
        vm.prank(alice);
        imd.approve(address(dd), 0);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.TipBelowPrice.selector, 3e18, 2e18));
        dd.leave(bob, hex"01", 2e18, 0);
        assertEq(_state(), beforeState);
    }

    function test_invalidBytesRejectBeforePullAndDoNotConsumeId() public {
        _leave(alice, bob, 2e18);
        vm.prank(alice);
        imd.approve(address(dd), 0);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.BadLength.selector, 1025));
        dd.leave(bob, new bytes(1025), 1e18, 0);
        assertEq(_state(), beforeState);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.BadLength.selector, 1025));
        dd.answer(1, new bytes(1025));
        assertEq(_state(), beforeState);
        vm.prank(bob);
        dd.answer(1, hex"01");
        assertEq(drop.balanceOf(bob), 2e18);
    }

    function test_unknownZeroAndMaximumIdsDoNotMutateCustody() public {
        _leave(alice, bob, 2e18);
        uint256[3] memory unknown = [uint256(0), uint256(2), type(uint256).max];
        bytes32 beforeState = _state();
        for (uint256 i; i < unknown.length; ++i) {
            uint256 id = unknown[i];
            assertEq(dd.takeBackAt(id), 0);
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(DeadDrop.UnknownNote.selector, id));
            dd.answer(id, hex"01");
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(DeadDrop.UnknownNote.selector, id));
            dd.takeBack(id);
        }
        assertEq(_state(), beforeState);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedSwapRollsBackBalancesAllowancesRecordsAndTotals(uint8 failure, bool knock) public virtual {
        _leave(alice, bob, 3e18); // Existing custody must survive each failure as well.
        failure = uint8(bound(failure, 0, 4));
        uint256 amount = knock ? INITIAL_STAMP : INITIAL_STAMP + 1e18;
        vm.prank(alice);
        imd.approve(address(dd), amount);
        bytes memory expected;
        uint256 minOut;
        if (failure == 0) {
            minOut = amount + 1;
            expected = abi.encodeWithSelector(DeadDrop.InsufficientOutput.selector, amount, minOut);
        } else if (failure == 1) {
            pm.setMaxIn(amount - 1);
            expected = abi.encodeWithSelector(DeadDrop.PartialSwap.selector, amount, amount - 1);
        } else if (failure == 2) {
            pm.setInitialized(false);
            expected = abi.encodeWithSelector(MockPoolManager.PoolNotInitialized.selector);
        } else if (failure == 3) {
            PoolKey memory wrongKey = dd.poolKey();
            wrongKey.fee += 1;
            pm.setPool(wrongKey);
            expected = abi.encodeWithSelector(MockPoolManager.WrongPool.selector);
        } else {
            // Insufficient output-token reserves fails after transferFrom has spent allowance.
            pm.setRate(POOL_DROP, amount);
            expected = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(pm), drop.balanceOf(address(pm)), POOL_DROP
            );
        }
        bytes32 beforeState = _state();
        vm.expectRevert(expected);
        vm.prank(alice);
        if (knock) dd.knock(closed, minOut);
        else dd.leave(bob, hex"01", 1e18, minOut);
        assertEq(_state(), beforeState, "failure is atomic even after settlement");

        pm.setInitialized(true);
        pm.setMaxIn(0);
        pm.setPool(dd.poolKey());
        pm.setRate(1, 1);
        vm.prank(alice);
        if (knock) dd.knock(closed, amount);
        else assertEq(dd.leave(bob, hex"01", 1e18, amount), 2, "failure cannot skip ids");
        assertEq(imd.allowance(alice, address(dd)), 0, "retry spends the restored allowance");
        assertFalse(pm.unlocked());
        vm.prank(address(pm));
        vm.expectRevert(DeadDrop.NotUnlocking.selector);
        dd.unlockCallback(abi.encode(amount));
    }

    function test_insufficientBalanceRollsBackFiniteAllowance() public {
        uint256 amount = USER_IMD + 1;
        vm.prank(alice);
        imd.approve(address(dd), amount);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, USER_IMD, amount));
        dd.leave(bob, hex"01", amount - INITIAL_STAMP, 0);
        assertEq(_state(), beforeState);
    }

    function test_insufficientAllowanceCannotBorrowFromOtherEscrows() public {
        _leave(alice, bob, 5e18);
        vm.prank(carol);
        imd.approve(address(dd), INITIAL_STAMP - 1);
        bytes32 beforeState = _state();
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(dd), INITIAL_STAMP - 1, INITIAL_STAMP
            )
        );
        dd.knock(closed, 0);
        assertEq(_state(), beforeState);
    }

    function test_knocksRemainAccountedWhenRecipientLaterOpens() public {
        vm.prank(alice);
        dd.knock(closed, INITIAL_STAMP);
        vm.prank(bob);
        dd.knock(closed, INITIAL_STAMP);
        vm.prank(closed);
        dd.openDrop(keccak256("new inbox"), 0);
        bytes32 beforeState = _state();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.HasDrop.selector, closed));
        dd.knock(closed, 0);
        assertEq(_state(), beforeState);
        assertEq(dd.knocks(closed), 2);
        assertEq(dd.knockCount(), 2);
        assertEq(dd.noteCount(), 0);
        assertEq(_leave(alice, closed, 0), 1);
    }

    function test_pendingAndFormerOwnerCannotChangeStamp() public {
        _leave(alice, bob, 1e18);
        vm.prank(owner);
        dd.transferOwnership(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        dd.setStamp(1e18);
        vm.prank(owner);
        dd.transferOwnership(bob); // supersede the pending owner
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        dd.acceptOwnership();
        vm.prank(bob);
        dd.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        dd.setStamp(1e18);
        vm.prank(bob);
        dd.setStamp(1e18);
        (,,,,, uint256 escrow) = dd.notes(1);
        assertEq(escrow, 1e18);
        assertEq(drop.balanceOf(address(dd)), escrow);
        assertEq(dd.pendingOwner(), address(0));
    }

    function test_ownerCannotAnswerOrRefundSomebodyElsesNote() public {
        _leave(alice, bob, 1e18);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        bytes32 beforeState = _state();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NotRecipient.selector, 1));
        dd.answer(1, hex"01");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NotSender.selector, 1));
        dd.takeBack(1);
        assertEq(_state(), beforeState);
    }
}

contract DeadDropAdversarialReverseOrderTest is DeadDropAdversarialTest {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitConservesOutputAndRoundsOnlyTowardBurn(
        uint256 tip,
        uint256 output,
        uint256 newStamp,
        bool refund
    ) public override {
        super.testFuzz_splitConservesOutputAndRoundsOnlyTowardBurn(tip, output, newStamp, refund);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedSwapRollsBackBalancesAllowancesRecordsAndTotals(uint8 failure, bool knock) public override {
        super.testFuzz_failedSwapRollsBackBalancesAllowancesRecordsAndTotals(failure, knock);
    }

    function reverseOrder() internal pure override returns (bool) {
        return true;
    }
}
