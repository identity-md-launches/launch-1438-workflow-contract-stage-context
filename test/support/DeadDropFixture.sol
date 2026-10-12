// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeadDrop} from "src/DeadDrop.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @dev Shared setup only: inheriting this fixture does not duplicate another test suite.
abstract contract DeadDropFixture is Test {
    address internal constant BURN = address(0xdead);
    address internal constant HOOKS = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    uint256 internal constant INITIAL_STAMP = 0.1e18;
    uint256 internal constant POOL_DROP = 500_000_000e18;
    uint256 internal constant USER_IMD = 1_000_000e18;

    address internal owner = makeAddr("test owner");
    address internal alice = makeAddr("test alice");
    address internal bob = makeAddr("test bob");
    address internal carol = makeAddr("test carol");
    address internal closed = makeAddr("unopened inbox");
    LaunchToken internal drop;
    MockERC20 internal imd;
    MockPoolManager internal pm;
    DeadDrop internal dd;

    function reverseOrder() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual {
        drop = new LaunchToken();
        MockERC20 implementation = new MockERC20();
        address imdAddress =
            reverseOrder() ? 0xFfffFfFFFfFFFFfFFfFFFfFFFfFFfFFFfFfFfFf1 : 0x1000000000000000000000000000000000000001;
        vm.etch(imdAddress, address(implementation).code);
        imd = MockERC20(imdAddress);
        pm = new MockPoolManager();
        dd = new DeadDrop(owner, address(drop), address(imd), address(pm), HOOKS);
        assertEq(dd.IMD_IS_CURRENCY0(), !reverseOrder(), "exercise both packed delta lanes");
        pm.setPool(dd.poolKey());
        pm.track(address(imd));
        pm.track(address(drop));
        drop.transfer(address(pm), POOL_DROP);
        vm.warp(1_800_000_000);
        _fundAndOpen(alice);
        _fundAndOpen(bob);
        _fundAndOpen(carol);
    }

    function _fundAndOpen(address actor) internal {
        imd.mint(actor, USER_IMD);
        vm.startPrank(actor);
        imd.approve(address(dd), type(uint256).max);
        dd.openDrop(keccak256(abi.encode(actor)), 0);
        vm.stopPrank();
    }

    function _leave(address from, address to, uint256 tip) internal returns (uint256 id) {
        vm.prank(from);
        id = dd.leave(to, hex"01", tip, 0);
    }

    /// @dev Fingerprint observable custody, records and counters, including finite allowance.
    function _state() internal view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                dd.noteCount(),
                dd.answeredCount(),
                dd.knockCount(),
                dd.totalImdSpent(),
                dd.totalDropBurned(),
                dd.stamp(),
                dd.owner(),
                dd.pendingOwner(),
                pm.swapCount(),
                pm.lastAmountIn(),
                pm.unlocked(),
                pm.currencyDelta(address(imd)),
                pm.currencyDelta(address(drop))
            )
        );
        address[8] memory accounts = [alice, bob, carol, closed, owner, address(dd), address(pm), BURN];
        for (uint256 i; i < accounts.length; ++i) {
            address actor = accounts[i];
            result = keccak256(
                abi.encode(
                    result,
                    imd.balanceOf(actor),
                    drop.balanceOf(actor),
                    imd.allowance(actor, address(dd)),
                    dd.earned(actor),
                    dd.knocks(actor)
                )
            );
        }
        for (uint256 id = 1; id <= dd.noteCount() + 1; ++id) {
            (address from, uint64 at, bool answered, bool takenBack, address to, uint256 escrow) = dd.notes(id);
            result = keccak256(abi.encode(result, from, at, answered, takenBack, to, escrow));
        }
    }
}
