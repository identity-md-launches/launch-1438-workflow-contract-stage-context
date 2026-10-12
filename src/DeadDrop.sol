// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "./interfaces/IPoolManager.sol";

/// @title DEAD DROP: every wallet has a dead drop
/// @notice Leave a sealed (client-side encrypted) note for any wallet that opened a drop. Each note
///         costs a stamp plus the recipient's price, both paid in IMD. The whole payment is swapped to
///         DROP on the launch pool in one exact-input swap: the stamp's share is burned, the tip's
///         share is escrowed and paid to the recipient when they answer. An unanswered note can be
///         taken back by its sender after 14 days (the stamp is never returned).
/// @dev The contract never sees plain text: notes and replies are NaCl boxes sealed in the browser.
///      Everything on chain (who, to whom, how much, when) is public; only the words are not.
contract DeadDrop is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice A wallet's dead drop: its x25519 public key and its price to read, in IMD.
    struct Drop {
        bytes32 key;
        uint256 price;
    }

    /// @notice A note left for a wallet. `escrow` is held in DROP until answered or taken back.
    struct Note {
        address from;
        uint64 leftAt;
        bool answered;
        bool takenBack;
        address to;
        uint256 escrow;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Where the stamp's share of every swap goes.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Lowest stamp the owner may set: 0.01 IMD.
    uint256 public constant MIN_STAMP = 0.01e18;
    /// @notice Highest stamp the owner may set: 1 IMD.
    uint256 public constant MAX_STAMP = 1e18;
    /// @notice Stamp at launch: 0.1 IMD.
    uint256 public constant INITIAL_STAMP = 0.1e18;
    /// @notice A sender may take back an unanswered note this long after leaving it.
    uint256 public constant TAKE_BACK_DELAY = 14 days;
    /// @notice Notes and replies are 1 to 1,024 bytes.
    uint256 public constant MAX_BYTES = 1024;
    /// @notice The launch pool's fee tier. The pool trades at the chain's LaunchFees fee.
    uint24 public constant POOL_FEE = 12500;
    /// @notice The launch pool's tick spacing.
    int24 public constant POOL_TICK_SPACING = 60;

    /// @dev Uniswap v4 TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: no price limit, the
    ///      caller's `minDropOut` is the slippage check.
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128739 + 1;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;

    // ─────────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The launch token, DROP.
    IERC20 public immutable DROP;
    /// @notice The paired currency, IMD, in which stamps and prices are quoted.
    IERC20 public immutable IMD;
    /// @notice The Uniswap v4 PoolManager that hosts the launch pool.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The launch pool's hook contract (gates initialize only).
    address public immutable POOL_HOOKS;
    /// @notice True when IMD sorts as currency0, so an IMD -> DROP swap is zeroForOne.
    bool public immutable IMD_IS_CURRENCY0;

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The stamp, in IMD, charged on every note and knock.
    uint256 public stamp = INITIAL_STAMP;
    /// @notice Number of notes left so far. Note ids run from 1 to `noteCount`.
    uint256 public noteCount;
    /// @notice Number of notes answered so far.
    uint256 public answeredCount;
    /// @notice Number of knocks so far.
    uint256 public knockCount;
    /// @notice IMD pulled for notes and knocks so far.
    uint256 public totalImdSpent;
    /// @notice DROP sent to the burn address so far.
    uint256 public totalDropBurned;

    /// @notice Each wallet's drop. A zero key means the wallet has no drop.
    mapping(address wallet => Drop) public drops;
    /// @notice Notes by id.
    mapping(uint256 id => Note) public notes;
    /// @notice DROP paid out to each wallet by answering.
    mapping(address wallet => uint256) public earned;
    /// @notice Knocks received by each wallet.
    mapping(address wallet => uint256) public knocks;

    /// @dev Set only for the duration of this contract's own `unlock` call.
    bool private _unlocking;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event DropOpened(address indexed wallet, bytes32 key, uint256 price);
    event PriceSet(address indexed wallet, uint256 price);
    event Left(uint256 indexed id, address indexed from, address indexed to, uint256 tip, uint256 escrow, bytes note);
    event Answered(uint256 indexed id, bytes reply);
    event TakenBack(uint256 indexed id, uint256 escrow);
    event Knocked(address indexed to, address indexed from);
    event StampSet(uint256 stamp);

    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error SameCurrency();
    error KeyRequired();
    error NoDrop(address wallet);
    error HasDrop(address wallet);
    error SelfNote();
    error BadLength(uint256 length);
    error TipBelowPrice(uint256 price, uint256 tip);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error PartialSwap(uint256 requested, uint256 consumed);
    error UnknownNote(uint256 id);
    error NotRecipient(uint256 id);
    error NotSender(uint256 id);
    error AlreadyAnswered(uint256 id);
    error AlreadyTakenBack(uint256 id);
    error TooEarly(uint256 id, uint256 takeBackAt);
    error StampOutOfRange(uint256 stamp);
    error NotPoolManager();
    error NotUnlocking();
    error RenounceDisabled();

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    /// @param owner_ The launch owner. May set the stamp; nothing else.
    /// @param drop The launch token (DROP).
    /// @param imd The paired currency (IMD).
    /// @param poolManager The Uniswap v4 PoolManager on the launch chain.
    /// @param hooks The launch pool's hook address.
    /// @dev Makes no external calls: the launch runs constructors on an empty chain. The pool is
    ///      checked on first use (the PoolManager reverts a swap on an uninitialised pool).
    constructor(address owner_, address drop, address imd, address poolManager, address hooks) Ownable(owner_) {
        if (drop == address(0) || imd == address(0) || poolManager == address(0) || hooks == address(0)) {
            revert ZeroAddress();
        }
        if (drop == imd) revert SameCurrency();
        DROP = IERC20(drop);
        IMD = IERC20(imd);
        POOL_MANAGER = IPoolManager(poolManager);
        POOL_HOOKS = hooks;
        IMD_IS_CURRENCY0 = imd < drop;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Drops
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Open (or replace) the caller's drop.
    /// @param key The caller's x25519 public key. Must be non-zero.
    /// @param price The price to read, in IMD. 0 means free.
    function openDrop(bytes32 key, uint256 price) external {
        if (key == bytes32(0)) revert KeyRequired();
        drops[msg.sender] = Drop({key: key, price: price});
        emit DropOpened(msg.sender, key, price);
    }

    /// @notice Change the caller's price to read. The caller must have a drop.
    function setPrice(uint256 price) external {
        if (drops[msg.sender].key == bytes32(0)) revert NoDrop(msg.sender);
        drops[msg.sender].price = price;
        emit PriceSet(msg.sender, price);
    }

    /// @notice Whether `wallet` has an open drop.
    function hasDrop(address wallet) public view returns (bool) {
        return drops[wallet].key != bytes32(0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Notes
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Leave a sealed note for `to`. Pulls `stamp + tip` IMD from the caller, swaps it all to
    ///         DROP on the launch pool, burns the stamp's share and escrows the tip's share.
    /// @param to The recipient. Must have a drop and must not be the caller.
    /// @param note The sealed note, 1 to 1,024 bytes.
    /// @param tip The tip in IMD. Must be at least `to`'s price.
    /// @param minDropOut The least DROP the swap must return, or the call reverts.
    /// @return id The note's id. Ids start at 1.
    function leave(address to, bytes calldata note, uint256 tip, uint256 minDropOut)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!hasDrop(msg.sender)) revert NoDrop(msg.sender);
        if (!hasDrop(to)) revert NoDrop(to);
        if (to == msg.sender) revert SelfNote();
        if (note.length == 0 || note.length > MAX_BYTES) revert BadLength(note.length);
        if (tip < drops[to].price) revert TipBelowPrice(drops[to].price, tip);

        (uint256 escrow, uint256 burn) = _pullSwapAndSplit(tip, minDropOut);

        id = ++noteCount;
        notes[id] = Note({
            from: msg.sender, leftAt: uint64(block.timestamp), answered: false, takenBack: false, to: to, escrow: escrow
        });
        emit Left(id, msg.sender, to, tip, escrow, note);

        if (burn > 0) DROP.safeTransfer(BURN_ADDRESS, burn);
    }

    /// @dev Pulls `stamp + tip` IMD from the caller, swaps it all to DROP, checks `minDropOut` and
    ///      splits the output: the tip's pro rata share is escrowed, the rest (the stamp's share plus
    ///      rounding dust) is burned. Updates the running totals.
    function _pullSwapAndSplit(uint256 tip, uint256 minDropOut) private returns (uint256 escrow, uint256 burn) {
        uint256 total = stamp + tip;
        IMD.safeTransferFrom(msg.sender, address(this), total);
        uint256 out = _swapToDrop(total);
        if (out < minDropOut) revert InsufficientOutput(out, minDropOut);

        escrow = out * tip / total;
        burn = out - escrow;
        totalImdSpent += total;
        totalDropBurned += burn;
    }

    /// @notice Answer a note. Recipient only, once, and only while the note has not been taken back.
    ///         Pays the note's escrow to the recipient.
    /// @param id The note's id.
    /// @param reply The sealed reply, 1 to 1,024 bytes.
    function answer(uint256 id, bytes calldata reply) external nonReentrant {
        Note storage n = notes[id];
        if (n.from == address(0)) revert UnknownNote(id);
        if (n.to != msg.sender) revert NotRecipient(id);
        if (n.answered) revert AlreadyAnswered(id);
        if (n.takenBack) revert AlreadyTakenBack(id);
        if (reply.length == 0 || reply.length > MAX_BYTES) revert BadLength(reply.length);

        n.answered = true;
        uint256 escrow = n.escrow;
        answeredCount += 1;
        earned[msg.sender] += escrow;
        emit Answered(id, reply);

        if (escrow > 0) DROP.safeTransfer(msg.sender, escrow);
    }

    /// @notice Take back an unanswered note at least 14 days after leaving it. Sender only. Returns
    ///         the escrow to the sender; the stamp is never returned.
    function takeBack(uint256 id) external nonReentrant {
        Note storage n = notes[id];
        if (n.from == address(0)) revert UnknownNote(id);
        if (n.from != msg.sender) revert NotSender(id);
        if (n.answered) revert AlreadyAnswered(id);
        if (n.takenBack) revert AlreadyTakenBack(id);
        uint256 unlockAt = uint256(n.leftAt) + TAKE_BACK_DELAY;
        if (block.timestamp < unlockAt) revert TooEarly(id, unlockAt);

        n.takenBack = true;
        uint256 escrow = n.escrow;
        emit TakenBack(id, escrow);

        if (escrow > 0) DROP.safeTransfer(msg.sender, escrow);
    }

    /// @notice Knock on a wallet that has no drop: one stamp, swapped to DROP and burned. No text.
    /// @param to The wallet to knock on. Must not have a drop.
    /// @param minDropOut The least DROP the swap must return, or the call reverts.
    function knock(address to, uint256 minDropOut) external nonReentrant {
        if (hasDrop(to)) revert HasDrop(to);

        uint256 stamp_ = stamp;
        IMD.safeTransferFrom(msg.sender, address(this), stamp_);
        uint256 out = _swapToDrop(stamp_);
        if (out < minDropOut) revert InsufficientOutput(out, minDropOut);

        knockCount += 1;
        knocks[to] += 1;
        totalImdSpent += stamp_;
        totalDropBurned += out;
        emit Knocked(to, msg.sender);

        if (out > 0) DROP.safeTransfer(BURN_ADDRESS, out);
    }

    /// @notice When note `id` may be taken back (its `leftAt` plus 14 days). 0 for an unknown note.
    function takeBackAt(uint256 id) external view returns (uint256) {
        Note storage n = notes[id];
        if (n.from == address(0)) return 0;
        return uint256(n.leftAt) + TAKE_BACK_DELAY;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Owner
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Set the stamp for later notes and knocks. Between 0.01 and 1 IMD inclusive.
    function setStamp(uint256 newStamp) external onlyOwner {
        if (newStamp < MIN_STAMP || newStamp > MAX_STAMP) revert StampOutOfRange(newStamp);
        stamp = newStamp;
        emit StampSet(newStamp);
    }

    /// @notice Disabled: the owner may be transferred (two-step) but never renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Swap
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The launch pool's key: DROP and IMD sorted, fee 12500, tick spacing 60, the launch hook.
    function poolKey() public view returns (PoolKey memory key) {
        (address c0, address c1) = IMD_IS_CURRENCY0 ? (address(IMD), address(DROP)) : (address(DROP), address(IMD));
        key = PoolKey({currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hooks: POOL_HOOKS});
    }

    /// @dev Swaps `amountIn` IMD held by this contract to DROP through the PoolManager's unlock.
    function _swapToDrop(uint256 amountIn) private returns (uint256 out) {
        _unlocking = true;
        bytes memory result = POOL_MANAGER.unlock(abi.encode(amountIn));
        _unlocking = false;
        out = abi.decode(result, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Accepted only from the PoolManager, and only during this contract's own unlock. Performs
    ///      one exact-input IMD -> DROP swap, settles the IMD and takes the DROP.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (!_unlocking) revert NotUnlocking();

        uint256 amountIn = abi.decode(data, (uint256));
        bool zeroForOne = IMD_IS_CURRENCY0;
        int256 delta = POOL_MANAGER.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        (int128 amount0, int128 amount1) = _unpack(delta);
        int256 inDelta = zeroForOne ? amount0 : amount1;
        int256 outDelta = zeroForOne ? amount1 : amount0;

        // An exact-input swap owes exactly the input; anything less means the pool ran out of range.
        if (inDelta != -int256(amountIn)) {
            revert PartialSwap(amountIn, inDelta < 0 ? uint256(-inDelta) : 0);
        }
        uint256 out = outDelta > 0 ? uint256(outDelta) : 0;

        POOL_MANAGER.sync(address(IMD));
        IMD.safeTransfer(address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();
        if (out > 0) POOL_MANAGER.take(address(DROP), address(this), out);

        return abi.encode(out);
    }

    /// @dev Unpacks v4-core's BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower.
    function _unpack(int256 delta) private pure returns (int128 amount0, int128 amount1) {
        assembly ("memory-safe") {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }
}
