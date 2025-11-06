# Running TrustlessFund Tests in Remix

## Prerequisites
- Ensure `TrustlessFund.sol`, `MockERC20.sol`, `MockTrustlessTester.sol`, and `TrustlessFundTests.sol` are in your Remix workspace.
- Place `TrustlessFund.sol` in `./TrustlessFund`.
- Place mock contracts and `TrustlessFundTests.sol` in `./Tests`.

## Steps
1. Open Remix [https://remix.ethereum.org](https://remix.ethereum.org).
2. Upload all contracts to the specified directories.
3. In "Solidity Compiler", select `^0.8.2` and compile all.
4. In "Deploy & Run Transactions", select **Remix VM**.
5. Ensure default account has 100 ETH.
6. Deploy `TrustlessFundTests` using the default account.
7. Call `initiateTesters()` with **4 ETH** (value field).
8. Call `p1_1TestFundCreation()`.
9. Call `p1_2TestPropAddGrantor()`.
10. Call `p1_3TestVoteAddGrantor()`.
11. Call `p1_4TestPropAddGrantee()`.
12. Call `p1_5TestVoteAddGrantee()`.
13. Call `p1_6TestDisburse()`.
- Redeploy the contract due to warped time. 
14. Call `p2_1TestMultiFund()`.
15. Call `p2_2TestAddTokens()` 
16. Call `p2_3TestPartialBalance()`
17. Call `p2_4TestExhaustion()` 
18. Call `p2_5TestReactivateAfterExhaustion()` 
19. Call `p2_6TestDistributePartial()` 
20. **Sad Path Tests**:
    - `s1_EmptyGranteesOneTime()`
    - `s2_EmptyGranteesRecurring()`
    - `s3_RecurringZeroInterval()`
    - `s4_NonGranteeDisburse()`
    - `s5_EarlyDisburse()`
    - `s6_DoubleDisburseOneTime()`
    - `s7_RecurringSamePeriod()`
    - `s8_NonGrantorPropose()`
    - `s9_RemoveLastGrantee()`
    - `s10_RemoveLastGrantor()`
    - `s11_NonGrantorVote()`
    - `s12_DoubleVote()`
    - `s13_VoteAfterDeadline()`
    - `s14_AddTokensInactiveFund()`

## Objectives

7. `initiateTesters()`:
   - **Objective**: Deploys 4 `MockTrustlessTester` contracts: `[0]` = grantor1, `[1]` = grantee1, `[2]` = grantee2 (fund 2), `[3]` = grantee2 (fund 3). Each gets 1 ETH + 1000 mock tokens.
   - **Looking For**: Successful deployment, ETH/token distribution.
   - **Avoid**: Wrong ETH value, failed transfers.

8. `p1_1TestFundCreation()`:
   - **Objective**: Grantor1 creates one-time fund: grantee1, 200 tokens, locked 2 years.
   - **Looking For**: `fundCount == 1`, tokens transferred.

9. `p1_2TestPropAddGrantor()`:
   - **Objective**: Grantor1 proposes adding grantor2.
   - **Looking For**: `proposalCount == 1`.

10. `p1_3TestVoteAddGrantor()`:
    - **Objective**: Grantor1 votes → >51% → proposal executes.
    - **Looking For**: `proposals(1).executed == true`.

11. `p1_4TestPropAddGrantee()`:
    - **Objective**: Grantor1 proposes adding grantee2.
    - **Looking For**: New proposal created.

12. `p1_5TestVoteAddGrantee()`:
    - **Objective**: Grantor1 & grantor2 vote → >51% → grantee added.
    - **Looking For**: `proposals(2).executed == true`.

13. `p1_6TestDisburse()`:
    - **Objective**: Warp 2+ years → grantee1 claims 200 tokens.
    - **Looking For**: Balance increase by `200e18`.

14. `p2_1TestMultiFund()`:
    - **Objective**: Grantor1 creates two recurring funds:
      - Fund 2: grantees [1,2], 60 tokens every 2 months, 100e18 initial, 2-year lock.
      - Fund 3: grantees [1,3], same, 200e18 initial, 3-year lock.
    - **Looking For**: `fundCount == 3`.

15. `p2_2TestAddTokens()`:
    - **Objective**: Grantor1 adds 100 tokens to Fund 3. → Fund 3: `totalIntended` → 300.
    - **Looking For**: `getTotalIntended(3) == 300e18`.

16. `p2_3TestPartialBalance()`:
    - **Objective**: Fund 2 has 100e18 → 2 grantees × 60 = 120 owed → both get 50e18 (fair split), total disbursed = 100e18.  → Fund 2: 100e18 total disbursed (50+50), 20e18 shortfall carried.
    - **Looking For**: `received1 + received2 == 100e18`, shortfall preserved.

17. `p2_4TestExhaustion()`: 
    - **Objective**: Add 140e18 → 240e18 total → disburse remaining 140e18 (incl. 20e18 shortfall) → `totalDisbursed == 240e18`, `active = false`. 
    → Fund 2: +140e18 → 240e18 disbursed → `active = false`.
    - **Looking For**: Full exhaustion, deactivation.

18. `p2_5TestReactivateAfterExhaustion()`:
    - **Objective**: `addTokens(60e18)` on exhausted Fund 2 → `active = true`, `totalIntended = 300e18`.
    → `addTokens(60e18)` → `totalIntended = 300e18`, `active = true`.
    - **Looking For**: Fund resurrection.

19. `p2_6TestDistributePartial()`:
    - **Objective**: Fund 3: 200e18 avail, 120e18 owed → `distributeToGrantees` pays both → fund stays active.
    → Fund 3: partial payout (120e18 owed, 200e18 avail), fund stays active.
    - **Looking For**: Both grantees receive >0, no revert, `isActive == true`.

---

## Objectives (Sad Path)
All `s*` functions **must revert** **except** `s14`. Success = transaction fails with expected revert.

20. `s1_EmptyGranteesOneTime()`:
   - **Objective**: `createOneTimeFund` with empty grantees array.
   - **Expected**: Revert (`"No grantees"`).

21. `s2_EmptyGranteesRecurring()`:
   - **Objective**: `createRecurringFund` with empty grantees.
   - **Expected**: Revert (`"No grantees"`).

22. `s3_RecurringZeroInterval()`:
   - **Objective**: `createRecurringFund` with `disbursementInterval == 0`.
   - **Expected**: Revert.

23. `s4_NonGranteeDisburse()`:
   - **Objective**: Non-grantee calls `disburse()` after unlock.
   - **Expected**: Revert (`"Not grantee"`).

24. `s5_EarlyDisburse()`:
   - **Objective**: Grantee calls `disburse()` before `lockedUntil`.
   - **Expected**: Revert (`"Locked"`).

25. `s6_DoubleDisburseOneTime()`:
   - **Objective**: Grantee claims one-time fund twice.
   - **Expected**: Revert (`"Already claimed"`).

26. `s7_RecurringSamePeriod()`:
   - **Objective**: Grantee claims recurring fund twice in same period.
   - **Expected**: Revert (no new owed).

27. `s8_NonGrantorPropose()`:
   - **Objective**: Non-grantor calls `proposeAddGrantor`.
   - **Expected**: Revert.

28. `s9_RemoveLastGrantee()`:
   - **Objective**: Propose removing the last grantee.
   - **Expected**: Revert.

29. `s10_RemoveLastGrantor()`:
   - **Objective**: Propose removing the last grantor.
   - **Expected**: Revert.

30. `s11_NonGrantorVote()`:
   - **Objective**: Non-grantor votes on proposal.
   - **Expected**: Revert.

31. `s12_DoubleVote()`:
   - **Objective**: Same grantor votes twice.
   - **Expected**: Revert.

32. `s13_VoteAfterDeadline()`:
   - **Objective**: Vote after proposal deadline (warp 8+ days).
   - **Expected**: Revert.

33. `s14_AddTokensInactiveFund()`:
   - **Objective**: Call `addTokens` on exhausted fund.
   - **Expected**: **SUCCEEDS** — fund reactivates.

## Notes
- All calls use default account.
- Set gas limit ≥ 10M.
- Verify paths in imports.
- Time skips via `fund.warp()` — uses contract’s `currentTime`.
- **Sad path success = revert** (except `s14`).
- Monitor console for reverts.
- View functions (`granteeFunds`, `grantorFunds`, `fundProposals`, `getTotalIntended`, `getTotalDisbursed`, `isActive`) can be used to inspect state.
- Non-critical failures emit `Disbursed(..., 0)` instead of reverting (happy path only).
- `disburse()` uses **pull** model: no per-grantee cap, only `remaining` and `balance`.
- `distributeToGrantees()` uses **push** model: applies fair-split cap per iteration.