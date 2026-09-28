# Security audit: stable-staker (StableStakerV2) at cf8de27

Date: 2026-09-28. Scope: `src/StableStakerV2.sol`, `src/InPlaceMigrator.sol`, `src/CrossVersionMigrator.sol`, and the
calls `autoAnnihilate` makes into Antimatter (a5570ce) and PhusdStableMinter (d6ed115).
PoC tests: branch `claude/project-thread-jgdg08` on ghbhintern/stable-staker, folder `test/audit/`.

## Why this repo

- It is the next contract to go live with user money. StableStakerV2 custodies users' stablecoin principal
  (USDC / USDe / DOLA pools), the UI's Stake tab is already wired to it, and phase-2-staging did a Sepolia
  deployment of it on 2026-09-26.
- It is the only place outside the stable minter that can mint phUSD, and since story 028 it mints phUSD with no
  collateral behind it (the `autoAnnihilate` shortfall top-up). A bug there inflates phUSD directly.
- phoenix-phase-2-staging was the coordinator's first guess, but by its own CLAUDE.md it holds no production contract
  code; it deploys stable-staker and the others.

## Result

**No Critical or High issue found.** The build is clean and all 255 existing tests pass. Reward accounting (emission
cap, `rewardDebt` rebasing, dust flooring), terminal migration conservation (`Σ credit ≤ min(R,P)`), and
reentrancy/CEI ordering all hold up on a line-by-line read.

The deep-audits pipeline has already reviewed this exact commit 18 times, so I checked each candidate against
`deep-audits/stable-staker/ledger.json`. The two new findings are below, followed by open items from the ledger
that I re-checked and that should be settled before mainnet.

## New findings

### L-A: When the exit delivers zero, autoAnnihilate gets around every phUSD circuit breaker (Low)

`StableStakerV2.sol:578`, `:644`, `:676`. When `_routeExit` returns 0, `netUsed` and `annihilatable` are both 0, so
`_annihilateMeasured` returns early and **never calls `Antimatter.annihilate`**. Then `phUSDMinted = target - 0` and the
staker mints the whole frictionless payout (about 2× the principal debited) as new phUSD. The following controls never
run on this path:

- Antimatter's pause
- PhusdStableMinter's pause
- the per-stablecoin `enabled` flag
- `maxMintPerDay`

CLAUDE.md says "a cap or pause biting there reverts the whole call atomically". The tests
`test_autoAnnihilate_revertsWhileAntimatterIsPaused` and `test_autoAnnihilate_dailyMintCap_revertsAtomically` say the
same. That claim is only true while delivery is non-zero. CLAUDE.md also names "a strategy that delivers nothing at
all" as a supported case.

- PoC: `test/audit/ZeroDeliveryBypass.t.sol`. All four breakers are engaged, and alice still gets 100 phUSD, all of it
  freshly minted. The control test shows the breakers do stop the call at 1% delivery.
- Why only Low: an honest ERC4626 or market strategy reverts before it returns 0, except for sub-share dust. Pausing
  StableStaker itself still stops the call. The realistic trigger is an impaired strategy that `_isUnderwater` doesn't
  see, which is exactly the incident where operators reach for the Antimatter or minter pause.
- Fix: `require(received > 0, "StableStaker: exit delivered nothing")` in `autoAnnihilate`. Or, whenever
  `phUSDMinted > 0`, also require that Antimatter is not paused and that the minter is unpaused and has `enabled` set
  for this token.

### Q-A: InPlaceMigrator.migrateIn paging skips users (QA)

`InPlaceMigrator.sol:203-251`. `migrateIn` removes each user it re-injects from `_parkedUsers`. EnumerableSet removal is
swap-and-pop, so after a page `[0,k)`, the next page `[k,2k)` skips the users who were moved down into the low
indices. They stay parked, earn nothing, and at timeout can only `claimTimedOut` out of the system, which also loses
them the top-up.

- PoC: `test/audit/MigrateInPaging.t.sol`. With 4 parked users, paging `(0,2)` then `(2,4)` re-stakes only 2.
- Today's tests and scripts always call `(0, n)`, which works. Say so in the NatSpec ("always page from 0"), or drop
  `start` from the signature.

## Open ledger items still live at cf8de27 that should block mainnet

| Ledger item | Status | Why it matters |
|---|---|---|
| Run 17 M-01: underwater + closed claim gate means the only exit (`emergencyWithdraw`) destroys the Antimatter backlog | open | I re-proved it: `test/audit/UnderwaterForfeiture.t.sol`. `withdraw`, `autoAnnihilate` and `claim` all revert, and `emergencyWithdraw` zeroes the reward. The runbook answer is `setClaimEnabled(true)` the moment any strategy goes below par. Make that an alert, not tribal knowledge. |
| Run 18 M-01: a third party can sandwich someone else's autoAnnihilate and be paid out of the phUSD top-up | wont-fix | Bounded by `slippageToleranceBps` on the market strategy, which StableStakerV2 never reads. Confirm the deployed tolerance is tight before opening USDe (the AMM-backed pool). |
| Run 18 L-01: the top-up mints phUSD outside the stable minter's `maxMintPerDay` and without collateral | wont-fix | The same design choice as L-A above. L-A shows the bypass goes further than the cap when delivery is zero. |
| Run 17 M-02: autoAnnihilate spends the shared underwater buffer | open (Low) | This contradicts the "never touches the buffer" NatSpec at `:486-487`. |

## Checked and not a problem

- Reentrancy through annihilate → minter → strategy: every entry point is `nonReentrant`, and phUSD delivery is
  measured as a balance delta.
- Rounding in `autoAnnihilate`: everything floors in the protocol's favour, and sub-unit dust is carried in
  `unclaimedReward`.
- `rescueERC20` cannot reach idle principal, and during Migrating it reserves `totalStaked ≥ Σ credits`.
- Reviving a pool with `finalizeAndReset`: stale `accAntimatterPerShare` is harmless because every position was
  zeroed.
