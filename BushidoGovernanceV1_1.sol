// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

/// @title BushidoGovernanceV1_1
/// @notice Plain OpenZeppelin v5 Governor for BTG. Voting power is exactly the voter's delegated WRunes
/// (WrappedRunesVotes) at the proposal's snapshot: one WRune, one vote.
/// @dev V1.1 deliberately has no virtue registry and no `_getVotes` override. The Bushido Virtue Score boost is
/// deferred to V2, which needs the registry to keep score history (checkpoints) so the bonus can be read at the
/// snapshot rather than at the moment of voting. MyGovernance is left unchanged alongside this contract.
/// WRunes uses a timestamp clock, so the delay and voting period below are in seconds. Governance can retune them
/// later with setVotingDelay / setVotingPeriod / setProposalThreshold / updateQuorumNumerator.
contract BushidoGovernanceV1_1 is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @notice The EIP-712 domain name used for signed votes (castVoteBySig).
    string public constant GOVERNOR_NAME = "BushidoGovernance V1.1";

    /// @notice 1 hour between a proposal and the start of voting (seconds: the token's clock is timestamps).
    uint48 public constant INITIAL_VOTING_DELAY = 1 hours;

    /// @notice 7 days of voting.
    uint32 public constant INITIAL_VOTING_PERIOD = 7 days;

    /// @notice No minimum holding is needed to propose.
    uint256 public constant INITIAL_PROPOSAL_THRESHOLD = 0;

    /// @notice 4% of the WRunes supply (at the proposal's snapshot) must vote For or Abstain for a result to count.
    uint256 public constant INITIAL_QUORUM_PERCENT = 4;

    /// @param _token The deployed WrappedRunesVotes (WRunes) contract.
    /// @param _timelock The TimelockController that executes passed proposals.
    constructor(IVotes _token, TimelockController _timelock)
        Governor(GOVERNOR_NAME)
        GovernorSettings(INITIAL_VOTING_DELAY, INITIAL_VOTING_PERIOD, INITIAL_PROPOSAL_THRESHOLD)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(INITIAL_QUORUM_PERCENT)
        GovernorTimelockControl(_timelock)
    {}

    // --- Required overrides: standard OpenZeppelin Governor wiring only, no custom logic ---

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
