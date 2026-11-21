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
/// @dev V1.1 has no virtue registry and no `_getVotes` override. The Bushido Virtue Score boost is deferred to V2,
/// which needs the registry to keep score history (checkpoints) so the bonus can be read at the snapshot.
/// It uses a fresh EIP-712 domain ("BushidoGovernance V1.1"), so signatures made for MyGovernance do not carry over.
/// WRunes uses a timestamp clock, so the delay and voting period are in seconds. Governance can retune them later
/// with setVotingDelay / setVotingPeriod / setProposalThreshold / updateQuorumNumerator.
contract BushidoGovernanceV1_1 is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @notice 1 day between a proposal and the start of voting.
    uint48 public constant INITIAL_VOTING_DELAY = 1 days;

    /// @notice 7 days of voting.
    uint32 public constant INITIAL_VOTING_PERIOD = 7 days;

    /// @notice 4% of the WRunes supply (at the proposal's snapshot) must vote For or Abstain for a result to count.
    uint256 public constant INITIAL_QUORUM_PERCENT = 4;

    /// @notice A constructor address had no contract code (an EOA or the zero address).
    error InvalidContractAddress(address account);

    /// @param _tokenStorage The deployed WrappedRunesVotes (WRunes) contract.
    /// @param _timelock The TimelockController that executes passed proposals.
    /// @param _initialProposalThreshold WRunes votes needed to create a proposal (0 = anyone).
    constructor(IVotes _tokenStorage, TimelockController _timelock, uint256 _initialProposalThreshold)
        Governor("BushidoGovernance V1.1")
        GovernorSettings(INITIAL_VOTING_DELAY, INITIAL_VOTING_PERIOD, _initialProposalThreshold)
        GovernorVotes(_checkedToken(_tokenStorage))
        GovernorVotesQuorumFraction(INITIAL_QUORUM_PERCENT)
        GovernorTimelockControl(_timelock)
    {
        if (address(_timelock).code.length == 0) revert InvalidContractAddress(address(_timelock));
    }

    /// @dev Checked before GovernorVotes runs, because GovernorVotes calls `clock()` on the token in its
    /// constructor: an EOA or zero address would otherwise fail there without our custom error.
    function _checkedToken(IVotes token) private view returns (IVotes) {
        if (address(token).code.length == 0) revert InvalidContractAddress(address(token));
        return token;
    }

    // --- Required overrides: standard OpenZeppelin v5 Governor wiring only, no custom logic ---

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
