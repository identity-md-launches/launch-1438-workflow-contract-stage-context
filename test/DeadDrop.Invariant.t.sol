// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeadDropFixture} from "./support/DeadDropFixture.sol";
import {DeadDropHandler} from "./handlers/DeadDropHandler.sol";

contract DeadDropInvariantTest is DeadDropFixture {
    DeadDropHandler internal handler;

    function setUp() public override {
        super.setUp();
        imd.mint(closed, USER_IMD);
        vm.prank(closed);
        imd.approve(address(dd), type(uint256).max);
        handler = new DeadDropHandler(
            dd, drop, imd, pm, address(this), owner, [alice, bob, carol, closed], makeAddr("never opened")
        );
        // Nonzero custody, a free note, an answered note, a refund, and a knock in every run.
        // All transitions still run through the same checked handler used by the fuzzer.
        handler.leave(0, 0, 3e18, 5, 1);
        handler.leave(1, 0, 0, 3, 1024);
        handler.leave(2, 0, 2e18, 7, 2);
        handler.answer(3, false);
        handler.leave(0, 1, 1e18, 2, 1);
        handler.takeBack(4, 0);
        handler.knock(0, 0, 2);
        handler.failedSwap(1, 3, false, false);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.register.selector;
        selectors[1] = handler.setPrice.selector;
        selectors[2] = handler.leave.selector;
        selectors[3] = handler.answer.selector;
        selectors[4] = handler.takeBack.selector;
        selectors[5] = handler.knock.selector;
        selectors[6] = handler.failedSwap.selector;
        selectors[7] = handler.stamp.selector;
        selectors[8] = handler.ownership.selector;
        selectors[9] = handler.advanceTime.selector;
        selectors[10] = handler.donate.selector;
        selectors[11] = handler.leave.selector; // weight note creation so sequences retain live custody
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_assetsConserveEscrowBurnsPayoutsAndDonations() public view virtual {
        handler.assertAccounting();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_recordsKeepAuthorizationAndTerminalStates() public view virtual {
        handler.assertStateMachine();
    }

    function afterInvariant() public {
        assertGt(handler.successfulLeaves(), 0);
        assertGt(handler.successfulKnocks(), 0);
        assertGt(handler.answers(), 0);
        assertGt(handler.refunds(), 0);
        assertGt(handler.rejectedCalls(), 0);
        handler.closeAll();
        handler.assertAccounting();
        handler.assertStateMachine();
    }

    function test_handlerExercisesBothSettlementOutcomesAndDonations() public {
        handler.donate(1e18, 0, true);
        handler.donate(2e18, 1, false);
        handler.register(3, keccak256("new key"), 5e18);
        handler.setPrice(2, 6e18);
        handler.stamp(1e18, true);
        handler.stamp(1e18, false);
        handler.ownership(1, 0);
        handler.ownership(1, 2);
        handler.leave(2, 0, 1, 0, 1024);
        handler.answer(1, true);
        handler.takeBack(1, 2);
        handler.failedSwap(0, 3, true, true);
        handler.assertAccounting();
        handler.assertStateMachine();
        afterInvariant();
    }
}

contract DeadDropInvariantReverseOrderTest is DeadDropInvariantTest {
    // Foundry does not inherit inline settings; configure the overrides explicitly.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_assetsConserveEscrowBurnsPayoutsAndDonations() public view override {
        handler.assertAccounting();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_recordsKeepAuthorizationAndTerminalStates() public view override {
        handler.assertStateMachine();
    }

    function reverseOrder() internal pure override returns (bool) {
        return true;
    }
}
