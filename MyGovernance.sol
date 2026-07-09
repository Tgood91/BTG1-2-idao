// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "./IDAOBTG2.sol";

/// @title MyGovernance
/// @notice OpenZeppelin Governor-based voting contract. Voting power is the voter's
/// token balance, boosted by their Bushido Virtue Score — the higher a wallet's
/// combined virtue score, the more weight its vote carries, up to a capped bonus.
contract MyGovernance is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, GovernorTimelockControl {
    /// @notice The contract holding each account's Bushido Virtue Score.
    IDAOBTG2 public immutable virtueRegistry;

    /// @notice Every 100 combined virtue points (summed across all 8 virtues) adds
    /// 1% extra voting weight on top of raw token votes.
    uint256 public constant VIRTUE_POINTS_PER_BONUS_BP = 100;

    /// @notice The virtue bonus is capped at +100% (a 2x multiplier), so no single
    /// account's virtue score can dominate a vote outright.
    uint256 public constant MAX_VIRTUE_BONUS_BP = 10_000; // 10,000 basis points = 100%

    constructor(IVotes _tokenStorage, TimelockController _timelock, IDAOBTG2 _virtueRegistry)
        Governor("MyGovernance")
        GovernorSettings(1 /* 1 block voting delay */, 5040 /* 1 week voting period */, 0 /* 0 proposal threshold */)
        GovernorVotes(_tokenStorage)
        GovernorTimelockControl(_timelock)
    {
        virtueRegistry = _virtueRegistry;
    }

    /// @dev Reads the base token-weighted vote count, then adds a bonus based on the
    /// voter's Bushido Virtue Score. Accounts with zero token votes get no bonus,
    /// since a virtue score alone shouldn't grant voting power.
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

        IDAOBTG2.BushidoVirtueScore memory scores = virtueRegistry.getBushidoVirtueScore(account);

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