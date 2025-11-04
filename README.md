# TrustlessFund 

**Version**: 0.0.15 (04/11/2025)  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`TrustlessFund` manages timed token disbursements for ERC20 or ERC721 tokens. Users create funds with multiple grantees who can withdraw tokens (one-time or recurring) after a specified timestamp. Grantors propose and vote on grantee additions/removals or grantor changes, requiring >51% approval. A public `distributeToGrantees` function enables automated disbursements. The contract ensures secure token transfers with pre/post balance checks and graceful degradation for non-critical failures, with per-grantee tracking to prevent duplicate disbursements.

**Key Security Enhancements (v0.0.15)**:
- **Reentrancy Protection**: `nonReentrant` guard on `disburse()` and `distributeToGrantees()`.
- **Checks-Effects-Interactions (CEI) Pattern**: State updated **before** external calls in all paths.
- **Per-Grantee Owed Calculation**: Both `disburse()` and `distributeToGrantees()` use identical logic: `disbursementAmount * (currentPeriod - lastPeriod)`.
- **Fund Exhaustion Safety**: `_checkFundExhaustion()` deactivates only when `totalDisbursed >= totalIntended` **and** no future periods are owed.
- **Gas Resilient**: `distributeToGrantees` resumes after failed transfer or gas limit.
- **Fund Resurrection**: `addTokens()` **reactivates** exhausted funds and increases `totalIntended`.

## Structs
- **Fund**: Stores fund details.
  - `grantees`: Array of addresses allowed to receive disbursements.
  - `lockedUntil`: Timestamp when funds can be disbursed.
  - `disbursementAmount`: Amount per grantee per period (ERC20) or token ID (ERC721).
  - `disbursementInterval`: Interval for recurring disbursements (0 for one-time).
  - `fundType`: Enum (`ERC20`, `ERC721`) for token type.
  - `grantors`: Array of addresses that can propose changes.
  - `tokenContract`: Address of the token contract.
  - `tokenIds`: Array of ERC721 token IDs (empty for ERC20).
  - `active`: Fund status (false after ERC721 tokens are depleted or intended pool exhausted).
  - `lastDisbursedIndex`: Tracks last grantee index for `distributeToGrantees` resumption.
  - `disbursedGrantees`: Mapping tracking last disbursed period per grantee.
  - `totalIntended`: Total tokens intended for distribution (initial deposit + all `addTokens`).
  - `totalDisbursed`: Cumulative amount successfully disbursed.
- **Proposal**: Tracks proposals for grantee or grantor changes.
  - `fundId`: Associated fund ID.
  - `targetAddresses`: Array of addresses for grantee/grantor changes.
  - `votesFor`: Number of votes in favor.
  - `deadline`: Proposal expiration timestamp.
  - `executed`: Whether the proposal is executed.
  - `proposalType`: Enum (`GranteeAddition`, `GranteeRemoval`, `AddGrantor`, `RemoveGrantor`).
  - `voted`: Mapping tracking grantor votes.

## State Variables
- `funds`: Public mapping of fund ID to `Fund` struct.
- `proposals`: Public mapping of proposal ID to `Proposal` struct.
- `fundCount`: Counter for fund IDs.
- `proposalCount`: Counter for proposal IDs.
- `currentTime`: Warped timestamp (used when `isWarped`).
- `isWarped`: Flag indicating time warp mode.
- `_status`: Reentrancy guard (`_NOT_ENTERED` / `_ENTERED`).

## External Functions
- **warp(uint256 newTimestamp)**: Sets `currentTime` and enables warp mode. Used in VM tests.  
  **Internal Call Tree**: Direct state update.
- **unWarp()**: Resets to real `block.timestamp` and disables warp.  
  **Internal Call Tree**: Direct state update.
- **createOneTimeFund(address[] grantees, uint256 lockedUntil, address tokenContract, uint256 amountOrId, FundType fundType)**:
  - Creates a one-time fund for multiple grantees, transferring tokens from the caller.
  - Parameters: Grantees array, unlock timestamp, token contract, amount (ERC20) or token ID (ERC721), token type.
  - Initializes `tokenIds` for ERC721, sets `lastDisbursedIndex` to 0.
  - Sets `totalIntended = amountOrId`, `totalDisbursed = 0`.
  - Calls `_transferTokens`, emits `FundCreated`.
  - **Internal Call Tree**: `_transferTokens` for token transfer with balance checks.
- **createRecurringFund(address[] grantees, uint256 lockedUntil, uint256 disbursementAmount, uint256 disbursementInterval, address tokenContract, uint256 amountOrId, FundType fundType)**:
  - Creates a recurring fund for multiple grantees (ERC20 only).
  - Parameters: Grantees array, unlock timestamp, amount per grantee, interval (>0), token contract, initial amount, token type.
  - Rejects ERC721, sets `lastDisbursedIndex` to 0.
  - Sets `totalIntended = amountOrId`, `totalDisbursed = 0`.
  - Calls `_transferTokens`, emits `FundCreated`.
  - **Internal Call Tree**: `_transferTokens`.
- **disburse(uint256 fundId)** (reentrancy-protected):
  - Allows a grantee to withdraw their share if `lockedUntil` is reached.
  - For recurring funds, disburses `disbursementAmount * (periods - disbursedGrantees[caller])`.
  - For one-time funds, disburses `disbursementAmount` (ERC20) or one token ID (ERC721) if not yet disbursed.
  - Updates `disbursedGrantees`, calls `_disburseERC20` or direct ERC721 logic, emits `Disbursed` (0 for non-critical failures).
  - **Internal Call Tree**: `_isGrantee`, `_disburseERC20`, `_checkFundExhaustion`.
- **distributeToGrantees(uint256 fundId, uint256 maxIterations)** (reentrancy-protected):
  - Public function to distribute tokens to grantees, up to `maxIterations`, starting from `lastDisbursedIndex`.
  - For ERC20, calculates per-grantee owed amount using `disbursementAmount * (currentPeriod - lastPeriod)`.
  - For ERC721, distributes one token ID per grantee, skips previously disbursed grantees.
  - Updates `disbursedGrantees`, `lastDisbursedIndex` per success, and `totalDisbursed`.
  - Deactivates fund if ERC721 tokens are depleted or intended pool exhausted.
  - **Internal Call Tree**: `_calcERC20Globals`, `_checkFundExhaustion`.
- **proposeGranteeAddition(uint256 fundId, address[] newGrantees)**:
  - Grantor proposes adding multiple grantees.
  - Creates a `GranteeAddition` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: `_isGrantor`, `_isGrantee` to check duplicates.
- **proposeGranteeRemoval(uint256 fundId, address[] granteesToRemove)**:
  - Grantor proposes removing multiple grantees (requires >0 remaining grantees).
  - Creates a `GranteeRemoval` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: `_isGrantor`, `_isGrantee`.
- **proposeAddGrantor(uint256 fundId, address newGrantor)**:
  - Grantor proposes adding a new grantor.
  - Creates an `AddGrantor` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: `_isGrantor` to verify caller and check duplicates.
- **proposeRemoveGrantor(uint256 fundId, address grantorToRemove)**:
  - Grantor proposes removing a grantor (requires >1 grantor).
  - Creates a `RemoveGrantor` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: `_isGrantor` to verify caller and target.
- **voteOnProposal(uint256 proposalId, bool inFavor)**:
  - Grantor votes on a proposal.
  - Increments `votesFor` if in favor, calls `_checkProposalOutcome`.
  - Emits `Voted`.
  - **Internal Call Tree**: `_isGrantor`, `_checkProposalOutcome`.
- **addTokens(uint256 fundId, uint256 amountOrId)**:
  - Deposits additional ERC20 or ERC721 tokens to an existing fund.
  - Parameters: Fund ID, amount (ERC20) or token ID (ERC721).
  - **No `active` check** — allows resurrection of exhausted funds.
  - Increases `totalIntended` by `amountOrId`.
  - Sets `fund.active = true` on success.
  - Calls `_transferTokens`, emits `Deposited`.
  - **Internal Call Tree**: `_transferTokens`.
  
## View Functions
- **granteeFunds(address grantee)**:
  - Returns array of active fund IDs for a grantee.
  - Iterates `funds`, filters by `_isGrantee` and `active`.
  - **Internal Call Tree**: `_isGrantee`.
- **grantorFunds(address grantor)**:
  - Returns array of active fund IDs where the caller is a grantor.
  - Iterates `funds`, filters by `_isGrantor` and `active`.
  - **Internal Call Tree**: `_isGrantor`.
- **fundProposals(uint256 fundId)**:
  - Returns array of active proposal IDs for a fund.
  - Filters `proposals` by `fundId` and `!executed`.
  - **Internal Call Tree**: None.
- **getTotalIntended(uint256 fundId)**:
  - **Purpose**: Returns `totalIntended` for a fund.
  - **Why**: `Fund` struct contains nested mapping → cannot be read into memory.
  - **Internal Call Tree**: Direct storage access.
- **getTotalDisbursed(uint256 fundId)**:
  - **Purpose**: Returns `totalDisbursed` for a fund.
  - **Why**: Same memory limitation.
  - **Internal Call Tree**: Direct storage access.
- **isActive(uint256 fundId)**:
  - **Purpose**: Returns `active` status of a fund.
  - **Why**: Clean test assertions.
  - **Internal Call Tree**: Direct storage access.

## Internal Functions
- **_transferTokens(address tokenContract, uint256 amountOrId, FundType fundType)**:
  - Transfers ERC20 or ERC721 tokens with pre/post balance checks.
  - For ERC721, appends `amountOrId` to `tokenIds`.
  - Called by `createOneTimeFund`, `createRecurringFund`, `addTokens`.
  - Emits `Deposited`.
- **_disburseERC20(uint256 fundId, address to, uint256 amount)**:
  - Handles ERC20 token disbursement, checks balance to avoid reverts.
  - Updates `totalDisbursed` **before** `transfer`, rolls back on failure.
  - Called by `disburse`, `distributeToGrantees`.
- **_calcERC20Globals(Fund storage fund)**:
  - Returns `periods`, `remainingIntended`, `contractBalance`.
  - Called by `distributeToGrantees`.
- **_checkFundExhaustion(uint256 fundId)**:
  - Deactivates fund only if `totalDisbursed >= totalIntended` and no future periods owed.
  - Called by `disburse`, `distributeToGrantees`.
- **_isGrantee(Fund storage fund, address account)**:
  - Checks if an address is a grantee for a fund.
  - Called by `disburse`, `proposeGranteeAddition`, `proposeGranteeRemoval`, `granteeFunds`.
- **_isGrantor(Fund storage fund, address account)**:
  - Checks if an address is a grantor for a fund.
  - Called by `propose*`, `voteOnProposal`, `grantorFunds`.
- **_checkProposalOutcome(uint256 proposalId)**:
  - Executes proposal if >51% votes are received.
  - Handles `GranteeAddition` (appends to `grantees`), `GranteeRemoval` (calls `_removeGrantee`), `AddGrantor` (appends to `grantors`), or `RemoveGrantor` (calls `_removeGrantor`).
  - Emits `GranteeAdded`, `GranteeRemoved`, `GrantorAdded`, or `GrantorRemoved`.
- **_removeGrantee(Fund storage fund, address granteeToRemove)**:
  - Removes a grantee from the `grantees` array using pop-and-swap.
  - Called by `_checkProposalOutcome`.
- **_removeGrantor(Fund storage fund, address grantorToRemove)**:
  - Removes a grantor from the `grantors` array using pop-and-swap.
  - Called by `_checkProposalOutcome`.

## Events
- `FundCreated(uint256 fundId, address firstGrantee, uint256 lockedUntil, FundType fundType)`
- `Deposited(uint256 fundId, address tokenContract, uint256 amountOrId)`
- `Disbursed(uint256 fundId, address grantee, uint256 amountOrId)`
- `ProposalCreated(uint256 proposalId, uint256 fundId, address firstTarget, ProposalType proposalType)`
- `Voted(uint256 proposalId, address grantor, bool inFavor)`
- `GranteeAdded(uint256 fundId, address newGrantee)`
- `GranteeRemoved(uint256 fundId, address removedGrantee)`
- `GrantorAdded(uint256 fundId, address newGrantor)`
- `GrantorRemoved(uint256 fundId, address removedGrantor)`

## Key Insights
- **Security**: Pre/post balance checks in `_transferTokens` ensure accurate token transfers. Non-critical failures (e.g., insufficient balance in `disburse` or `distributeToGrantees`) emit `Disbursed` with 0 amount instead of reverting.
- **Time Control**: All time checks (`lockedUntil`, proposal deadlines, recurring periods) use `_now()`. VM tests can `warp()` to simulate future states.
- **Modularity**: Helper functions (`_transferTokens`, `_disburseERC20`, `_calcERC20Globals`, `_removeGrantee`, `_removeGrantor`) reduce complexity and gas costs.
- **Voting**: Proposals require >51% grantor approval, evaluated in `_checkProposalOutcome`.
- **Flexibility**: Supports multiple grantees, with `distributeToGrantees` enabling public, automated disbursements. ERC721 recurring funds are blocked for consistency.
- **Gas Efficiency**: Array resizing in `_removeGrantee` and `_removeGrantor` uses pop-and-swap. View functions use single-pass array allocation. `distributeToGrantees` respects `maxIterations` and resumes on failure.
- **Disbursement Tracking**: `disbursedGrantees` mapping prevents duplicate disbursements by tracking periods (recurring) or status (one-time) per grantee. `lastDisbursedIndex` ensures `distributeToGrantees` resumes correctly.
- **ERC721 Handling**: `tokenIds` array tracks multiple ERC721 tokens, ensuring disbursements do not exceed deposits. State updated before transfer.
- **Period Truncation**: Intentional accrual model — no fractional periods. Periods are calculated using integer division.
- **Future-Proof**: `addTokens` extends `totalIntended` indefinitely, **reactivates** exhausted funds, and keeps them active for future disbursements.
