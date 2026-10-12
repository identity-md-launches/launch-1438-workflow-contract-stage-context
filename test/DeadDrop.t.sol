// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DeadDrop} from "../src/DeadDrop.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PoolKey} from "../src/interfaces/IPoolManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager, ReentrantPoolManager, StrangerCaller} from "./mocks/MockPoolManager.sol";

/// @dev Runs with IMD placed at a low address, so IMD is currency0 and the swap is zeroForOne.
///      `DeadDropReverseOrderTest` re-runs every test with IMD above DROP.
contract DeadDropTest is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant HOOKS = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    uint256 internal constant STAMP = 0.1e18;

    address internal owner = makeAddr("owner");
    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    LaunchToken internal drop;
    MockERC20 internal imd;
    MockPoolManager internal pm;
    DeadDrop internal dd;

    bytes32 internal aliceKey = keccak256("alice x25519");
    bytes32 internal bobKey = keccak256("bob x25519");

    function _imdAddress() internal pure virtual returns (address) {
        return 0x1000000000000000000000000000000000000001;
    }

    function _expectImdIsCurrency0() internal pure virtual returns (bool) {
        return true;
    }

    function _deployPoolManager() internal virtual returns (MockPoolManager) {
        return new MockPoolManager();
    }

    function setUp() public virtual {
        vm.prank(factory);
        drop = new LaunchToken();

        MockERC20 impl = new MockERC20();
        vm.etch(_imdAddress(), address(impl).code);
        imd = MockERC20(_imdAddress());

        pm = _deployPoolManager();
        dd = new DeadDrop(owner, address(drop), address(imd), address(pm), HOOKS);
        assertEq(dd.IMD_IS_CURRENCY0(), _expectImdIsCurrency0(), "test ordering assumption");

        pm.setPool(dd.poolKey());
        pm.track(address(drop));
        pm.track(address(imd));
        // The pool's DROP side: the factory seeded liquidity with DROP.
        vm.prank(factory);
        drop.transfer(address(pm), 500_000_000e18);

        imd.mint(alice, 1_000e18);
        imd.mint(bob, 1_000e18);
        imd.mint(carol, 1_000e18);
        vm.prank(alice);
        imd.approve(address(dd), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(dd), type(uint256).max);
        vm.prank(carol);
        imd.approve(address(dd), type(uint256).max);

        vm.warp(1_700_000_000);
    }

    function _open(address who, bytes32 key, uint256 price) internal {
        vm.prank(who);
        dd.openDrop(key, price);
    }

    function _note(uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(uint8(i + 1));
        }
    }

    // ───────────────────────────── constructor / key ─────────────────────────────

    function test_constructorConfig() public view {
        assertEq(dd.owner(), owner);
        assertEq(address(dd.DROP()), address(drop));
        assertEq(address(dd.IMD()), address(imd));
        assertEq(address(dd.POOL_MANAGER()), address(pm));
        assertEq(dd.POOL_HOOKS(), HOOKS);
        assertEq(dd.stamp(), STAMP);
        assertEq(dd.noteCount(), 0);
    }

    function test_poolKeyIsSortedWithLaunchParameters() public view {
        PoolKey memory key = dd.poolKey();
        assertTrue(key.currency0 < key.currency1, "sorted");
        assertEq(key.fee, 12500);
        assertEq(key.tickSpacing, 60);
        assertEq(key.hooks, HOOKS);
        if (_expectImdIsCurrency0()) {
            assertEq(key.currency0, address(imd));
            assertEq(key.currency1, address(drop));
        } else {
            assertEq(key.currency0, address(drop));
            assertEq(key.currency1, address(imd));
        }
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DeadDrop(address(0), address(drop), address(imd), address(pm), HOOKS);
        vm.expectRevert(DeadDrop.ZeroAddress.selector);
        new DeadDrop(owner, address(0), address(imd), address(pm), HOOKS);
        vm.expectRevert(DeadDrop.ZeroAddress.selector);
        new DeadDrop(owner, address(drop), address(0), address(pm), HOOKS);
        vm.expectRevert(DeadDrop.ZeroAddress.selector);
        new DeadDrop(owner, address(drop), address(imd), address(0), HOOKS);
        vm.expectRevert(DeadDrop.ZeroAddress.selector);
        new DeadDrop(owner, address(drop), address(imd), address(pm), address(0));
        vm.expectRevert(DeadDrop.SameCurrency.selector);
        new DeadDrop(owner, address(drop), address(drop), address(pm), HOOKS);
    }

    function test_constructorMakesNoExternalCalls() public {
        // Deploy against addresses with no code at all: the launch runs constructors on an empty chain.
        address noCode1 = address(0xA11CE);
        address noCode2 = address(0xB0B);
        address noCode3 = address(0xC0DE);
        DeadDrop fresh = new DeadDrop(owner, noCode1, noCode2, noCode3, HOOKS);
        assertEq(address(fresh.DROP()), noCode1);
    }

    // ───────────────────────────── openDrop / setPrice ─────────────────────────────

    function test_openDropStoresKeyAndPrice() public {
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.DropOpened(alice, aliceKey, 5e18);
        _open(alice, aliceKey, 5e18);
        (bytes32 key, uint256 price) = dd.drops(alice);
        assertEq(key, aliceKey);
        assertEq(price, 5e18);
        assertTrue(dd.hasDrop(alice));
        assertFalse(dd.hasDrop(bob));
    }

    function test_openDropAgainReplacesBoth() public {
        _open(alice, aliceKey, 5e18);
        bytes32 newKey = keccak256("alice new key");
        _open(alice, newKey, 0);
        (bytes32 key, uint256 price) = dd.drops(alice);
        assertEq(key, newKey);
        assertEq(price, 0);
    }

    function test_openDropRejectsZeroKey() public {
        vm.prank(alice);
        vm.expectRevert(DeadDrop.KeyRequired.selector);
        dd.openDrop(bytes32(0), 1e18);
    }

    function test_setPriceChangesOnlyPrice() public {
        _open(alice, aliceKey, 5e18);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.PriceSet(alice, 7e18);
        dd.setPrice(7e18);
        (bytes32 key, uint256 price) = dd.drops(alice);
        assertEq(key, aliceKey);
        assertEq(price, 7e18);
    }

    function test_setPriceRequiresDrop() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NoDrop.selector, alice));
        dd.setPrice(1e18);
    }

    // ───────────────────────────── leave ─────────────────────────────

    function test_leaveSwapsBurnsStampShareAndEscrowsTip() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 2e18);
        pm.setRate(3, 1); // 1 IMD -> 3 DROP

        uint256 tip = 2e18;
        uint256 total = STAMP + tip;
        uint256 expectedOut = total * 3;
        uint256 expectedEscrow = expectedOut * tip / total;
        uint256 expectedBurn = expectedOut - expectedEscrow;
        bytes memory note = _note(100);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.Left(1, alice, bob, tip, expectedEscrow, note);
        uint256 id = dd.leave(bob, note, tip, expectedOut);

        assertEq(id, 1);
        assertEq(dd.noteCount(), 1);
        assertEq(imd.balanceOf(alice), 1_000e18 - total, "alice paid stamp + tip");
        assertEq(imd.balanceOf(address(pm)), total, "pool received the IMD");
        assertEq(imd.balanceOf(address(dd)), 0, "no IMD left behind");
        assertEq(drop.balanceOf(BURN), expectedBurn, "stamp share burned");
        assertEq(drop.balanceOf(address(dd)), expectedEscrow, "tip share escrowed");
        assertEq(expectedBurn, STAMP * 3, "stamp share is exactly pro rata here");
        assertEq(dd.totalImdSpent(), total);
        assertEq(dd.totalDropBurned(), expectedBurn);

        (address from, uint64 leftAt, bool answered, bool takenBack, address to, uint256 escrow) = dd.notes(1);
        assertEq(from, alice);
        assertEq(to, bob);
        assertEq(leftAt, uint64(block.timestamp));
        assertFalse(answered);
        assertFalse(takenBack);
        assertEq(escrow, expectedEscrow);
        assertEq(dd.takeBackAt(1), block.timestamp + 14 days);
        assertEq(dd.takeBackAt(99), 0);
        assertEq(pm.swapCount(), 1, "one exact-input swap");
        assertEq(pm.lastAmountIn(), total);
    }

    function test_leaveIdsStartAtOneAndIncrement() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        assertEq(dd.leave(bob, _note(1), 0, 0), 1);
        vm.prank(bob);
        assertEq(dd.leave(alice, _note(1024), 0, 0), 2);
        vm.prank(alice);
        assertEq(dd.leave(bob, _note(7), 1, 0), 3);
        assertEq(dd.noteCount(), 3);
    }

    function test_leaveFreeDropWithZeroTipBurnsEverything() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 0, 0);
        (,,,,, uint256 escrow) = dd.notes(1);
        assertEq(escrow, 0);
        assertEq(drop.balanceOf(BURN), STAMP); // rate 1:1
        assertEq(drop.balanceOf(address(dd)), 0);
    }

    function test_leaveTipAbovePriceIsAllowed() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 1e18);
        vm.prank(alice);
        dd.leave(bob, _note(1), 5e18, 0);
        (,,,,, uint256 escrow) = dd.notes(1);
        assertEq(escrow, (STAMP + 5e18) * 5e18 / (STAMP + 5e18));
    }

    function test_leaveRevertsWithoutSenderDrop() public {
        _open(bob, bobKey, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NoDrop.selector, alice));
        dd.leave(bob, _note(1), 0, 0);
    }

    function test_leaveRevertsWithoutRecipientDrop() public {
        _open(alice, aliceKey, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NoDrop.selector, bob));
        dd.leave(bob, _note(1), 0, 0);
    }

    function test_leaveRevertsToSelf() public {
        _open(alice, aliceKey, 0);
        vm.prank(alice);
        vm.expectRevert(DeadDrop.SelfNote.selector);
        dd.leave(alice, _note(1), 0, 0);
    }

    function test_leaveRevertsOnBadLength() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.BadLength.selector, 0));
        dd.leave(bob, "", 0, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.BadLength.selector, 1025));
        dd.leave(bob, _note(1025), 0, 0);
    }

    function test_leaveRevertsBelowPrice() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 2e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.TipBelowPrice.selector, 2e18, 2e18 - 1));
        dd.leave(bob, _note(1), 2e18 - 1, 0);
    }

    function test_leaveRevertsOnSlippage() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        pm.setRate(1, 2); // 1 IMD -> 0.5 DROP
        uint256 out = STAMP / 2;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.InsufficientOutput.selector, out, out + 1));
        dd.leave(bob, _note(1), 0, out + 1);
        assertEq(imd.balanceOf(alice), 1_000e18, "nothing pulled on revert");
    }

    function test_leaveRevertsWithoutAllowance() public {
        _open(alice, aliceKey, 0);
        _open(carol, keccak256("carol"), 0);
        vm.prank(carol);
        imd.approve(address(dd), 0);
        vm.prank(carol);
        vm.expectRevert();
        dd.leave(alice, _note(1), 0, 0);
    }

    function test_leaveRevertsWhenPoolNotInitialized() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        pm.setInitialized(false);
        vm.prank(alice);
        vm.expectRevert(MockPoolManager.PoolNotInitialized.selector);
        dd.leave(bob, _note(1), 0, 0);
    }

    function test_leaveRevertsOnPartialSwap() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        pm.setMaxIn(STAMP / 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.PartialSwap.selector, STAMP, STAMP / 2));
        dd.leave(bob, _note(1), 0, 0);
    }

    function test_leaveUsesStampAtTimeOfLeave() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        (,,,,, uint256 escrowBefore) = dd.notes(1);

        vm.prank(owner);
        dd.setStamp(1e18);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);

        (,,,,, uint256 escrowStill) = dd.notes(1);
        (,,,,, uint256 escrowAfter) = dd.notes(2);
        assertEq(escrowStill, escrowBefore, "earlier note untouched");
        assertEq(escrowAfter, 2e18 * 1e18 / 2e18, "later note pays the new stamp");
        assertEq(dd.totalImdSpent(), (STAMP + 1e18) + 2e18);
    }

    // ───────────────────────────── answer ─────────────────────────────

    function test_answerPaysEscrowToRecipient() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 3e18);
        vm.prank(alice);
        dd.leave(bob, _note(10), 3e18, 0);
        (,,,,, uint256 escrow) = dd.notes(1);
        assertGt(escrow, 0);

        bytes memory reply = _note(50);
        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.Answered(1, reply);
        dd.answer(1, reply);

        assertEq(drop.balanceOf(bob), escrow);
        assertEq(drop.balanceOf(address(dd)), 0);
        assertEq(dd.earned(bob), escrow);
        assertEq(dd.answeredCount(), 1);
        (,, bool answered,,,) = dd.notes(1);
        assertTrue(answered);
    }

    function test_answerFreeNoteWorksWithZeroEscrow() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 0, 0);
        vm.prank(bob);
        dd.answer(1, _note(1));
        assertEq(drop.balanceOf(bob), 0);
        assertEq(dd.answeredCount(), 1);
    }

    function test_answerRejectsNonRecipient() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NotRecipient.selector, 1));
        dd.answer(1, _note(1));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NotRecipient.selector, 1));
        dd.answer(1, _note(1));
    }

    function test_answerRejectsUnknownNote() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.UnknownNote.selector, 1));
        dd.answer(1, _note(1));
    }

    function test_answerOnlyOnce() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.prank(bob);
        dd.answer(1, _note(1));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.AlreadyAnswered.selector, 1));
        dd.answer(1, _note(1));
    }

    function test_answerRejectsBadLength() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.BadLength.selector, 0));
        dd.answer(1, "");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.BadLength.selector, 1025));
        dd.answer(1, _note(1025));
    }

    function test_answerRejectedAfterTakeBack() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.warp(block.timestamp + 14 days);
        vm.prank(alice);
        dd.takeBack(1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.AlreadyTakenBack.selector, 1));
        dd.answer(1, _note(1));
    }

    // ───────────────────────────── takeBack ─────────────────────────────

    function test_takeBackReturnsEscrowAfter14Days() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        (,,,,, uint256 escrow) = dd.notes(1);
        uint256 burned = drop.balanceOf(BURN);

        vm.warp(block.timestamp + 14 days);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.TakenBack(1, escrow);
        dd.takeBack(1);

        assertEq(drop.balanceOf(alice), escrow, "escrow returned in DROP");
        assertEq(drop.balanceOf(address(dd)), 0);
        assertEq(drop.balanceOf(BURN), burned, "stamp never returned");
        assertEq(imd.balanceOf(alice), 1_000e18 - STAMP - 1e18, "no IMD returned");
        (,,, bool takenBack,,) = dd.notes(1);
        assertTrue(takenBack);
    }

    function test_takeBackTooEarly() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        uint256 at = block.timestamp + 14 days;
        vm.warp(at - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.TooEarly.selector, 1, at));
        dd.takeBack(1);
    }

    function test_takeBackRejectsNonSender() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.warp(block.timestamp + 14 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.NotSender.selector, 1));
        dd.takeBack(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.UnknownNote.selector, 2));
        dd.takeBack(2);
    }

    function test_takeBackRejectedAfterAnswer() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.prank(bob);
        dd.answer(1, _note(1));
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.AlreadyAnswered.selector, 1));
        dd.takeBack(1);
    }

    function test_takeBackOnlyOnce() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        vm.warp(block.timestamp + 14 days);
        vm.prank(alice);
        dd.takeBack(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.AlreadyTakenBack.selector, 1));
        dd.takeBack(1);
    }

    // ───────────────────────────── knock ─────────────────────────────

    function test_knockBurnsOneStamp() public {
        pm.setRate(2, 1);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.Knocked(bob, alice);
        dd.knock(bob, STAMP * 2);

        assertEq(imd.balanceOf(alice), 1_000e18 - STAMP);
        assertEq(drop.balanceOf(BURN), STAMP * 2);
        assertEq(drop.balanceOf(address(dd)), 0);
        assertEq(dd.knockCount(), 1);
        assertEq(dd.knocks(bob), 1);
        assertEq(dd.totalImdSpent(), STAMP);
        assertEq(dd.totalDropBurned(), STAMP * 2);
        assertEq(dd.noteCount(), 0, "a knock is not a note");
    }

    function test_knockRejectsWalletWithDrop() public {
        _open(bob, bobKey, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.HasDrop.selector, bob));
        dd.knock(bob, 0);
    }

    function test_knockRevertsOnSlippage() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.InsufficientOutput.selector, STAMP, STAMP + 1));
        dd.knock(bob, STAMP + 1);
    }

    function test_knockDoesNotRequireSenderDrop() public {
        vm.prank(alice);
        dd.knock(bob, 0);
        assertEq(dd.knocks(bob), 1);
    }

    // ───────────────────────────── owner ─────────────────────────────

    function test_setStampBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.StampOutOfRange.selector, 0.01e18 - 1));
        dd.setStamp(0.01e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.StampOutOfRange.selector, 1e18 + 1));
        dd.setStamp(1e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(DeadDrop.StampOutOfRange.selector, 0));
        dd.setStamp(0);
        dd.setStamp(0.01e18);
        assertEq(dd.stamp(), 0.01e18);
        vm.expectEmit(true, true, true, true, address(dd));
        emit DeadDrop.StampSet(1e18);
        dd.setStamp(1e18);
        assertEq(dd.stamp(), 1e18);
        vm.stopPrank();
    }

    function test_setStampOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        dd.setStamp(0.5e18);
    }

    function test_ownershipIsTwoStepAndNotRenounceable() public {
        vm.prank(owner);
        dd.transferOwnership(alice);
        assertEq(dd.owner(), owner, "still owner until accepted");
        assertEq(dd.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        dd.acceptOwnership();
        vm.prank(alice);
        dd.acceptOwnership();
        assertEq(dd.owner(), alice);

        vm.prank(alice);
        vm.expectRevert(DeadDrop.RenounceDisabled.selector);
        dd.renounceOwnership();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        dd.renounceOwnership();
        assertEq(dd.owner(), alice);
    }

    function test_ownerCannotMoveEscrow() public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        vm.prank(alice);
        dd.leave(bob, _note(1), 1e18, 0);
        uint256 held = drop.balanceOf(address(dd));
        assertGt(held, 0);

        string[5] memory signatures = [
            "withdraw(address,uint256)",
            "sweep(address)",
            "rescue(address,address,uint256)",
            "pause()",
            "answer(uint256,bytes)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(dd).call(abi.encodeWithSignature(signatures[i], address(drop), owner, held));
            assertFalse(ok, signatures[i]);
        }
        assertEq(drop.balanceOf(address(dd)), held);
    }

    // ───────────────────────────── callback / reentrancy ─────────────────────────────

    function test_unlockCallbackRejectsStrangers() public {
        vm.prank(alice);
        vm.expectRevert(DeadDrop.NotPoolManager.selector);
        dd.unlockCallback(abi.encode(uint256(1)));
        StrangerCaller stranger = new StrangerCaller();
        vm.expectRevert(DeadDrop.NotPoolManager.selector);
        stranger.call(address(dd), abi.encode(uint256(1)));
    }

    function test_unlockCallbackRejectsPoolManagerOutsideOwnUnlock() public {
        vm.prank(address(pm));
        vm.expectRevert(DeadDrop.NotUnlocking.selector);
        dd.unlockCallback(abi.encode(uint256(1)));
    }

    function test_reentrancyFromPoolManagerIsBlocked() public {
        ReentrantPoolManager evil = new ReentrantPoolManager();
        DeadDrop victim = new DeadDrop(owner, address(drop), address(imd), address(evil), HOOKS);
        evil.setPool(victim.poolKey());
        vm.prank(factory);
        drop.transfer(address(evil), 1_000_000e18);
        vm.prank(alice);
        imd.approve(address(victim), type(uint256).max);
        vm.prank(alice);
        victim.openDrop(aliceKey, 0);
        vm.prank(bob);
        victim.openDrop(bobKey, 0);

        // A clean note first, so answer / takeBack have a target.
        vm.prank(alice);
        victim.leave(bob, _note(1), 1e18, 0);

        bytes memory reentered = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        for (uint8 mode = 1; mode <= 4; ++mode) {
            evil.arm(mode, address(victim), bob, 1);
            vm.prank(alice);
            vm.expectRevert(reentered);
            victim.leave(bob, _note(1), 0, 0);
            evil.arm(mode, address(victim), carol, 1);
            vm.prank(alice);
            vm.expectRevert(reentered);
            victim.knock(carol, 0);
        }
        assertEq(victim.noteCount(), 1, "no note slipped through");
    }

    // ───────────────────────────── conservation ─────────────────────────────

    function testFuzz_contractHoldsExactlyTheOpenEscrows(uint8 nActions, uint64 tipSeed, uint64 rateSeed) public {
        _open(alice, aliceKey, 0);
        _open(bob, bobKey, 0);
        _open(carol, keccak256("carol"), 0);
        pm.setRate(1 + rateSeed % 50, 1 + (rateSeed >> 8) % 7);
        address[3] memory users = [alice, bob, carol];

        uint256 expectedHeld;
        uint256 count = uint256(nActions) % 24;
        for (uint256 i; i < count; ++i) {
            address from = users[i % 3];
            address to = users[(i + 1 + (tipSeed >> (i % 32)) % 2) % 3];
            uint256 tip = (uint256(tipSeed) * (i + 1)) % 5e18;
            vm.prank(from);
            uint256 id = dd.leave(to, _note(1 + i), tip, 0);
            (,,,,, uint256 escrow) = dd.notes(id);
            expectedHeld += escrow;

            if (i % 3 == 0) {
                vm.prank(to);
                dd.answer(id, _note(1));
                expectedHeld -= escrow;
            } else if (i % 3 == 1) {
                vm.warp(block.timestamp + 14 days);
                vm.prank(from);
                dd.takeBack(id);
                expectedHeld -= escrow;
            }
            assertEq(drop.balanceOf(address(dd)), expectedHeld, "held == sum of open escrows");
            assertEq(imd.balanceOf(address(dd)), 0, "no IMD ever stays");
        }
        assertEq(dd.noteCount(), count);
        assertEq(drop.balanceOf(BURN), dd.totalDropBurned());
        assertEq(imd.balanceOf(address(pm)), dd.totalImdSpent());
    }
}

/// @dev Same tests with IMD above DROP, so DROP is currency0 and the swap is oneForZero.
contract DeadDropReverseOrderTest is DeadDropTest {
    function _imdAddress() internal pure override returns (address) {
        return 0xFfffFfFFFfFFFFfFFfFFFfFFFfFFfFFFfFfFfFf1;
    }

    function _expectImdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
