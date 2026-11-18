// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.20;

import "./IDAOBTG1.sol";

/// @title IDAOBTG2
/// @notice The virtue layer: everything in IDAOBTG1, plus a Bushido Virtue Score per wallet, tracked across the
/// eight virtues. VirtueAuditRegistry implements the score functions; MyGovernance reads them for the vote bonus.
/// @dev Each virtue is a running total of x100-scaled scores (a 9.2 trade score adds 920), so totals are uint256:
/// they only grow as trades are recorded and must never overflow.
interface IDAOBTG2 is IDAOBTG1 {
    /// @notice A wallet's cumulative score across the eight virtues.
    struct BushidoVirtueScore {
        uint256 righteousness; // Gi: from trades (execution fidelity)
        uint256 courage; // Yu: from trades (conviction)
        uint256 benevolence; // Jin: from trades (liquidity depth)
        uint256 respect; // Rei: from trades (slippage adherence)
        uint256 honesty; // Makoto: from trades (token transparency)
        uint256 honour; // Meiyo: set separately (e.g. governance participation)
        uint256 duty; // Chugi: set separately
        uint256 selfControl; // Jisei: set separately
    }

    /// @notice Thrown when an account without the recorder role tries to write a virtue score.
    error UnauthorizedVirtueScoreUpdate(address caller);

    /// @notice Emitted whenever an account's virtue score changes.
    event BushidoVirtueScoreUpdated(address indexed account, BushidoVirtueScore newScores);

    /// @notice The account's current cumulative virtue score.
    function getBushidoVirtueScore(address account) external view returns (BushidoVirtueScore memory);

    /// @notice Replaces the account's full virtue score (recorder only in implementations).
    function updateBushidoVirtueScore(address account, BushidoVirtueScore calldata scores) external;
}
