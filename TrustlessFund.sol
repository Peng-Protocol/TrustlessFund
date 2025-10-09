// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.4 (09/10/2025)
// Changelog:
// - v0.0.4 (09/10): Added lastDisbursedIndex to Fund struct; Updated distributeToGrantees to track disbursed grantees; Added disbursedGrantees mapping to Fund struct; Updated disburse to track per-grantee disbursements
// - v0.0.3 (09/10): Replaced trustee with grantees array; Added distributeToGrantees; Split proposeGranteeChange into proposeGranteeAddition/Removal
// - v0.0.2 (09/10): Optimized view functions; Prevented ERC721 in createRecurringFund; Added tokenIds array
// - v0.0.1 (09/10): Initial implementation



// Interface for ERC20 and ERC721 tokens
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}
interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function balanceOf(address account) external view returns (uint256);
}

// TrustlessFund contract for managing timed token disbursements
contract TrustlessFund {
    // Enum for fund type
    enum FundType { ERC20, ERC721 }

    // Enum for proposal type
    enum ProposalType { GranteeAddition, GranteeRemoval, AddGrantor, RemoveGrantor }

    // Struct for each fund
    struct Fund {
    address[] grantees; // Addresses allowed to receive disbursements
    uint256 lockedUntil; // Timestamp for disbursement
    uint256 disbursementAmount; // Amount for disbursement
    uint256 disbursementInterval; // Interval for recurring disbursements
    FundType fundType; // Type of token (ERC20/ERC721)
    address[] grantors; // Addresses that can propose changes
    address tokenContract; // Token contract address
    uint256[] tokenIds; // For ERC721, tracks token IDs; for ERC20, empty
    bool active; // Fund status
    uint256 lastDisbursedIndex; // Tracks last grantee index for distributeToGrantees
    mapping(address => uint256) disbursedGrantees; // Tracks last period (recurring) or 1 (one-time) for each grantee
}

    // Struct for proposals
    struct Proposal {
        uint256 fundId; // Fund ID associated with proposal
        address[] targetAddresses; // Addresses for grantee/grantor changes
        uint256 votesFor; // Number of votes in favor
        uint256 deadline; // Proposal expiration timestamp
        bool executed; // Whether proposal has been executed
        ProposalType proposalType; // Type of proposal
        mapping(address => bool) voted; // Track grantor votes
    }

    // State variables
    mapping(uint256 => Fund) public funds; // Maps fund ID to Fund struct
    mapping(uint256 => Proposal) public proposals; // Maps proposal ID to Proposal struct
    uint256 public fundCount; // Counter for fund IDs
    uint256 public proposalCount; // Counter for proposal IDs

    // Events
    event FundCreated(uint256 indexed fundId, address firstGrantee, uint256 lockedUntil, FundType fundType);
    event Deposited(uint256 indexed fundId, address tokenContract, uint256 amountOrId);
    event Disbursed(uint256 indexed fundId, address grantee, uint256 amountOrId);
    event ProposalCreated(uint256 indexed proposalId, uint256 fundId, address firstTarget, ProposalType proposalType);
    event Voted(uint256 indexed proposalId, address grantor, bool inFavor);
    event GranteeAdded(uint256 indexed fundId, address newGrantee);
    event GranteeRemoved(uint256 indexed fundId, address removedGrantee);
    event GrantorAdded(uint256 indexed fundId, address newGrantor);
    event GrantorRemoved(uint256 indexed fundId, address removedGrantor);

    // Create a one-time fund
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
    if (fundType == FundType.ERC721) {
        fund.tokenIds = new uint256[](1);
        fund.tokenIds[0] = amountOrId;
    }
    fund.active = true;
    fund.lastDisbursedIndex = 0;
    _transferTokens(tokenContract, amountOrId, fundType);
    emit FundCreated(fundCount, grantees[0], lockedUntil, fundType);
}

// create recurring fund
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
    _transferTokens(tokenContract, amountOrId, fundType);
    emit FundCreated(fundCount, grantees[0], lockedUntil, fundType);
}

    // Helper: Transfer tokens with balance checks
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

    // Disburse tokens by grantee
    function disburse(uint256 fundId) external {
    Fund storage fund = funds[fundId];
    require(fund.active, "Fund not active");
    require(_isGrantee(fund, msg.sender), "Not grantee");
    require(block.timestamp >= fund.lockedUntil, "Funds locked");
    if (fund.disbursementInterval > 0) {
        uint256 periods = (block.timestamp - fund.lockedUntil) / fund.disbursementInterval;
        require(periods > fund.disbursedGrantees[msg.sender], "Already disbursed");
        uint256 amount = fund.disbursementAmount * (periods - fund.disbursedGrantees[msg.sender]);
        fund.disbursedGrantees[msg.sender] = periods; // Update last disbursed period
        _disburseERC20(fundId, amount);
        emit Disbursed(fundId, msg.sender, amount);
    } else {
        require(fund.disbursedGrantees[msg.sender] == 0, "Already disbursed");
        fund.disbursedGrantees[msg.sender] = 1; // Mark as disbursed
        if (fund.fundType == FundType.ERC20) {
            _disburseERC20(fundId, fund.disbursementAmount);
            emit Disbursed(fundId, msg.sender, fund.disbursementAmount);
        } else {
            _disburseERC721(fundId);
            emit Disbursed(fundId, msg.sender, fund.tokenIds.length > 0 ? fund.tokenIds[fund.tokenIds.length - 1] : 0);
        }
    }
}

    // Helper: Disburse ERC20 tokens
    function _disburseERC20(uint256 fundId, uint256 amount) private {
        Fund storage fund = funds[fundId];
        IERC20 token = IERC20(fund.tokenContract);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) {
            emit Disbursed(fundId, msg.sender, 0);
            return;
        }
        require(token.transferFrom(address(this), msg.sender, amount), "Transfer failed");
    }

    // Helper: Disburse ERC721 tokens
    function _disburseERC721(uint256 fundId) private {
        Fund storage fund = funds[fundId];
        require(fund.tokenIds.length > 0, "No tokens to disburse");
        IERC721 token = IERC721(fund.tokenContract);
        uint256 tokenId = fund.tokenIds[fund.tokenIds.length - 1];
        fund.tokenIds.pop();
        token.transferFrom(address(this), msg.sender, tokenId);
        if (fund.tokenIds.length == 0) fund.active = false;
    }

    // Distribute tokens to grantees
    function distributeToGrantees(uint256 fundId, uint256 maxIterations) external {
    Fund storage fund = funds[fundId];
    require(fund.active, "Fund not active");
    require(block.timestamp >= fund.lockedUntil, "Funds locked");
    uint256 amountOrId = fund.disbursementAmount;
    uint256 periods = 0; // Declare periods for recurring funds
    if (fund.disbursementInterval > 0) {
        periods = (block.timestamp - fund.lockedUntil) / fund.disbursementInterval;
        require(periods > 0, "No disbursement available");
        amountOrId = fund.disbursementAmount * periods;
        fund.lockedUntil += periods * fund.disbursementInterval; // Update lockedUntil
    }
    uint256 startIndex = fund.lastDisbursedIndex;
    uint256 iterations = fund.grantees.length - startIndex > maxIterations ? maxIterations : fund.grantees.length - startIndex;
    if (fund.fundType == FundType.ERC20) {
        IERC20 token = IERC20(fund.tokenContract);
        uint256 balance = token.balanceOf(address(this));
        uint256 perGrantee = amountOrId / fund.grantees.length;
        if (balance < perGrantee * iterations) {
            emit Disbursed(fundId, msg.sender, 0);
            return;
        }
        for (uint256 i = 0; i < iterations; i++) {
            uint256 index = startIndex + i;
            address grantee = fund.grantees[index];
            if (fund.disbursementInterval > 0 && fund.disbursedGrantees[grantee] >= periods) continue;
            require(token.transferFrom(address(this), grantee, perGrantee), "Transfer failed");
            fund.disbursedGrantees[grantee] = periods; // Update last disbursed period
            emit Disbursed(fundId, grantee, perGrantee);
        }
    } else {
        require(fund.tokenIds.length >= iterations, "Insufficient tokens");
        IERC721 token = IERC721(fund.tokenContract);
        for (uint256 i = 0; i < iterations && fund.tokenIds.length > 0; i++) {
            uint256 index = startIndex + i;
            address grantee = fund.grantees[index];
            if (fund.disbursedGrantees[grantee] > 0) continue; // Skip if already disbursed
            uint256 tokenId = fund.tokenIds[fund.tokenIds.length - 1];
            fund.tokenIds.pop();
            token.transferFrom(address(this), grantee, tokenId);
            fund.disbursedGrantees[grantee] = 1; // Mark as disbursed
            emit Disbursed(fundId, grantee, tokenId);
        }
        if (fund.tokenIds.length == 0) fund.active = false;
    }
    fund.lastDisbursedIndex = startIndex + iterations;
    if (fund.lastDisbursedIndex >= fund.grantees.length) fund.lastDisbursedIndex = 0; // Reset for next cycle
}

    // Propose adding grantees
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
        proposal.deadline = block.timestamp + 7 days;
        proposal.proposalType = ProposalType.GranteeAddition;
        emit ProposalCreated(proposalCount, fundId, newGrantees[0], ProposalType.GranteeAddition);
    }

    // Propose removing grantees
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
        proposal.deadline = block.timestamp + 7 days;
        proposal.proposalType = ProposalType.GranteeRemoval;
        emit ProposalCreated(proposalCount, fundId, granteesToRemove[0], ProposalType.GranteeRemoval);
    }

    // Propose adding a grantor
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
        proposal.deadline = block.timestamp + 7 days;
        proposal.proposalType = ProposalType.AddGrantor;
        emit ProposalCreated(proposalCount, fundId, newGrantor, ProposalType.AddGrantor);
    }

    // Propose removing a grantor
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
        proposal.deadline = block.timestamp + 7 days;
        proposal.proposalType = ProposalType.RemoveGrantor;
        emit ProposalCreated(proposalCount, fundId, grantorToRemove, ProposalType.RemoveGrantor);
    }

    // Vote on a proposal
    function voteOnProposal(uint256 proposalId, bool inFavor) external {
        Proposal storage proposal = proposals[proposalId];
        Fund storage fund = funds[proposal.fundId];
        require(block.timestamp <= proposal.deadline, "Proposal expired");
        require(!proposal.executed, "Proposal executed");
        require(_isGrantor(fund, msg.sender), "Not a grantor");
        require(!proposal.voted[msg.sender], "Already voted");
        proposal.voted[msg.sender] = true;
        if (inFavor) proposal.votesFor++;
        emit Voted(proposalId, msg.sender, inFavor);
        _checkProposalOutcome(proposalId);
    }

    // Helper: Check if address is a grantee
    function _isGrantee(Fund storage fund, address account) private view returns (bool) {
        for (uint256 i = 0; i < fund.grantees.length; i++) {
            if (account == fund.grantees[i]) return true;
        }
        return false;
    }

    // Helper: Check if address is a grantor
    function _isGrantor(Fund storage fund, address account) private view returns (bool) {
        for (uint256 i = 0; i < fund.grantors.length; i++) {
            if (account == fund.grantors[i]) return true;
        }
        return false;
    }

    // Helper: Check proposal outcome and execute if passed
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

    // Helper: Remove grantee from array
    function _removeGrantee(Fund storage fund, address granteeToRemove) private {
        for (uint256 i = 0; i < fund.grantees.length; i++) {
            if (fund.grantees[i] == granteeToRemove) {
                fund.grantees[i] = fund.grantees[fund.grantees.length - 1];
                fund.grantees.pop();
                break;
            }
        }
    }

    // Helper: Remove grantor from array
    function _removeGrantor(Fund storage fund, address grantorToRemove) private {
        for (uint256 i = 0; i < fund.grantors.length; i++) {
            if (fund.grantors[i] == grantorToRemove) {
                fund.grantors[i] = fund.grantors[fund.grantors.length - 1];
                fund.grantors.pop();
                break;
            }
        }
    }

    // View: Get funds for a grantee
    function granteeFunds(address grantee) external view returns (uint256[] memory) {
    uint256[] memory temp = new uint256[](fundCount); // Over-allocate
    uint256 index = 0;
    for (uint256 i = 1; i <= fundCount; i++) {
        if (_isGrantee(funds[i], grantee) && funds[i].active) {
            temp[index] = i;
            index++;
        }
    }
    uint256[] memory result = new uint256[](index); // Correct size
    for (uint256 i = 0; i < index; i++) {
        result[i] = temp[i];
    }
    return result;
}

// Update grantorFunds function
function grantorFunds(address grantor) external view returns (uint256[] memory) {
    uint256[] memory temp = new uint256[](fundCount); // Over-allocate
    uint256 index = 0;
    for (uint256 i = 1; i <= fundCount; i++) {
        if (_isGrantor(funds[i], grantor) && funds[i].active) {
            temp[index] = i;
            index++;
        }
    }
    uint256[] memory result = new uint256[](index); // Correct size
    for (uint256 i = 0; i < index; i++) {
        result[i] = temp[i];
    }
    return result;
}

// Update fundProposals function
function fundProposals(uint256 fundId) external view returns (uint256[] memory) {
    uint256[] memory temp = new uint256[](proposalCount); // Over-allocate
    uint256 index = 0;
    for (uint256 i = 1; i <= proposalCount; i++) {
        if (proposals[i].fundId == fundId && !proposals[i].executed) {
            temp[index] = i;
            index++;
        }
    }
    uint256[] memory result = new uint256[](index); // Correct size
    for (uint256 i = 0; i < index; i++) {
        result[i] = temp[i];
    }
    return result;
}

    // Add tokens to an existing fund
    function addTokens(uint256 fundId, uint256 amountOrId) external {
        Fund storage fund = funds[fundId];
        require(fund.active, "Fund not active");
        require(fund.tokenContract != address(0), "Invalid token contract");
        _transferTokens(fund.tokenContract, amountOrId, fund.fundType);
    }
}