pragma solidity ^0.8.17;


contract Oracle {
    
    // Maximum voter stake
    uint256 max_voter_stake = 25;

    // Minimum voter stake
    uint256 min_voter_stake = 1;

    // Maximum certifier stake
    uint256 max_certifier_stake = 100;

    // Minimum certifier stake
    uint256 min_certifier_stake = 25;
    
    // Maximum user reputation
    uint256 max_reputation = 100; // set to '1' for system without reputation

    // When stake pool reaches this, close proposition
    uint256 max_total_stake = 499;

    // Track number of props
    uint256 total_props = 0;

    // Certifier reward pools
    uint256 cert_pool_t = 0;
    uint256 cert_pool_f = 0;


    // Mapping of users registered in the system, along with their user account balance
    mapping(address => bool) public isRegisteredVoter;
    mapping(address => bool) public isRegisteredCertifier;

    mapping (address => bool) isCurrentlyCertifying;

    // Reputation of each address
    mapping (address => uint256) reputations;
    
    // Current user balance (not neccesarily msg.sender.balance)
    mapping (address => uint256) user_balances;
    
    // Maps voters to a mapping of prop_id to stake. Tracks stakes for voters that have
    // requested a proposition to vote on, but not yet cast a vote.
    mapping (address => mapping(uint256 => uint256)) to_vote;
    mapping (address => bool) is_voting;

    // Maps eligible certifiers to stake. I.e., tracks stakes for certifiers that have
    // requested to certify some proposition, but not yet cast a vote.
    mapping (address => uint256) to_certify;
    
    // Propositions
    mapping (uint256 => Proposition) propositions;
    uint256[] active_propositions;

    // outcomes
    uint[] public outcome_list;

    struct Vote {
        address voter;
        uint256 stake;
        bool vote;
        uint256 weighted_stake;
        bool is_voter; // true = voter, false = certifier
    }

    struct Proposition {
        address submitter;
        uint256 bounty;
        string proposition;
        Vote[] votes;
        uint256 total_stake;
        uint256 sum_voter_t; // WEIGHTED SUM
        uint256 sum_voter_f; // WEIGHTED SUM
        uint256 sum_cert_t; // WEIGHTED SUM
        uint256 sum_cert_f; // WEIGHTED SUM
        bool status; // true = open, false = closed
    }

    // Return user's current reputation
    // If reputation is negative, instead returns 0
    function reputation() public view returns(uint256) {
        uint256 rep = reputations[msg.sender];
        if (rep < 0)
            return 1;
        return rep;
    }

    // Increment the reputation of a voter
    function increment_reputation(address _voter) internal {
        uint256 rep = reputations[_voter];
        if (rep < max_reputation) {
            reputations[_voter] += 1;
        }
    }
    

    // Decrement the reputation of a voter
    function decrement_reputation(address _voter) internal {
        uint256 rep = reputations[_voter];
        if (rep == 1) {
            reputations[_voter] = 1;
        }
        else {
            reputations[_voter] -= 1;
        }
    }
    
    // Calculate the vote weight using stake & reputation
    function calculate_weight(uint256 stake, uint256 rep) internal view returns(uint256) {
        return sqrt(stake * (rep));
    }
    
    // Transfer funds from user account 
    function transferToBalance() external payable {
        require(isRegisteredVoter[msg.sender] == true, "You are not currently registered in the system. Please register");
        //msg.sender.transfer(transferAmount);
        user_balances[msg.sender] += msg.value;
    }

    // Check current balance in user account
    function checkBalance() public view returns(uint256){
        require(isRegisteredVoter[msg.sender] == true, "You are not currently registered in the system. Please register");
        return user_balances[msg.sender];
    }

    // Withdraw funds from user account 
    function withdrawFromBalance(address payable recipient, uint256 withdrawAmount) public payable {
        require(isRegisteredVoter[msg.sender] == true, "You are not currently registered in the system. Please register");
        require(withdrawAmount > 0, "Cannot cash out negative amount.");
        uint256 currentUserBalance = user_balances[msg.sender];
        require(withdrawAmount <= currentUserBalance, "You do not have enough funds to cash out this amount.");
        recipient.transfer(withdrawAmount);
        user_balances[msg.sender] -= withdrawAmount;
    }
    

    // Register voter to participate in the decentralized oracle protocol. Assign starting reputation to 1
    function register_user(bool is_voter) external {
        require(isRegisteredCertifier[msg.sender] != true && isRegisteredVoter[msg.sender] != true, "You are already registered in the system");
        
        reputations[msg.sender] = 1;
        user_balances[msg.sender] = 2000;
        if (is_voter) {
            isRegisteredVoter[msg.sender] = true;
            isRegisteredCertifier[msg.sender] = false;
        }
        else {
            isRegisteredCertifier[msg.sender] = true;
            isRegisteredVoter[msg.sender] = false;
        }
    }

    // Allow submitter to create a proposition, along with their submission bounty
    function create_proposition(uint256 bounty, string memory proposition_question) external{
        uint256 prop_id = total_props;
        total_props += 1;
        
        // propositions[prop_id] = Proposition(msg.sender, bounty, proposition_question, new Vote[](0), 0, 0, 0, 0, 0, true);
        Proposition storage prop = propositions[prop_id];
        prop.submitter = msg.sender;
        prop.bounty = bounty;
        prop.proposition = proposition_question;
        prop.status = true;

        active_propositions.push(prop_id);
    }

    // Allow user to submit their certifying stake (if they haven't already done so.)
    function request_certify(uint256 certify_stake) external {
        require(isRegisteredCertifier[msg.sender] == true, "You are not currently registered in the system. Please register.");
        require(certify_stake <= max_certifier_stake, "Your certifier stake is too high");
        require(certify_stake >= min_certifier_stake, "Your certifier stake is too low");
        require(user_balances[msg.sender] > certify_stake, "You currently do not have enough funds in your account to provide this certifier stake.");
        require(isCurrentlyCertifying[msg.sender] == false, "You have already provided your certifier stake. Please use your submitted stake to certify a proposition.");
        
        uint256 num_props = active_propositions.length;
        require(num_props >= 1, "No propositions available");

        user_balances[msg.sender] -= certify_stake;
        to_certify[msg.sender] = certify_stake;
        isCurrentlyCertifying[msg.sender] = true;
    }
    
    // Submit certification vote (if eligible)
    function submit_certification_vote(uint256 chosen_proposition_id, bool certify_vote) external {
        require(isRegisteredCertifier[msg.sender] == true, "You are not currently registered in the system. Please register.");
        require(isCurrentlyCertifying[msg.sender] == true, "You have not yet submitted a stake to be eligible to certify.");
      
        uint256 certify_stake = to_certify[msg.sender];
        
        // Add vote to list of proposition votes
        Proposition storage prop = propositions[chosen_proposition_id];
        uint256 weighted_stake = calculate_weight(certify_stake, reputations[msg.sender]);
        prop.votes.push(Vote(msg.sender, certify_stake, certify_vote, weighted_stake, true));

        // Update that vote is no longer certifying
        isCurrentlyCertifying[msg.sender] == false;
        // Set their certifying stake to 0
        to_certify[msg.sender] = 0;
        
        // Update total stake and total weighted stake associated with the proposition
        prop.total_stake += certify_stake;
        if (certify_vote)
            prop.sum_cert_t += weighted_stake;
        else
            prop.sum_cert_f += weighted_stake;
        
        // Close proposition if total stake exceeds max_total_stake
        if (prop.total_stake > max_total_stake) {
            close_proposition(chosen_proposition_id);
        }
    }

    // Request a random proposition as a voter
    function request_vote(uint256 vote_stake) external returns(uint256) {
        require(isRegisteredVoter[msg.sender] == true, "You are not currently registered in the system. Please register");
        require(is_voting[msg.sender] == false, "You have already a proposition and have not voted on it");
        require(vote_stake >= min_voter_stake, "Vote stake too low");
        require(vote_stake <= max_voter_stake, "Vote stake too high");
        require(user_balances[msg.sender] > vote_stake, "You currently do not have enough funds in your account to provide this voter stake.");

        uint256 num_props = active_propositions.length;
        require(num_props >= 1, "No propositions available");

        is_voting[msg.sender] = true;
        
        uint256 rand_index = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender))) % num_props;
        uint256 prop_id = active_propositions[rand_index];
        to_vote[msg.sender][prop_id] = vote_stake;

        user_balances[msg.sender] -= vote_stake;

        return prop_id;
    }

    // Submit a vote
    function submit_vote(uint256 prop_id, bool vote) external {
        require(isRegisteredVoter[msg.sender] == true, "You are not currently registered in the system. Please register");
        uint256 vote_stake = to_vote[msg.sender][prop_id];
        require(vote_stake > 0, "No stake; not a voter for this proposition");
        to_vote[msg.sender][prop_id] = 0;
        is_voting[msg.sender] = false;
        
        // Add vote to list of proposition votes
        uint256 weighted_stake = calculate_weight(vote_stake, reputations[msg.sender]);
        propositions[prop_id].votes.push(Vote(msg.sender, vote_stake, vote, weighted_stake, true));
        propositions[prop_id].total_stake += vote_stake;

        if (vote)
            propositions[prop_id].sum_voter_t += weighted_stake;
        else
            propositions[prop_id].sum_voter_f += weighted_stake;

        // Close proposition if total stake exceeds max_total_stake
        if (propositions[prop_id].total_stake > max_total_stake) {
            close_proposition(prop_id);
        }
    }

    // Evaluate the outcome of a proposition
    // Returns: 0 (False), 1 (True), 2 (Unknown)
    function evaluate_proposition(uint256 prop_id) internal returns(uint) {
        Proposition storage prop = propositions[prop_id];
        
        // Calculate voter outcome
        uint voter_outcome = 2;
        if (prop.sum_voter_t > prop.sum_voter_f)
            voter_outcome = 1;
        else if (prop.sum_voter_f > prop.sum_voter_t)
            voter_outcome = 0;
        
        // Calculate certifier outcome
        uint cert_outcome = 2;
        if (prop.sum_cert_t > prop.sum_cert_f)
            cert_outcome = 1;
        else if (prop.sum_cert_f > prop.sum_cert_t)
            cert_outcome = 0;
        
        // Check if either outcome is unknown, or if the outcomes are not equal
        /*if (voter_outcome == 2 || cert_outcome == 2 || voter_outcome != cert_outcome)
            return 2;*/
        
        // If certifier outcome is unknown, return voter outcome
        if (cert_outcome == 2) {
            return voter_outcome;
        }
        else {
            if (voter_outcome != 2 && voter_outcome != cert_outcome)
            return 2;
        }
        
        // Otherwise, the outcomes are both known and equal
        return voter_outcome;
    }

    // Close a proposition
    function close_proposition(uint256 prop_id) internal {
        propositions[prop_id].status = false;

        // Find proposition in list of active props, replace it with the one at the end of the list
        for (uint256 i = 0; i < active_propositions.length; i++) {
            if (active_propositions[i] == prop_id) {
                active_propositions[i] = active_propositions[active_propositions.length - 1];
                active_propositions.pop();
                break;
            }
        }

        uint outcome = evaluate_proposition(prop_id);
        // append oracle decision to outcome list
        outcome_list.push(outcome);
        update_reputation_and_reward(prop_id, outcome);
    }

    // Update reputation of all users who participated in a finalized proposition
    function update_reputation_and_reward(uint256 prop_id, uint outcome) internal {
        Proposition storage prop = propositions[prop_id];

        // Case: outcome unknown
        if (outcome == 2) {
            // Add bounty to certifier reward pool
            cert_pool_t += prop.bounty / 2;
            cert_pool_f += prop.bounty / 2;
            for (uint i = 0; i < prop.votes.length; i++) {
                Vote storage v = prop.votes[i];
                if (v.is_voter)
                    user_balances[v.voter] += v.stake; // Return stakes for voters
                else
                    decrement_reputation(v.voter); // Don't return stakes for certifiers; decrement reputation
            }
        }

        uint256 voter_total;
        uint256 cert_total;
        uint256 cert_pool;
        bool out;
        if (outcome == 1) {
            voter_total = prop.sum_voter_t;
            cert_total = prop.sum_cert_t;
            cert_pool = cert_pool_t;

            cert_pool_t -= cert_total;

            out = true;
        }
        else {
            voter_total = prop.sum_voter_f;
            cert_total = prop.sum_cert_f;
            cert_pool = cert_pool_f;

            cert_pool_f -= cert_total;

            out = false;
        }

        uint256 penalty = 0; // Total lost stakes

        for (uint i = 0; i < prop.votes.length; i++) {
            //Vote storage v = prop.votes[i];
            // Reward correct voters and increment their reputation
            if (prop.votes[i].vote == out) {
                increment_reputation(prop.votes[i].voter);
                if (prop.votes[i].is_voter) {
                    user_balances[prop.votes[i].voter] += prop.votes[i].stake + prop.bounty * prop.votes[i].weighted_stake / voter_total;
                }
                else {
                    user_balances[prop.votes[i].voter] += prop.votes[i].stake + cert_pool * prop.votes[i].weighted_stake / cert_total;
                }
            }
            // Decrement reputation of incorrect voters; add their stake to penalty pool
            else {
                decrement_reputation(prop.votes[i].voter);
                penalty += prop.votes[i].stake;
            }
        }

        // Add penalty to the corresponding certifier pool based on what the outcome was
        if (outcome == 1)
            cert_pool_f += penalty;
        else
            cert_pool_t += penalty;
    }

    // Calculate square root
    // source: https://ethereum.stackexchange.com/questions/2910/can-i-square-root-in-solidity
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) {
            return 0;
        }

        // Calculate the square root of the perfect square of a power of two that is the closest to x.
        uint256 xAux = uint256(x);
        result = 1;
        if (xAux >= 0x100000000000000000000000000000000) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 0x10000000000000000) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 0x100000000) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 0x10000) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 0x100) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 0x10) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 0x8) {
            result <<= 1;
        }

        // The operations can never overflow because the result is max 2^127 when it enters this block.
        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1; // Seven iterations should be enough
            uint256 roundedDownResult = x / result;
            return result >= roundedDownResult ? roundedDownResult : result;
        }
    }
    
}