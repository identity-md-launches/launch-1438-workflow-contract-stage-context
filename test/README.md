# DEAD DROP test coverage

Run the complete offline suite with `forge build` and `forge test`. Dependencies are
already vendored in the repository. These tests need no RPC, environment settings,
FFI, configuration changes, or downloaded artifacts. Existing contributor tests
remain intact.

| Added suite | Guarantees exercised |
| --- | --- |
| `DeadDrop.Adversarial.t.sol` | Both currency sort orders; split conservation and a cross-multiplied rounding interval; zero/one-unit output, zero/one-wei tips, maximum signed pool input and all available DROP output; 1,024-byte payloads; unknown ids; key/price changes; owner boundaries; complete rollback of transfers, finite allowances, counters and records on slippage, partial fill, missing/wrong pool, and exhausted reserves. |
| `DeadDrop.TokenFailures.t.sol` | False-returning, reverting and no-return ERC-20s; settlement shortfalls; retry after failed answer/refund; reentry into all four value-moving entry points from input pull, settlement, burn, answer and refund transfers; callback authentication during an active unlock. |
| `DeadDrop.Invariant.t.sol` | Random calls across four actors, both currency sort orders, an independent note ledger, changes to prices/keys/stamps/ownership, advancing time, unsolicited donations, failed swaps, authorized and unauthorized settlements, and repeated terminal-state calls. |
| `LaunchToken.Properties.t.sol` | Fixed supply and the sum of modeled holder balances; direct and delegated transfers; self/zero/full-supply transfers; finite/infinite allowances, revocation, failed spends and rollback. |

The arithmetic and swap rollback fuzz properties use 1,000 runs. DeadDrop invariant
campaigns use 256 runs of depth 64 per currency order; the launch-token campaign uses
256 runs of depth 96. Inline settings are repeated on inherited overrides because
Foundry does not propagate the original annotations to the derived test contract.
Unexpected handler reverts fail the campaigns. Expected errors are checked with
specific revert data and leave the independent ledger unchanged.

DeadDrop's ledger checks these identities after random calls:

- Custodied DROP = pending escrows + unsolicited DROP donations.
- Purchased DROP = pending escrows + paid escrows + stamp burns.
- IMD held by the pool = successful purchases; unsolicited IMD in DeadDrop stays separate.
- Each actor's balances and earned total agree with authorized payments and refunds.
- A note's sender, recipient, timestamp and escrow remain unchanged; answered and
  refunded states are mutually exclusive and permanent.
- DROP total supply and the sum of all tracked balances remain exactly `10^27`.

Every campaign starts with nonzero custody, a zero-tip note, a paid answer, a refund,
a knock and a rejected purchase. At the end, `afterInvariant` settles every pending
note and verifies that only donations remain in custody. This tests withdrawal
liveness as well as solvency. Handler call statistics show which randomized actions
ran; the deterministic handler test separately exercises both donation currencies
and ownership acceptance.

## Model limits

`MockPoolManager` models the unlock/callback, signed packed deltas, sorted pool key,
price-limit direction, exact-input consumption, sync/settle/take and outstanding-debt
checks. Its exchange rate is a configurable rational quote, not a Uniswap tick curve.
The production launch token is used by the arithmetic and invariant suites. The
separate hostile-token suite deliberately substitutes local test tokens to exercise
SafeERC20 and callback failure handling; it does not claim support for arbitrary
fee-on-transfer assets in production.

No fork tests or live-chain validation were run. The deployed PoolManager and launch
hook, the actual initialized launch pool, its liquidity/tick behavior, and quotes
against live state remain integration checks for the deployment handoff. They are
not dependencies of this offline suite. These tests do not validate the browser's
NaCl encryption or the separate launch manifest.

No confirmed implementation defect was reproduced during this contribution.
