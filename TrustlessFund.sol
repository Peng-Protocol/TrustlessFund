// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.18 (06/11/2025)
// Changelog:
// - 06/11/2025: Removed fair-split cap from _disburseERC20 (caused under-disbursement in sequential disburse calls)
// - 06/11/2025: Fair-split now only applied in distributeToGrantees (push model)
// - 06/11/2025: disburse() now disburses up to remaining/balance without per-grantee cap
// - 06/11/2025: Fixed partial payment shortfall loss in disburse() & distributeToGrantees()
// - 06/11/2025: Helper _calcOwed computes owed = currentPeriod * amount - withdrawn
// - 06/11/2025: Fair-split caps applied before transfer; state updated by sent
// - 06/11/2025: disbursedGrantees now tracks cumulative amount withdrawn per grantee
// - 06/11/2025: _disburseERC20 returns amount sent; state updated proportionally
// - 06/11/2025: Removed periodsToPay logic; owed = (currentPeriod * amount) - withdrawn
// - 06/11/2025: _disburseERC20 – cap per-grantee to remaining / grantees left (fair split)
// - 04/11/2025: Removed active check from addTokens → allows resurrection.
// - 04/11/2025: Added views.
// - 04/11/2025: Added nonReentrant guard to disburse/distributeToGrantees
// - 04/11/2025: Improved recurring distribution calculation, added structs.
// - 04/11/2025: Split distributeToGrantees to resolve stack error, added structs.
// - 04/11/2025: Improved fund tracking.
// - 04/11/2025: Fixed distributeToGrantees overpayment: calculate per-grantee owed amount.
// - 04/11/2025: Unified logic with disburse(): use periodsToPay = currentPeriod - lastPeriod.
// - 04/11/2025: Restricted warp/unWarp to owner only.
// - 04/11/2025: Removed lockedUntil mutation in distributeToGrantees.
// - 04/11/2025: Fixed distributeToGrantees: use token.transfer() not transferFrom() for ERC20.
// - 04/11/2025: Fixed disburse() state update before transfer (critical bug).
// - 04/11/2025: Removed redundant tokenId assignment in createOneTimeFund.
// - 04/11/2025: Added time-warp system (currentTime, isWarped, warp(), unWarp(), _now()) for VM testing.
// - v0.0.4 (09/10): Added lastDisbursedIndex to Fund struct; Updated distributeToGrantees to track disbursed grantees; Added disbursedGrantees mapping to Fund struct; Updated disburse to track per-grantee disbursements
// - v0.0.3 (09/10): Replaced trustee with grantees array; Added distributeToGrantees; Split proposeGranteeChange into proposeGranteeAddition/Removal
// - v0.0.2 (09/10): Optimized view functions; Prevented ERC721 in createRecurringFund; Added tokenIds array
// - v0.0.1 (09/10): Initial implementation

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}
interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function balanceOf(address account) external view returns (uint256);
}

contract TrustlessFund {
	uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status; // Reentrancy guard
    
    enum FundType { ERC20, ERC721 }
    enum ProposalType { GranteeAddition, GranteeRemoval, AddGrantor, RemoveGrantor }

    struct Fund {
    address[] grantees;
    uint256 lockedUntil;
    uint256 disbursementAmount;
    uint256 disbursementInterval;
    FundType fundType;
    address[] grantors;
    address tokenContract;
    uint256[] tokenIds;
    bool active;
    uint256 lastDisbursedIndex;
    mapping(address => uint256) disbursedGrantees;

    // --- NEW (0.0.10): Track intended pool ---
    uint256 totalIntended;     // Total tokens meant to be distributed (initial + added)
    uint256 totalDisbursed;    // Cumulative successfully sent
}

    struct Proposal {
        uint256 fundId;
        address[] targetAddresses;
        uint256 votesFor;
        uint256 deadline;
        bool executed;
        ProposalType proposalType;
        mapping(address => bool) voted;
    }
    
    struct DistributeERC20Params {
    uint256 periods;
    uint256 intendedTotal;
    uint256 remainingIntended;
    uint256 contractBalance;
}
    struct DistributeLoopState {
    uint256 perGrantee;
    uint256 totalDisbursed;
    uint256 i;
    address grantee;
}

struct DistributeERC20Calc {
    uint256 periods;
    uint256 remainingIntended;
    uint256 contractBalance;
}
struct DistributeERC20State {
    uint256 totalDisbursed;
    uint256 i;
    address grantee;
    uint256 amountToPay;
}

    mapping(uint256 => Fund) public funds;
    mapping(uint256 => Proposal) public proposals;
    uint256 public fundCount;
    uint256 public proposalCount;

    address public owner;
    uint256 public currentTime;   // Warp state
    bool public isWarped;         // Warp flag

    event FundCreated(uint256 indexed fundId, address firstGrantee, uint256 lockedUntil, FundType fundType);
    event Deposited(uint256 indexed fundId, address tokenContract, uint256 amountOrId);
    event Disbursed(uint256 indexed fundId, address grantee, uint256 amountOrId);
    event ProposalCreated(uint256 indexed proposalId, uint256 fundId, address firstTarget, ProposalType proposalType);
    event Voted(uint256 indexed proposalId, address grantor, bool inFavor);
    event GranteeAdded(uint256 indexed fundId, address newGrantee);
    event GranteeRemoved(uint256 indexed fundId, address removedGrantee);
    event GrantorAdded(uint256 indexed fundId, address newGrantor);
    event GrantorRemoved(uint256 indexed fundId, address removedGrantor);
    
    constructor() {
    	_status = _NOT_ENTERED;
        owner = msg.sender;
    }
    
    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // --- Time warp ---
    function warp(uint256 newTimestamp) external {
        require(msg.sender == owner, "Not owner");
        currentTime = newTimestamp;
        isWarped = true;
    }

    function unWarp() external {
        require(msg.sender == owner, "Not owner");
        isWarped = false;
    }

    function _now() internal view returns (uint256) {
        return isWarped ? currentTime : block.timestamp;
    }

    // --- Fund creation ---
    function createOneTimeFund(
    address[] memory grantees,
    uint256 lockedUntil,
    address tokenContract,
    uint256 amountOrId,
    FundType fundType
) external {
    require(grantees.length > 0, "No grantees");
    address[] memory grantors = new address[](1);
    grantors[0] = msg.sender;
    fundCount++;
    Fund storage fund = funds[fundCount];
    fund.grantees = grantees;
    fund.lockedUntil = lockedUntil;
    fund.disbursementAmount = amountOrId;
    fund.disbursementInterval = 0;
    fund.fundType = fundType;
    fund.grantors = grantors;
    fund.tokenContract = tokenContract;
    fund.tokenIds = new uint256[](0);
    fund.active = true;
    fund.lastDisbursedIndex = 0;

    // --- NEW: Set intended pool ---
    fund.totalIntended = amountOrId;
    fund.totalDisbursed = 0;

    _transferTokens(tokenContract, amountOrId, fundType);
    emit FundCreated(fundCount, grantees[0], lockedUntil, fundType);
}

    function createRecurringFund(
    address[] memory grantees,
    uint256 lockedUntil,
    uint256 disbursementAmount,
    uint256 disbursementInterval,
    address tokenContract,
    uint256 amountOrId,
    FundType fundType
) external {
    require(grantees.length > 0, "No grantees");
    require(disbursementInterval > 0, "Invalid interval");
    require(fundType == FundType.ERC20, "ERC721 not allowed for recurring");
    address[] memory grantors = new address[](1);
    grantors[0] = msg.sender;
    fundCount++;
    Fund storage fund = funds[fundCount];
    fund.grantees = grantees;
    fund.lockedUntil = lockedUntil;
    fund.disbursementAmount = disbursementAmount;
    fund.disbursementInterval = disbursementInterval;
    fund.fundType = fundType;
    fund.grantors = grantors;
    fund.tokenContract = tokenContract;
    fund.tokenIds = new uint256[](0);
    fund.active = true;
    fund.lastDisbursedIndex = 0;

    // --- NEW: Set intended pool ---
    fund.totalIntended = amountOrId;
    fund.totalDisbursed = 0;

    _transferTokens(tokenContract, amountOrId, fundType);
    emit FundCreated(fundCount, grantees[0], lockedUntil, fundType);
}

    function _transferTokens(address tokenContract, uint256 amountOrId, FundType fundType) private {
        uint256 preBalance = fundType == FundType.ERC20
            ? IERC20(tokenContract).balanceOf(address(this))
            : IERC721(tokenContract).balanceOf(address(this));
        if (fundType == FundType.ERC20) {
            require(IERC20(tokenContract).transferFrom(msg.sender, address(this), amountOrId), "ERC20 transfer failed");
        } else {
            IERC721(tokenContract).transferFrom(msg.sender, address(this), amountOrId);
            funds[fundCount].tokenIds.push(amountOrId);
        }
        uint256 postBalance = fundType == FundType.ERC20
            ? IERC20(tokenContract).balanceOf(address(this))
            : IERC721(tokenContract).balanceOf(address(this));
        require(postBalance > preBalance, "No tokens received");
        emit Deposited(fundCount, tokenContract, amountOrId);
    }

    // --- Disbursement ---
    function disburse(uint256 fundId) external nonReentrant {
    Fund storage fund = funds[fundId];
    require(fund.active, "Fund inactive");
    require(_isGrantee(fund, msg.sender), "Not grantee");
    require(_now() >= fund.lockedUntil, "Locked");

    if (fund.disbursementInterval > 0) {
        uint256 currentPeriod = (_now() - fund.lockedUntil) / fund.disbursementInterval;
        uint256 owed = currentPeriod * fund.disbursementAmount;
        uint256 withdrawn = fund.disbursedGrantees[msg.sender];
        if (owed <= withdrawn) return; // No new claim

        uint256 amountToSend = owed - withdrawn;
        uint256 sent = _disburseERC20(fundId, msg.sender, amountToSend);
        if (sent > 0) fund.disbursedGrantees[msg.sender] = withdrawn + sent;
        emit Disbursed(fundId, msg.sender, sent);
    } else {
        require(fund.disbursedGrantees[msg.sender] == 0, "Already claimed");
        if (fund.fundType == FundType.ERC20) {
            uint256 sent = _disburseERC20(fundId, msg.sender, fund.disbursementAmount);
            if (sent > 0) fund.disbursedGrantees[msg.sender] = sent;
            emit Disbursed(fundId, msg.sender, sent);
        } else {
            require(fund.tokenIds.length > 0, "No NFTs");
            uint256 tokenId = fund.tokenIds[fund.tokenIds.length - 1];
            fund.tokenIds.pop();
            fund.disbursedGrantees[msg.sender] = 1;
            fund.totalDisbursed += 1;
            emit Disbursed(fundId, msg.sender, tokenId);
            IERC721(fund.tokenContract).transferFrom(address(this), msg.sender, tokenId);
            _checkFundExhaustion(fundId);
        }
    }
}

function _checkFundExhaustion(uint256 fundId) private {
        Fund storage fund = funds[fundId];
        if (fund.totalDisbursed < fund.totalIntended) return;

        // Only deactivate if no future periods owed
        if (fund.disbursementInterval > 0) {
            uint256 futurePeriods = (_now() - fund.lockedUntil) / fund.disbursementInterval;
            for (uint256 i = 0; i < fund.grantees.length; i++) {
                if (fund.disbursedGrantees[fund.grantees[i]] < futurePeriods + 1) {
                    return; // still owed
                }
            }
        }
        fund.active = false;
    }

    function _disburseERC20(uint256 fundId, address to, uint256 requested) private returns (uint256 sent) {
    Fund storage fund = funds[fundId];
    IERC20 token = IERC20(fund.tokenContract);
    uint256 balance = token.balanceOf(address(this));
    uint256 remaining = fund.totalIntended > fund.totalDisbursed ? fund.totalIntended - fund.totalDisbursed : 0;

    sent = requested;
    if (sent > remaining) sent = remaining;
    if (sent > balance) sent = balance;
    if (sent == 0) return 0;

    // REMOVED: Fair-split cap — unsafe in sequential pull calls
    // It under-disburses when grantees claim one-by-one

    fund.totalDisbursed += sent;
    bool success = token.transfer(to, sent);
    if (!success) {
        fund.totalDisbursed -= sent;
        sent = 0;
    } else {
        _checkFundExhaustion(fundId);
    }
    return sent;
}

    function _disburseERC721(uint256 fundId) private {
        Fund storage fund = funds[fundId];
        require(fund.tokenIds.length > 0, "No tokens to disburse");
        IERC721 token = IERC721(fund.tokenContract);
        uint256 tokenId = fund.tokenIds[fund.tokenIds.length - 1];
        fund.tokenIds.pop();
        token.transferFrom(address(this), msg.sender, tokenId);
        if (fund.tokenIds.length == 0) fund.active = false;
    }

    function distributeToGrantees(uint256 fundId, uint256 maxIterations) external nonReentrant {
    Fund storage fund = funds[fundId];
    require(fund.active, "Fund inactive");
    require(fund.disbursementInterval > 0, "Not recurring");
    require(_now() >= fund.lockedUntil, "Locked");

    uint256 currentPeriod = (_now() - fund.lockedUntil) / fund.disbursementInterval;
    uint256 start = fund.lastDisbursedIndex;
    uint256 end = _min(start + maxIterations, fund.grantees.length);
    uint256 pending = 0;

    // Count pending grantees for fair split
    for (uint256 i = 0; i < fund.grantees.length; i++) {
        if (_calcOwed(fund, fund.grantees[i], currentPeriod) > 0) pending++;
    }

    uint256 remaining = fund.totalIntended > fund.totalDisbursed ? fund.totalIntended - fund.totalDisbursed : 0;
    uint256 maxPer = pending > 1 ? remaining / pending : remaining;

    for (uint256 i = start; i < end; i++) {
        address grantee = fund.grantees[i];
        uint256 owed = _calcOwed(fund, grantee, currentPeriod);
        if (owed == 0) continue;

        uint256 amount = owed;
        if (amount > maxPer) amount = maxPer;
        if (amount > remaining) amount = remaining;

        uint256 sent = _disburseERC20(fundId, grantee, amount);
        if (sent > 0) {
            fund.disbursedGrantees[grantee] += sent;
            fund.lastDisbursedIndex = i + 1;
            remaining -= sent;
            if (pending > 1) maxPer = remaining / --pending;
        }
        emit Disbursed(fundId, grantee, sent);
    }
    _checkFundExhaustion(fundId);
}

// -- New Helpers (0.0.17)
function _calcOwed(Fund storage fund, address grantee, uint256 currentPeriod) private view returns (uint256) {
    uint256 totalOwed = currentPeriod * fund.disbursementAmount;
    uint256 withdrawn = fund.disbursedGrantees[grantee];
    return totalOwed > withdrawn ? totalOwed - withdrawn : 0;
}

function _min(uint256 a, uint256 b) private pure returns (uint256) {
    return a < b ? a : b;
}

// --- Helper: global caps ---
function _calcERC20Globals(Fund storage fund) private view returns (uint256 periods, uint256 remaining, uint256 balance) {
        periods = fund.disbursementInterval > 0
            ? (_now() - fund.lockedUntil) / fund.disbursementInterval
            : 0;
        remaining = fund.totalIntended > fund.totalDisbursed ? fund.totalIntended - fund.totalDisbursed : 0;
        balance = IERC20(fund.tokenContract).balanceOf(address(this));
    }

// --- More helpers ---
function _calcERC20Available(Fund storage fund) private view returns (DistributeERC20Params memory p) {
    p.periods = fund.disbursementInterval > 0
        ? (_now() - fund.lockedUntil) / fund.disbursementInterval
        : 1;
    p.intendedTotal = fund.disbursementAmount * p.periods * fund.grantees.length;
    p.remainingIntended = fund.totalIntended > fund.totalDisbursed
        ? fund.totalIntended - fund.totalDisbursed
        : 0;
    p.intendedTotal = p.intendedTotal > p.remainingIntended ? p.remainingIntended : p.intendedTotal;
    p.contractBalance = IERC20(fund.tokenContract).balanceOf(address(this));
    if (p.intendedTotal > p.contractBalance) p.intendedTotal = p.contractBalance;
}

function _shouldDisburseGrantee(Fund storage fund, address grantee, uint256 periods) private view returns (bool) {
    uint256 last = fund.disbursedGrantees[grantee];
    uint256 current = fund.disbursementInterval > 0 ? periods : 1;
    return last < current;
}
    
    function addTokens(uint256 fundId, uint256 amountOrId) external {
        Fund storage fund = funds[fundId];
        require(fund.tokenContract != address(0), "Invalid fund");

        uint256 preBalance = fund.fundType == FundType.ERC20
            ? IERC20(fund.tokenContract).balanceOf(address(this))
            : IERC721(fund.tokenContract).balanceOf(address(this));

        if (fund.fundType == FundType.ERC20) {
            require(IERC20(fund.tokenContract).transferFrom(msg.sender, address(this), amountOrId), "ERC20 transfer failed");
        } else {
            IERC721(fund.tokenContract).transferFrom(msg.sender, address(this), amountOrId);
            fund.tokenIds.push(amountOrId);
        }

        uint256 postBalance = fund.fundType == FundType.ERC20
            ? IERC20(fund.tokenContract).balanceOf(address(this))
            : IERC721(fund.tokenContract).balanceOf(address(this));
        require(postBalance > preBalance, "No tokens received");

        // --- REACTIVATION LOGIC ---
        fund.totalIntended += amountOrId;
        fund.active = true; // RESURRECT if was inactive

        emit Deposited(fundId, fund.tokenContract, amountOrId);
    }

    // --- Proposals ---
    function proposeGranteeAddition(uint256 fundId, address[] memory newGrantees) external {
        Fund storage fund = funds[fundId];
        require(fund.active, "Fund not active");
        require(_isGrantor(fund, msg.sender), "Not a grantor");
        require(newGrantees.length > 0, "No grantees");
        for (uint256 i = 0; i < newGrantees.length; i++) {
            require(newGrantees[i] != address(0), "Invalid grantee");
            require(!_isGrantee(fund, newGrantees[i]), "Already a grantee");
        }
        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.fundId = fundId;
        proposal.targetAddresses = newGrantees;
        proposal.deadline = _now() + 7 days;
        proposal.proposalType = ProposalType.GranteeAddition;
        emit ProposalCreated(proposalCount, fundId, newGrantees[0], ProposalType.GranteeAddition);
    }

    function proposeGranteeRemoval(uint256 fundId, address[] memory granteesToRemove) external {
        Fund storage fund = funds[fundId];
        require(fund.active, "Fund not active");
        require(_isGrantor(fund, msg.sender), "Not a grantor");
        require(fund.grantees.length > granteesToRemove.length, "Cannot remove all grantees");
        for (uint256 i = 0; i < granteesToRemove.length; i++) {
            require(_isGrantee(fund, granteesToRemove[i]), "Not a grantee");
        }
        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.fundId = fundId;
        proposal.targetAddresses = granteesToRemove;
        proposal.deadline = _now() + 7 days;
        proposal.proposalType = ProposalType.GranteeRemoval;
        emit ProposalCreated(proposalCount, fundId, granteesToRemove[0], ProposalType.GranteeRemoval);
    }

    function proposeAddGrantor(uint256 fundId, address newGrantor) external {
        Fund storage fund = funds[fundId];
        require(fund.active, "Fund not active");
        require(_isGrantor(fund, msg.sender), "Not a grantor");
        require(newGrantor != address(0), "Invalid grantor");
        require(!_isGrantor(fund, newGrantor), "Already a grantor");
        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.fundId = fundId;
        proposal.targetAddresses = new address[](1);
        proposal.targetAddresses[0] = newGrantor;
        proposal.deadline = _now() + 7 days;
        proposal.proposalType = ProposalType.AddGrantor;
        emit ProposalCreated(proposalCount, fundId, newGrantor, ProposalType.AddGrantor);
    }

    function proposeRemoveGrantor(uint256 fundId, address grantorToRemove) external {
        Fund storage fund = funds[fundId];
        require(fund.active, "Fund not active");
        require(_isGrantor(fund, msg.sender), "Not a grantor");
        require(_isGrantor(fund, grantorToRemove), "Not a grantor");
        require(fund.grantors.length > 1, "Cannot remove last grantor");
        proposalCount++;
        Proposal storage proposal = proposals[proposalCount];
        proposal.fundId = fundId;
        proposal.targetAddresses = new address[](1);
        proposal.targetAddresses[0] = grantorToRemove;
        proposal.deadline = _now() + 7 days;
        proposal.proposalType = ProposalType.RemoveGrantor;
        emit ProposalCreated(proposalCount, fundId, grantorToRemove, ProposalType.RemoveGrantor);
    }

    function voteOnProposal(uint256 proposalId, bool inFavor) external {
        Proposal storage proposal = proposals[proposalId];
        Fund storage fund = funds[proposal.fundId];
        require(_now() <= proposal.deadline, "Proposal expired");
        require(!proposal.executed, "Proposal executed");
        require(_isGrantor(fund, msg.sender), "Not a grantor");
        require(!proposal.voted[msg.sender], "Already voted");
        proposal.voted[msg.sender] = true;
        if (inFavor) proposal.votesFor++;
        emit Voted(proposalId, msg.sender, inFavor);
        _checkProposalOutcome(proposalId);
    }

    function _isGrantee(Fund storage fund, address account) private view returns (bool) {
        for (uint256 i = 0; i < fund.grantees.length; i++) {
            if (account == fund.grantees[i]) return true;
        }
        return false;
    }

    function _isGrantor(Fund storage fund, address account) private view returns (bool) {
        for (uint256 i = 0; i < fund.grantors.length; i++) {
            if (account == fund.grantors[i]) return true;
        }
        return false;
    }

    function _checkProposalOutcome(uint256 proposalId) private {
        Proposal storage proposal = proposals[proposalId];
        Fund storage fund = funds[proposal.fundId];
        uint256 totalGrantors = fund.grantors.length;
        if (proposal.votesFor * 100 / totalGrantors > 51) {
            if (proposal.proposalType == ProposalType.GranteeAddition) {
                for (uint256 i = 0; i < proposal.targetAddresses.length; i++) {
                    fund.grantees.push(proposal.targetAddresses[i]);
                    emit GranteeAdded(proposal.fundId, proposal.targetAddresses[i]);
                }
            } else if (proposal.proposalType == ProposalType.GranteeRemoval) {
                for (uint256 i = 0; i < proposal.targetAddresses.length; i++) {
                    _removeGrantee(fund, proposal.targetAddresses[i]);
                    emit GranteeRemoved(proposal.fundId, proposal.targetAddresses[i]);
                }
            } else if (proposal.proposalType == ProposalType.AddGrantor) {
                fund.grantors.push(proposal.targetAddresses[0]);
                emit GrantorAdded(proposal.fundId, proposal.targetAddresses[0]);
            } else {
                _removeGrantor(fund, proposal.targetAddresses[0]);
                emit GrantorRemoved(proposal.fundId, proposal.targetAddresses[0]);
            }
            proposal.executed = true;
        }
    }

    function _removeGrantee(Fund storage fund, address granteeToRemove) private {
        for (uint256 i = 0; i < fund.grantees.length; i++) {
            if (fund.grantees[i] == granteeToRemove) {
                fund.grantees[i] = fund.grantees[fund.grantees.length - 1];
                fund.grantees.pop();
                break;
            }
        }
    }

    function _removeGrantor(Fund storage fund, address grantorToRemove) private {
        for (uint256 i = 0; i < fund.grantors.length; i++) {
            if (fund.grantors[i] == grantorToRemove) {
                fund.grantors[i] = fund.grantors[fund.grantors.length - 1];
                fund.grantors.pop();
                break;
            }
        }
    }

    // --- Views ---
    function granteeFunds(address grantee) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](fundCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= fundCount; i++) {
            if (_isGrantee(funds[i], grantee) && funds[i].active) {
                temp[index++] = i;
            }
        }
        uint256[] memory result = new uint256[](index);
        for (uint256 i = 0; i < index; i++) result[i] = temp[i];
        return result;
    }

    function grantorFunds(address grantor) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](fundCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= fundCount; i++) {
            if (_isGrantor(funds[i], grantor) && funds[i].active) {
                temp[index++] = i;
            }
        }
        uint256[] memory result = new uint256[](index);
        for (uint256 i = 0; i < index; i++) result[i] = temp[i];
        return result;
    }

    function fundProposals(uint256 fundId) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](proposalCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].fundId == fundId && !proposals[i].executed) {
                temp[index++] = i;
            }
        }
        uint256[] memory result = new uint256[](index);
        for (uint256 i = 0; i < index; i++) result[i] = temp[i];
        return result;
    }
    
    // Added views (0.0.14)
    function getTotalIntended(uint256 fundId) external view returns (uint256) {
    return funds[fundId].totalIntended;
}

function getTotalDisbursed(uint256 fundId) external view returns (uint256) {
    return funds[fundId].totalDisbursed;
}

function isActive(uint256 fundId) external view returns (bool) {
    return funds[fundId].active;
}
}