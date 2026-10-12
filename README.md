# DEAD DROP

*Every wallet has a dead drop.*

Leave a sealed note for any wallet. Only they can open it. They get paid when they answer.
Every note is a DROP buy on the launch pool: the stamp's share is burned, the tip's share is
escrowed in DROP and paid to the recipient when they answer.

This repository holds the on-chain part of the project: the launch token and the `DeadDrop`
application contract, their tests, and the ABI exports. The site, the sealing scheme (NaCl box
in the browser) and the launch manifest are separate deliverables.

## Contracts

| Contract      | File                   | Role                                                        |
| ------------- | ---------------------- | ----------------------------------------------------------- |
| `LaunchToken` | `src/LaunchToken.sol`  | Dead Drop (DROP). Fixed-supply ERC-20, the launch token.    |
| `DeadDrop`    | `src/DeadDrop.sol`     | Drops, notes, answers, take-backs, knocks, the pool swap.   |

ABI exports: `docs/abi/LaunchToken.json`, `docs/abi/DeadDrop.json`.

### LaunchToken (Dead Drop, DROP)

- Name "Dead Drop", symbol "DROP", 18 decimals.
- Exactly 1,000,000,000 DROP (10^27 minor units) minted once to `msg.sender` (the launch factory)
  in the constructor. No constructor arguments.
- Plain OpenZeppelin ERC-20 transfers. No mint, owner, pause, blocklist, fee or upgrade functions.
- The brief asks for exactly this (fixed supply, plain transfers, no tax, no mint), so nothing the
  brief asked of the token is left out.

The factory splits the supply under the launch policy (10% swarm, 88% pool, 2% to the wallet that
paid). Nothing here mints, reserves or receives any of it at launch. `DeadDrop` only ever holds
DROP that notes escrow in it after launch.

### DeadDrop

**Drops**

- `openDrop(bytes32 key, uint256 price)`: stores the caller's x25519 public key (non-zero) and the
  price to read, in IMD (0 = free). Calling again replaces both. Emits `DropOpened`.
- `setPrice(uint256 price)`: changes the price only. Requires a drop. Emits `PriceSet`.
- `hasDrop(address)`, `drops(address)`: views.

**Notes**

- `leave(address to, bytes note, uint256 tip, uint256 minDropOut) returns (uint256 id)`
  - Checks, before any transfer: the sender has a drop, `to` has a drop, `to != sender`, the note is
    1 to 1,024 bytes, `tip >= to's price`.
  - Pulls `stamp + tip` IMD from the sender (IMD allowance required) and swaps all of it to DROP in
    one exact-input swap on the launch pool. Reverts with `InsufficientOutput` if the DROP out is
    below `minDropOut`, and with `PartialSwap` if the pool could not consume the whole input.
  - The tip's pro rata share of the DROP out (`out * tip / (stamp + tip)`, rounded down) stays in
    the contract as the note's escrow; the rest (the stamp's share plus any rounding dust) goes to
    `0x000000000000000000000000000000000000dEaD`.
  - Emits `Left(id, from, to, tip, escrow, note)`. Ids start at 1 and increment.
- `answer(uint256 id, bytes reply)`: recipient only, once, and only while the note has not been
  taken back. Reply 1 to 1,024 bytes. Pays the escrow (in DROP) to the recipient. Emits
  `Answered(id, reply)`.
- `takeBack(uint256 id)`: sender only, unanswered, at least 14 days (1,209,600 seconds) after the
  note was left. Returns the escrow (in DROP) to the sender. The stamp is never returned. Emits
  `TakenBack(id, escrow)`.
- `knock(address to, uint256 minDropOut)`: only for a wallet with no drop. One stamp, pulled,
  swapped and burned the same way. No text. Emits `Knocked(to, from)`.
- `notes(id)`, `takeBackAt(id)`: views.

**Owner** (the launch owner, OpenZeppelin `Ownable2Step`, `renounceOwnership` disabled)

- `setStamp(uint256)`: between 0.01 and 1 IMD inclusive, for later notes and knocks only. Emits
  `StampSet`.
- Nothing else. No pause, no upgrade, no fee to the owner, no way to move escrow except `answer`
  and `takeBack`.

**Counters for the site**: `noteCount`, `answeredCount`, `knockCount`, `totalImdSpent`,
`totalDropBurned`, `earned(address)`, `knocks(address)`. Who wrote to whom is in the `Left` events;
the site is responsible for showing a wallet only its own notes.

### The swap

`DeadDrop` swaps through the Uniswap v4 PoolManager with `unlock` and `unlockCallback`, on the
launch pool's own key: DROP and IMD sorted by address, fee 12500, tick spacing 60, the launch hook.
Inside the callback it does one exact-input swap with no price limit (`minDropOut` is the slippage
check), settles the IMD with `sync` / transfer / `settle`, and `take`s the DROP.

- `unlockCallback` accepts only the PoolManager, and only during `DeadDrop`'s own unlock.
- `leave`, `answer`, `takeBack` and `knock` are `nonReentrant`; a PoolManager that re-enters any
  of them during the unlock makes the whole call revert.
- All token movement uses SafeERC20. Every check that does not depend on the swap result runs
  before any transfer.
- The pool is not touched in the constructor. The PoolManager reverts a swap on a pool that is not
  initialised, so a note cannot be left before the factory has opened the pool.

## Deployment parameters

The launch factory deploys both contracts from their bytecode. The manifest step writes
`launch.json`; this repository does not contain one.

`LaunchToken`: no constructor arguments.

`DeadDrop(address owner_, address drop, address imd, address poolManager, address hooks)`:

| Argument      | Value on Ethereum (chain id 1)                                     | Manifest reference |
| ------------- | ------------------------------------------------------------------ | ------------------ |
| `owner_`      | the launch owner, `0xadfeb3f908a735fe366ed3e77489116383bdcc48`     | `$owner`           |
| `drop`        | the `LaunchToken` deployed by this launch                          | `$token`           |
| `imd`         | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`                  | literal            |
| `poolManager` | Uniswap v4 PoolManager, `0x000000000004444c5dc75cB358380D2e3dE08A90` | literal          |
| `hooks`       | the IMD launch hook, `0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000`   | literal            |

Fixed values are constants in the contract: pool fee 12500, tick spacing 60, burn address
`0x…dEaD`, stamp bounds 0.01 to 1 IMD, initial stamp 0.1 IMD, 1,024-byte limit, 14-day take-back
delay. The pool key is derived in the constructor by sorting `drop` and `imd`; the swap direction
follows from the sort (`IMD_IS_CURRENCY0`). The constructor makes no external calls and does not
require any address to have code, so it runs on an empty chain.

Build settings (`foundry.toml`): solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`,
`cbor_metadata = false`, no `ffi`, no filesystem permissions. `DeadDrop`'s runtime is about 8 KB.
Every library call (`SafeERC20`) is internal, so the bytecode has no link placeholders.

Dependencies are vendored as ordinary files under `lib/` (OpenZeppelin Contracts v5.1.0,
`contracts/` only; forge-std v1.9.6, `src/` only). There are no git submodules.

## After launch

Nothing has to be set for the contract to work: every outside value is a constructor argument the
brief gives for the launch chain, and the pool key is derived from them.

The owner may:

- `setStamp(uint256)`: change the stamp for later notes and knocks, between `0.01e18` and `1e18`
  (IMD has 18 decimals). It starts at `0.1e18`.
- `transferOwnership(address)` then `acceptOwnership()` from the new owner. Ownership cannot be
  renounced.

## Assumptions

- **IMD and DROP are plain ERC-20s** with 18 decimals and no transfer fee. A fee-on-transfer or
  rebasing IMD would break the exact-input accounting. IMD is the chain's pair token; DROP is the
  token in this repository.
- **The launch pool exists at the derived key** (sorted DROP and IMD, fee 12500, tick spacing 60,
  the launch hook) and is initialised by the factory. If the factory opened the pool at any other
  key, every `leave` and `knock` reverts (`PoolManager` reports an uninitialised pool); nothing is
  lost, but the contract is unusable until a build with the right key is launched.
- **The hook only gates initialisation.** The swap passes empty hook data. A hook that took swap
  fees or reverted swaps would surface as a reverting or lower-output swap, which `minDropOut`
  catches.
- **Escrow is held in DROP** and its IMD value floats with the pool price between `leave` and
  `answer` / `takeBack`. The brief wants this ("price compared in IMD at leave; escrow held in
  DROP").
- **Prices are set by wallets, not the contract.** A recipient can raise or lower the price at
  any time; a note already left keeps the tip it was left with.
- **Sealing happens off chain.** The contract stores and emits bytes. It cannot check that a note
  is a valid NaCl box, that the key is a real x25519 public key, or that a reply decrypts. A
  recipient can answer with garbage and still be paid; the price to read is the recipient's
  reputation to keep.
- **Smart-contract wallets**: a contract wallet can call every function, but the site's key
  derivation signs a message with an EOA key, so the site does not support them. The contract
  does not restrict callers.
- **No timestamp-sensitive value is derived**: `block.timestamp` only gates the 14-day take-back,
  where a few seconds of miner drift do not matter.

## Operational responsibilities

- **Owner**: holds the only privileged power, `setStamp`, and the ability to hand ownership to
  another address. The owner cannot touch escrow, pause, upgrade or take a fee. Keep the owner key
  in a wallet that can accept a two-step transfer (a multisig is fine).
- **Senders**: approve IMD to `DeadDrop` before `leave` / `knock`; pass a `minDropOut` from a
  fresh quote (the site defaults to 1% slippage); keep their own sealed copy of the note if they
  want to reread it (the site does this); take back unanswered notes after 14 days if they want
  the escrow.
- **Recipients**: answer notes to be paid; set a price that reflects the attention they sell.
- **Site**: reads `Left`, `Answered`, `TakenBack` and `Knocked` events, shows each wallet only
  its own notes, and uses the exact `poolKey()` of the deployed contract for quotes.
- **Nobody** needs to run anything: there is no keeper, oracle, relayer or off-chain service.

## What is public

Who left a note, for whom, when, how much was tipped and how much DROP is escrowed are public
(events and storage). The words are not: the contract only ever sees sealed bytes.

## Tests

```
forge build
forge test
forge fmt --check
```

`test/LaunchToken.t.sol` checks metadata, the supply minted to the deployer, an exact transfer,
and that mint / admin selectors do not exist.

`test/DeadDrop.t.sol` runs every test twice, once with IMD sorted below DROP and once above, so
both swap directions are covered: constructor validation and the derived pool key, drop open /
replace / price, `leave` success (balances, burn and escrow split, event, stored note) and every
failure (no drop on either side, self, length, price, slippage, allowance, uninitialised pool,
partial swap), `answer` and `takeBack` success and every failure (wrong caller, twice, after the
other, unknown id, too early, bad length), `knock`, stamp bounds and owner-only, two-step
ownership with renounce disabled, that the owner cannot move escrow, callback access control,
re-entrancy from a malicious PoolManager into all four state-changing functions, and a fuzz test
that the contract's DROP balance always equals the sum of open escrows while no IMD stays behind.

The PoolManager in the tests is a local model (`test/mocks/MockPoolManager.sol`) that enforces
the unlock / swap / sync / settle / take protocol, the expected pool key and price limits, exact-
input semantics and full settlement, but prices swaps at a fixed rate. It demonstrates the
contract's behaviour against the protocol, not the launch pool's real price or the real
PoolManager's bytecode. A fork test against mainnet was not possible in the offline verifier.

## Review notes

Tests passing are not an audit. Points for the independent review:

- The swap has no price limit by design; the only slippage protection is the caller's
  `minDropOut`. A caller that passes 0 accepts any price.
- `leave` computes the escrow after the swap, so the recipient's payout depends on the pool
  price at the moment of the note, including the launch fee the pool takes.
- DROP sent directly to the contract (not through `leave`) is not tracked and cannot be recovered;
  there is deliberately no sweep.
- Tools run: `forge build`, `forge test` (99 tests, including fuzz), `forge fmt --check`, and the
  launch floor tests from `.imd/reads/protected/evm_project` against the built bytecode with the
  real constructor arguments. Slither and Mythril were not run.
