// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "./IDAOBTG2.sol";

/// @title MyGovernance
/// @notice OpenZeppelin Governor-based voting contract. Voting power is the voter's
/// token balance, boosted by their Bushido Virtue Score — the higher a wallet's
/// combined virtue score, the more weight its vote carries, up to a capped bonus.
/// @dev Timings are in blocks of the governance token's clock and sized for Monad (about 0.31 s per block,
/// measured over 1M blocks in Nov 2026). Governance can retune them later with setVotingDelay / setVotingPeriod.
/// If the token uses a timestamp clock (ERC-6372 "mode=timestamp"), these numbers are seconds instead and must be
/// changed before deploying.
contract MyGovernance is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @notice The contract holding each account's Bushido Virtue Score.
    IDAOBTG2 public immutable virtueRegistry;

    /// @notice Every 100 combined virtue points (summed across all 8 virtues) adds
    /// 1% extra voting weight on top of raw token votes.
    uint256 public constant VIRTUE_POINTS_PER_BONUS_BP = 100;

    /// @notice The virtue bonus is capped at +100% (a 2x multiplier), so no single
    /// account's virtue score can dominate a vote outright.
    uint256 public constant MAX_VIRTUE_BONUS_BP = 10_000; // 10,000 basis points = 100%

    /// @notice About 1 hour of Monad blocks between a proposal and the start of voting.
    uint48 public constant INITIAL_VOTING_DELAY = 11_760;

    /// @notice About 7 days of Monad blocks of voting (604,800 s / ~0.306 s per block).
    uint32 public constant INITIAL_VOTING_PERIOD = 1_976_000;

    /// @notice 4% of the token supply (at the proposal's snapshot) must vote For or Abstain for a result to count.
    /// Note: votes include the virtue bonus, so quorum can be reached with less than 4% of the supply in tokens.
    uint256 public constant INITIAL_QUORUM_PERCENT = 4;

    error VirtueRegistryNotAContract(address registry);

    constructor(IVotes _tokenStorage, TimelockController _timelock, IDAOBTG2 _virtueRegistry)
        Governor("MyGovernance")
        GovernorSettings(INITIAL_VOTING_DELAY, INITIAL_VOTING_PERIOD, 0 /* anyone may propose */)
        GovernorVotes(_tokenStorage)
        GovernorVotesQuorumFraction(INITIAL_QUORUM_PERCENT)
        GovernorTimelockControl(_timelock)
    {
        // A registry with no code would make every vote revert (the score call cannot be caught), so refuse it here.
        if (address(_virtueRegistry).code.length == 0) revert VirtueRegistryNotAContract(address(_virtueRegistry));
        virtueRegistry = _virtueRegistry;
    }

    /// @dev Reads the base token-weighted vote count, then adds a bonus based on the
    /// voter's Bushido Virtue Score. Accounts with zero token votes get no bonus,
    /// since a virtue score alone shouldn't grant voting power.
    /// If the registry call fails, the voter simply gets no bonus: a broken or paused registry must never stop
    /// people voting with their tokens.
    /// Known limit: the registry keeps only current totals, so the bonus uses the score at the moment of voting,
    /// not at the proposal's snapshot. A score that changes during a vote changes the bonus of later votes. Fixing
    /// that needs the registry to keep score history (checkpoints).
    function _getVotes(address account, uint256 timepoint, bytes memory params)
        internal
        view
        override(Governor, GovernorVotes)
        returns (uint256)
    {
        uint256 baseVotes = super._getVotes(account, timepoint, params);

        if (baseVotes == 0) {
            return 0;
        }

        IDAOBTG2.BushidoVirtueScore memory scores;
        try virtueRegistry.getBushidoVirtueScore(account) returns (IDAOBTG2.BushidoVirtueScore memory s) {
            scores = s;
        } catch {
            return baseVotes;
        }

        uint256 totalVirtue = uint256(scores.righteousness)
            + scores.courage
            + scores.benevolence
            + scores.respect
            + scores.honesty
            + scores.honour
            + scores.duty
            + scores.selfControl;

        uint256 bonusBp = totalVirtue / VIRTUE_POINTS_PER_BONUS_BP;
        if (bonusBp > MAX_VIRTUE_BONUS_BP) {
            bonusBp = MAX_VIRTUE_BONUS_BP;
        }

        return baseVotes + (baseVotes * bonusBp) / 10_000;
    }

    // --- Required overrides below are standard OpenZeppelin Governor wiring ---
    // (needed whenever Settings + TimelockControl are both used together; no
    // custom logic lives here, they just resolve which parent contract wins.)

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