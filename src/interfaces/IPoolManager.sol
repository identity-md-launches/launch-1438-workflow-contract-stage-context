// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The Uniswap v4 pool key. `currency0` sorts below `currency1`; the native currency is
///      address(0). User-defined value types in v4-core (Currency, IHooks) ABI-encode as `address`,
///      so these plain-address structs produce the same selectors and calldata as v4-core's.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Uniswap v4 swap parameters. A negative `amountSpecified` is an exact-input swap.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @title The subset of the Uniswap v4 PoolManager that DeadDrop uses
/// @dev Return type of `swap` is v4-core's BalanceDelta: an int256 packing amount0 in the upper 128
///      bits and amount1 in the lower 128 bits.
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// @title The callback the PoolManager invokes inside `unlock`
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
