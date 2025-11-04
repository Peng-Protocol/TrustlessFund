# TrustlessFund 

**Version**: 0.0.5 (04/11/2025)  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`TrustlessFund` manages timed token disbursements for ERC20 or ERC721 tokens. Users create funds with multiple grantees who can withdraw tokens (one-time or recurring) after a specified timestamp. Grantors propose and vote on grantee additions/removals or grantor changes, requiring >51% approval. A public `distributeToGrantees` function enables automated disbursements. The contract ensures secure token transfers with pre/post balance checks and graceful degradation for non-critical failures, with per-grantee tracking to prevent duplicate disbursements.

## Structs
- **Fund**: Stores fund details.
  - `grantees`: Array of addresses allowed to receive disbursements.
  - `lockedUntil`: Timestamp when funds can be disbursed.
  - `disbursementAmount`: Amount per grantee (ERC20) or tokens (ERC721).
  - `disbursementInterval`: Interval for recurring disbursements (0 for one-time).
  - `fundType`: Enum (`ERC20`, `ERC721`) for token type.
  - `grantors`: Array of addresses that can propose changes.
  - `tokenContract`: Address of the token contract.
  - `tokenIds`: Array of ERC721 token IDs (empty for ERC20).
  - `active`: Fund status (false after ERC721 tokens are depleted).
  - `lastDisbursedIndex`: Tracks last grantee index for `distributeToGrantees`.
  - `disbursedGrantees`: Mapping tracking last period (recurring) or 1 (one-time) per grantee.
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

## External Functions
- **warp(uint256 newTimestamp)**: Sets `currentTime` and enables warp mode. Used in VM tests.
- **unWarp()**: Resets to real `block.timestamp` and disables warp.
- **createOneTimeFund(address[] grantees, uint256 lockedUntil, address tokenContract, uint256 amountOrId, FundType fundType)**:
  - Creates a one-time fund for multiple grantees, transferring tokens from the caller.
  - Parameters: Grantees array, unlock timestamp, token contract, amount (ERC20) or token ID (ERC721), token type.
  - Initializes `tokenIds` for ERC721, sets `lastDisbursedIndex` to 0.
  - Calls `_transferTokens`, emits `FundCreated`.
  - **Internal Call Tree**: Calls `_transferTokens` for token transfer with balance checks.
- **createRecurringFund(address[] grantees, uint256 lockedUntil, uint256 disbursementAmount, uint256 disbursementInterval, address tokenContract, uint256 amountOrId, FundType fundType)**:
  - Creates a recurring fund for multiple grantees (ERC20 only).
  - Parameters: Grantees array, unlock timestamp, amount per grantee, interval (>0), token contract, initial amount, token type.
  - Rejects ERC721, sets `lastDisbursedIndex` to 0.
  - Calls `_transferTokens`, emits `FundCreated`.
  - **Internal Call Tree**: Calls `_transferTokens`.
- **disburse(uint256 fundId)**:
  - Allows a grantee to withdraw their share if `lockedUntil` is reached.
  - For recurring funds, disburses `disbursementAmount * (periods - disbursedGrantees[caller])`.
  - For one-time funds, disburses `disbursementAmount` (ERC20) or one token ID (ERC721) if not yet disbursed.
  - Updates `disbursedGrantees`, calls `_disburseERC20` or `_disburseERC721`, emits `Disbursed` (0 for non-critical failures).
  - **Internal Call Tree**: Calls `_isGrantee`, `_disburseERC20`, or `_disburseERC721`.
- **distributeToGrantees(uint256 fundId, uint256 maxIterations)**:
  - Public function to distribute tokens to grantees, up to `maxIterations`, starting from `lastDisbursedIndex`.
  - For ERC20, splits `disbursementAmount` (or `disbursementAmount * periods`) evenly, skips grantees with up-to-date disbursements.
  - For ERC721, distributes one token ID per grantee, skips previously disbursed grantees.
  - Updates `disbursedGrantees`, `lastDisbursedIndex`, and `lockedUntil` (recurring), emits `Disbursed` per grantee (0 for non-critical failures).
  - Deactivates fund if ERC721 tokens are depleted.
  - **Internal Call Tree**: None (direct token transfers).
- **proposeGranteeAddition(uint256 fundId, address[] newGrantees)**:
  - Grantor proposes adding multiple grantees.
  - Creates a `GranteeAddition` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: Calls `_isGrantor`, `_isGrantee` to check duplicates.
- **proposeGranteeRemoval(uint256 fundId, address[] granteesToRemove)**:
  - Grantor proposes removing multiple grantees (requires >0 remaining grantees).
  - Creates a `GranteeRemoval` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: Calls `_isGrantor`, `_isGrantee`.
- **proposeAddGrantor(uint256 fundId, address newGrantor)**:
  - Grantor proposes adding a new grantor.
  - Creates an `AddGrantor` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: Calls `_isGrantor` to verify caller and check duplicates.
- **proposeRemoveGrantor(uint256 fundId, address grantorToRemove)**:
  - Grantor proposes removing a grantor (requires >1 grantor).
  - Creates a `RemoveGrantor` proposal, emits `ProposalCreated`.
  - **Internal Call Tree**: Calls `_isGrantor` to verify caller and target.
- **voteOnProposal(uint256 proposalId, bool inFavor)**:
  - Grantor votes on a proposal.
  - Increments `votesFor` if in favor, calls `_checkProposalOutcome`.
  - Emits `Voted`.
  - **Internal Call Tree**: Calls `_isGrantor`, `_checkProposalOutcome`.
- **granteeFunds(address grantee)**:
  - Returns array of active fund IDs for a grantee.
  - Iterates `funds`, filters by `_isGrantee` and `active`.
  - **Internal Call Tree**: Calls `_isGrantee`.
- **grantorFunds(address grantor)**:
  - Returns array of active fund IDs where the caller is a grantor.
  - Iterates `funds`, filters by `_isGrantor` and `active`.
  - **Internal Call Tree**: Calls `_isGrantor`.
- **fundProposals(uint256 fundId)**:
  - Returns array of active proposal IDs for a fund.
  - Filters `proposals` by `fundId` and `!executed`.
  - **Internal Call Tree**: None.
- **addTokens(uint256 fundId, uint256 amountOrId)**:
  - Deposits additional ERC20 or ERC721 tokens to an existing fund.
  - Parameters: Fund ID, amount (ERC20) or token ID (ERC721).
  - Requires active fund and valid token contract.
  - Calls `_transferTokens`, emits `Deposited`.
  - **Internal Call Tree**: Calls `_transferTokens`.

## Internal Functions
- **_transferTokens(address tokenContract, uint256 amountOrId, FundType fundType)**:
  - Transfers ERC20 or ERC721 tokens with pre/post balance checks.
  - For ERC721, appends `amountOrId` to `tokenIds`.
  - Called by `createOneTimeFund`, `createRecurringFund`, `addTokens`.
  - Emits `Deposited`.
- **_disburseERC20(uint256 fundId, uint256 amount)**:
  - Handles ERC20 token disbursement, checks balance to avoid reverts.
  - Called by `disburse`, `distributeToGrantees`.
- **_disburseERC721(uint256 fundId)**:
  - Transfers one ERC721 token from `tokenIds`, removes it, deactivates fund if empty.
  - Called by `disburse`.
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
- **Modularity**: Helper functions (`_transferTokens`, `_disburseERC20`, `_disburseERC721`, `_removeGrantee`, `_removeGrantor`) reduce complexity and gas costs.
- **Voting**: Proposals (`GranteeAddition`, `GranteeRemoval`, `AddGrantor`, `RemoveGrantor`) require >51% grantor approval, evaluated in `_checkProposalOutcome`.
- **Flexibility**: Supports multiple grantees, with `distributeToGrantees` enabling public, automated disbursements. ERC721 recurring funds are blocked for consistency.
- **Gas Efficiency**: Array resizing in `_removeGrantee` and `_removeGrantor` uses pop-and-swap. View functions (`granteeFunds`, `grantorFunds`, `fundProposals`) use single-pass array allocation. `distributeToGrantees` respects `maxIterations` for large grantee cohorts.
- **Disbursement Tracking**: `disbursedGrantees` mapping prevents duplicate disbursements by tracking periods (recurring) or status (one-time) per grantee. `lastDisbursedIndex` ensures `distributeToGrantees` resumes correctly.
- **ERC721 Handling**: `tokenIds` array tracks multiple ERC721 tokens, ensuring disbursements do not exceed deposits.
