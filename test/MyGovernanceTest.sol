// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../MyGovernance.sol";

/// @title MyGovernanceTest (TESTNET ONLY)
/// @notice The real MyGovernance with short timings so a full proposal (propose, vote, queue, execute) fits in
/// minutes: 60 s voting delay, 5 min voting period. Everything else (quorum, virtue bonus, timelock) is unchanged.
contract MyGovernanceTest is MyGovernance {
    constructor(IVotes token, TimelockController timelock, IDAOBTG2 registry)
        MyGovernance(token, timelock, registry)
    {
        _setVotingDelay(60);
        _setVotingPeriod(300);
    }
}
