// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeadDrop} from "src/DeadDrop.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Bounded actors and an independent ledger. Only listed action selectors are fuzz targets.
///      Expected failures are checked explicitly; unexpected reverts must fail the campaign.
contract DeadDropHandler is Test {
    enum Status {
        Pending,
        Answered,
        Refunded
    }

    struct ModelNote {
        address from;
        address to;
        uint256 at;
        uint256 escrow;
        Status status;
    }

    DeadDrop public immutable dd;
    LaunchToken public immutable drop;
    MockERC20 public immutable imd;
    MockPoolManager public immutable pm;
    address public immutable reservoir;
    address public immutable neverOpened;
    address[4] public actors;
    mapping(uint256 => ModelNote) public modelNotes;
    mapping(address => bytes32) public modelKeys;
    mapping(address => uint256) public modelPrices;
    mapping(address => uint256) public paidImd;
    mapping(address => uint256) public paidDrop;
    mapping(address => uint256) public modelEarned;
    mapping(address => uint256) public modelKnocks;
    mapping(address => uint256) public donatedImdBy;

    uint256 public count;
    uint256 public answers;
    uint256 public refunds;
    uint256 public knockCount;
    uint256 public pendingEscrow;
    uint256 public totalEscrow;
    uint256 public outputBought;
    uint256 public inputSpent;
    uint256 public burned;
    uint256 public payouts;
    uint256 public donatedDrop;
    uint256 public donatedImd;
    uint256 public expectedStamp = 0.1e18;
    address public expectedOwner;
    address public expectedPendingOwner;
    uint256 public rejectedCalls;
    uint256 public successfulLeaves;
    uint256 public successfulKnocks;

    constructor(
        DeadDrop dd_,
        LaunchToken drop_,
        MockERC20 imd_,
        MockPoolManager pm_,
        address reservoir_,
        address owner_,
        address[4] memory actors_,
        address neverOpened_
    ) {
        dd = dd_;
        drop = drop_;
        imd = imd_;
        pm = pm_;
        reservoir = reservoir_;
        expectedOwner = owner_;
        actors = actors_;
        neverOpened = neverOpened_;
        for (uint256 i; i < 3; ++i) {
            modelKeys[actors[i]] = keccak256(abi.encode(actors[i]));
        }
    }

    function register(uint256 actorSeed, bytes32 key, uint256 price) public {
        address actor = actors[actorSeed % 4];
        if (key == bytes32(0)) key = bytes32(uint256(1));
        price = bound(price, 0, 20e18);
        vm.prank(actor);
        dd.openDrop(key, price);
        modelKeys[actor] = key;
        modelPrices[actor] = price;
    }

    function setPrice(uint256 actorSeed, uint256 price) public {
        address actor = actors[actorSeed % 4];
        price = bound(price, 0, 20e18);
        bytes memory expected;
        if (modelKeys[actor] == bytes32(0)) expected = abi.encodeWithSelector(DeadDrop.NoDrop.selector, actor);
        _checkedCall(actor, abi.encodeCall(dd.setPrice, (price)), expected);
        if (expected.length == 0) modelPrices[actor] = price;
    }

    function leave(uint256 fromSeed, uint256 toSeed, uint256 tipSeed, uint256 rateSeed, uint256 lengthSeed) public {
        address from = actors[fromSeed % 3];
        address to = actors[(fromSeed % 3 + 1 + toSeed % 2) % 3];
        uint256 tip = modelPrices[to] + bound(tipSeed, 0, 20e18);
        uint256 total = expectedStamp + tip;
        uint256 output = _quote(total, rateSeed);
        uint256 escrow = Math.mulDiv(output, tip, total);
        uint256 at = vm.getBlockTimestamp();
        vm.prank(from);
        uint256 id = dd.leave(to, new bytes(bound(lengthSeed, 1, 1024)), tip, output);
        assertEq(id, count + 1, "ids are contiguous and start at one");
        count++;
        modelNotes[id] = ModelNote(from, to, at, escrow, Status.Pending);
        pendingEscrow += escrow;
        totalEscrow += escrow;
        inputSpent += total;
        paidImd[from] += total;
        outputBought += output;
        burned += output - escrow;
        successfulLeaves++;
    }

    function answer(uint256 idSeed, bool unauthorized) public {
        uint256 id = bound(idSeed, 0, count + 1);
        ModelNote storage n = modelNotes[id];
        address caller = n.to == address(0) ? actors[1] : n.to;
        if (unauthorized) caller = _other(caller);
        bytes memory expected;
        if (id == 0 || id > count) expected = abi.encodeWithSelector(DeadDrop.UnknownNote.selector, id);
        else if (caller != n.to) expected = abi.encodeWithSelector(DeadDrop.NotRecipient.selector, id);
        else if (n.status == Status.Answered) expected = abi.encodeWithSelector(DeadDrop.AlreadyAnswered.selector, id);
        else if (n.status == Status.Refunded) expected = abi.encodeWithSelector(DeadDrop.AlreadyTakenBack.selector, id);
        _checkedCall(caller, abi.encodeCall(dd.answer, (id, hex"aabb")), expected);
        if (expected.length != 0) return;
        n.status = Status.Answered;
        pendingEscrow -= n.escrow;
        payouts += n.escrow;
        paidDrop[n.to] += n.escrow;
        modelEarned[n.to] += n.escrow;
        answers++;
    }

    /// @dev mode 0 advances to maturity, mode 1 uses current time, mode 2 tries a stranger.
    function takeBack(uint256 idSeed, uint8 mode) public {
        uint256 id = bound(idSeed, 0, count + 1);
        ModelNote storage n = modelNotes[id];
        mode %= 3;
        address caller = n.from == address(0) ? actors[0] : n.from;
        if (mode == 2) caller = _other(caller);
        uint256 deadline = n.at + 14 days;
        if (mode == 0 && id > 0 && id <= count && vm.getBlockTimestamp() < deadline) vm.warp(deadline);
        bytes memory expected;
        if (id == 0 || id > count) {
            expected = abi.encodeWithSelector(DeadDrop.UnknownNote.selector, id);
        } else if (caller != n.from) {
            expected = abi.encodeWithSelector(DeadDrop.NotSender.selector, id);
        } else if (n.status == Status.Answered) {
            expected = abi.encodeWithSelector(DeadDrop.AlreadyAnswered.selector, id);
        } else if (n.status == Status.Refunded) {
            expected = abi.encodeWithSelector(DeadDrop.AlreadyTakenBack.selector, id);
        } else if (vm.getBlockTimestamp() < deadline) {
            expected = abi.encodeWithSelector(DeadDrop.TooEarly.selector, id, deadline);
        }
        _checkedCall(caller, abi.encodeCall(dd.takeBack, (id)), expected);
        if (expected.length != 0) return;
        n.status = Status.Refunded;
        pendingEscrow -= n.escrow;
        payouts += n.escrow;
        paidDrop[n.from] += n.escrow;
        refunds++;
    }

    function knock(uint256 actorSeed, uint256 targetSeed, uint256 rateSeed) public {
        address from = actors[actorSeed % 4];
        address to = targetSeed % 2 == 0 ? neverOpened : actors[targetSeed % 4];
        uint256 output = _quote(expectedStamp, rateSeed);
        bytes memory expected;
        if (modelKeys[to] != bytes32(0)) expected = abi.encodeWithSelector(DeadDrop.HasDrop.selector, to);
        _checkedCall(from, abi.encodeCall(dd.knock, (to, output)), expected);
        if (expected.length != 0) return;
        knockCount++;
        modelKnocks[to]++;
        inputSpent += expectedStamp;
        paidImd[from] += expectedStamp;
        outputBought += output;
        burned += output;
        successfulKnocks++;
    }

    function failedSwap(uint256 actorSeed, uint256 rateSeed, bool partialFill, bool knocking) public {
        address from = actors[actorSeed % 3];
        address to = actors[(actorSeed % 3 + 1) % 3];
        uint256 tip = modelPrices[to] + 1;
        uint256 total = knocking ? expectedStamp : expectedStamp + tip;
        uint256 output = _quote(total, rateSeed);
        bytes memory expected;
        uint256 minOut;
        if (partialFill) {
            pm.setMaxIn(total - 1);
            expected = abi.encodeWithSelector(DeadDrop.PartialSwap.selector, total, total - 1);
        } else {
            minOut = output + 1;
            expected = abi.encodeWithSelector(DeadDrop.InsufficientOutput.selector, output, minOut);
        }
        bytes memory data = knocking
            ? abi.encodeCall(dd.knock, (neverOpened, minOut))
            : abi.encodeCall(dd.leave, (to, hex"01", tip, minOut));
        _checkedCall(from, data, expected);
        pm.setMaxIn(0);
    }

    function stamp(uint256 value, bool authorized) public {
        value = bound(value, 0.01e18, 1e18);
        address caller = authorized ? expectedOwner : _other(expectedOwner);
        bytes memory expected;
        if (!authorized) expected = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        _checkedCall(caller, abi.encodeCall(dd.setStamp, (value)), expected);
        if (authorized) expectedStamp = value;
    }

    /// @dev Includes superseding/cancelling a pending transfer and unauthorized acceptance.
    function ownership(uint256 actorSeed, uint8 mode) public {
        mode %= 4;
        if (mode < 2) {
            address next = mode == 0 ? actors[actorSeed % 4] : address(0);
            vm.prank(expectedOwner);
            dd.transferOwnership(next);
            expectedPendingOwner = next;
        } else {
            address caller =
                mode == 2 && expectedPendingOwner != address(0) ? expectedPendingOwner : _other(expectedPendingOwner);
            bytes memory expected;
            if (caller != expectedPendingOwner) {
                expected = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
            }
            _checkedCall(caller, abi.encodeCall(dd.acceptOwnership, ()), expected);
            if (expected.length == 0) {
                expectedOwner = caller;
                expectedPendingOwner = address(0);
            }
        }
    }

    function advanceTime(uint256 secondsForward) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 0, 28 days));
    }

    /// @dev Unsolicited balances are assets, never liabilities or counters for purchases.
    function donate(uint256 amount, uint256 actorSeed, bool isDrop) public {
        amount = bound(amount, 0, 10e18);
        if (isDrop) {
            vm.prank(reservoir);
            drop.transfer(address(dd), amount);
            donatedDrop += amount;
        } else {
            address actor = actors[actorSeed % 4];
            vm.prank(actor);
            imd.transfer(address(dd), amount);
            donatedImd += amount;
            donatedImdBy[actor] += amount;
        }
    }

    /// @dev Called only after a campaign, proving every remaining obligation can be discharged.
    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 14 days);
        for (uint256 id = 1; id <= count; ++id) {
            if (modelNotes[id].status == Status.Pending) {
                if (id % 2 == 0) answer(id, false);
                else takeBack(id, 0);
            }
        }
        assertEq(pendingEscrow, 0);
        assertEq(drop.balanceOf(address(dd)), donatedDrop, "no escrow stranded after all users exit");
    }

    function assertAccounting() external view {
        assertEq(drop.balanceOf(address(dd)), pendingEscrow + donatedDrop, "solvent after every action");
        assertEq(imd.balanceOf(address(dd)), donatedImd, "purchases cannot consume donations");
        assertEq(drop.balanceOf(address(pm)), 500_000_000e18 - outputBought);
        assertEq(imd.balanceOf(address(pm)), inputSpent);
        assertEq(drop.balanceOf(address(0xdead)), burned);
        assertEq(outputBought, pendingEscrow + payouts + burned, "every bought token accounted for");
        assertEq(totalEscrow, pendingEscrow + payouts);
        assertEq(dd.totalImdSpent(), inputSpent);
        assertEq(dd.totalDropBurned(), burned);
        assertEq(dd.noteCount(), count);
        assertEq(dd.answeredCount(), answers);
        assertEq(dd.knockCount(), knockCount);
        assertEq(pm.swapCount(), count + knockCount, "exactly one swap per purchase");
        assertFalse(pm.unlocked());
        assertEq(pm.currencyDelta(address(imd)), 0);
        assertEq(pm.currencyDelta(address(drop)), 0);
        uint256 balances =
            drop.balanceOf(reservoir) + drop.balanceOf(address(pm)) + drop.balanceOf(address(dd)) + burned;
        for (uint256 i; i < 4; ++i) {
            address actor = actors[i];
            assertEq(drop.balanceOf(actor), paidDrop[actor], "only the correct payee receives escrow");
            assertEq(imd.balanceOf(actor), 1_000_000e18 - paidImd[actor] - donatedImdBy[actor]);
            assertEq(dd.earned(actor), modelEarned[actor], "refunds do not count as earnings");
            assertEq(dd.knocks(actor), modelKnocks[actor]);
            balances += drop.balanceOf(actor);
        }
        assertEq(dd.knocks(neverOpened), modelKnocks[neverOpened]);
        assertEq(drop.totalSupply(), 1e27);
        assertEq(balances, 1e27, "burn address holds tokens; total supply is fixed");
    }

    function assertStateMachine() external view {
        uint256 outstanding;
        uint256 answered;
        uint256 refunded;
        for (uint256 id = 1; id <= count; ++id) {
            ModelNote memory n = modelNotes[id];
            (address from, uint64 at, bool isAnswered, bool isRefunded, address to, uint256 escrow) = dd.notes(id);
            assertEq(from, n.from);
            assertEq(to, n.to);
            assertEq(at, n.at);
            assertEq(escrow, n.escrow, "settings never rewrite past escrow");
            assertEq(dd.takeBackAt(id), n.at + 14 days);
            assertEq(isAnswered, n.status == Status.Answered, "terminal answers never reopen");
            assertEq(isRefunded, n.status == Status.Refunded, "terminal refunds never reopen");
            assertFalse(isAnswered && isRefunded, "a note can only pay out once");
            if (n.status == Status.Pending) outstanding += escrow;
            else if (n.status == Status.Answered) answered++;
            else refunded++;
        }
        assertEq(outstanding, pendingEscrow);
        assertEq(answered, answers);
        assertEq(refunded, refunds);
        assertEq(dd.owner(), expectedOwner);
        assertEq(dd.pendingOwner(), expectedPendingOwner);
        assertEq(dd.stamp(), expectedStamp);
        for (uint256 i; i < 4; ++i) {
            (bytes32 key, uint256 price) = dd.drops(actors[i]);
            assertEq(key, modelKeys[actors[i]]);
            assertEq(price, modelPrices[actors[i]]);
            assertEq(dd.hasDrop(actors[i]), key != bytes32(0));
        }
    }

    function _quote(uint256 input, uint256 rateSeed) internal returns (uint256) {
        uint256 num = rateSeed % 32;
        uint256 den = 1 + (rateSeed >> 8) % 17;
        pm.setRate(num, den);
        return input * num / den;
    }

    function _other(address actor) internal view returns (address) {
        return actor == actors[0] ? actors[1] : actors[0];
    }

    function _checkedCall(address caller, bytes memory data, bytes memory expected) internal {
        vm.prank(caller);
        (bool ok, bytes memory result) = address(dd).call(data);
        if (expected.length == 0) {
            assertTrue(ok, "valid action unexpectedly reverted");
        } else {
            assertFalse(ok, "invalid action succeeded");
            assertEq(result, expected, "unexpected revert reason");
            rejectedCalls++;
        }
    }
}
