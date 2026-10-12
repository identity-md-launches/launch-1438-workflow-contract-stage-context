// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IPoolManager.sol";

/// @dev A local model of the Uniswap v4 PoolManager's unlock / swap / sync / settle / take flow.
///      It enforces the parts DeadDrop relies on: a swap only inside unlock, the expected pool key and
///      price limits, exact-input semantics, and every delta settled before unlock returns. It prices
///      swaps at a fixed rate instead of a tick curve, so it demonstrates local behaviour and not the
///      launch pool's real price.
contract MockPoolManager is IPoolManager {
    error AlreadyUnlocked();
    error ManagerLocked();
    error WrongPool();
    error PoolNotInitialized();
    error NotExactInput();
    error WrongPriceLimit();
    error CurrencyNotSettled(address currency, int256 delta);
    error NoSync();

    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128739 + 1;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;

    bytes32 public expectedPoolId;
    bool public initialized = true;
    /// @dev out = in * rateNum / rateDen
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    /// @dev When non-zero, at most this much input is consumed per swap (models running out of range).
    uint256 public maxIn;

    bool public unlocked;
    mapping(address currency => int256) public currencyDelta;
    address private _synced;
    uint256 private _syncedReserve;

    uint256 public swapCount;
    uint256 public lastAmountIn;

    function setPool(PoolKey memory key) external {
        expectedPoolId = keccak256(abi.encode(key));
    }

    function setInitialized(bool value) external {
        initialized = value;
    }

    function setRate(uint256 num, uint256 den) external {
        rateNum = num;
        rateDen = den;
    }

    function setMaxIn(uint256 value) external {
        maxIn = value;
    }

    function unlock(bytes calldata data) external virtual returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        _requireSettled();
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256 delta) {
        if (!unlocked) revert ManagerLocked();
        if (keccak256(abi.encode(key)) != expectedPoolId) revert WrongPool();
        if (!initialized) revert PoolNotInitialized();
        if (params.amountSpecified >= 0) revert NotExactInput();
        if (params.sqrtPriceLimitX96 != (params.zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT)) {
            revert WrongPriceLimit();
        }

        uint256 requested = uint256(-params.amountSpecified);
        uint256 consumed = (maxIn != 0 && requested > maxIn) ? maxIn : requested;
        uint256 out = consumed * rateNum / rateDen;

        (address input, address output) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        currencyDelta[input] -= int256(consumed);
        currencyDelta[output] += int256(out);

        swapCount += 1;
        lastAmountIn = consumed;

        int128 amount0 = params.zeroForOne ? -int128(int256(consumed)) : int128(int256(out));
        int128 amount1 = params.zeroForOne ? int128(int256(out)) : -int128(int256(consumed));
        assembly ("memory-safe") {
            delta := or(shl(128, amount0), and(sub(shl(128, 1), 1), amount1))
        }
    }

    function sync(address currency) external {
        _synced = currency;
        _syncedReserve = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (!unlocked) revert ManagerLocked();
        if (_synced == address(0)) revert NoSync();
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedReserve;
        currencyDelta[_synced] += int256(paid);
        _synced = address(0);
        _syncedReserve = 0;
    }

    function take(address currency, address to, uint256 amount) external {
        if (!unlocked) revert ManagerLocked();
        currencyDelta[currency] -= int256(amount);
        IERC20(currency).transfer(to, amount);
    }

    address[] private _tracked;

    function track(address currency) external {
        _tracked.push(currency);
    }

    function _requireSettled() internal view {
        for (uint256 i; i < _tracked.length; ++i) {
            int256 d = currencyDelta[_tracked[i]];
            if (d != 0) revert CurrencyNotSettled(_tracked[i], d);
        }
    }
}

interface IDeadDropReentry {
    function leave(address to, bytes calldata note, uint256 tip, uint256 minDropOut) external returns (uint256);
    function answer(uint256 id, bytes calldata reply) external;
    function knock(address to, uint256 minDropOut) external;
    function takeBack(uint256 id) external;
}

/// @dev A PoolManager that tries to re-enter DeadDrop during the unlock, before running the callback.
contract ReentrantPoolManager is MockPoolManager {
    uint8 public mode; // 1 leave, 2 answer, 3 knock, 4 takeBack
    address public victim;
    address public target;
    uint256 public noteId;

    function arm(uint8 mode_, address victim_, address target_, uint256 noteId_) external {
        mode = mode_;
        victim = victim_;
        target = target_;
        noteId = noteId_;
    }

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        if (mode == 1) IDeadDropReentry(victim).leave(target, hex"01", 0, 0);
        if (mode == 2) IDeadDropReentry(victim).answer(noteId, hex"01");
        if (mode == 3) IDeadDropReentry(victim).knock(target, 0);
        if (mode == 4) IDeadDropReentry(victim).takeBack(noteId);
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        _requireSettled();
    }
}

/// @dev A PoolManager that calls the callback from a second address (a stranger) during unlock.
contract StrangerCaller {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(target).unlockCallback(data);
    }
}
