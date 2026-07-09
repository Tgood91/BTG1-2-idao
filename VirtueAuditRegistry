// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IDAOBTG2.sol";
import "./BushidoVirtueAccessControl.sol";

/// @title VirtueAuditRegistry
/// @notice Records every scored trade on-chain and rolls the trade-related virtues
/// into each trader's running Bushido Virtue Score. That score is what
/// MyGovernance reads to calculate a wallet's voting-power bonus — so this
/// contract is the missing link between "you traded well" and "you get more say."
/// @dev Deliberately does NOT inherit the full IDAOBTG2 / IDAOBTG1 interface tree.
/// This contract's only job is virtue scoring and trade history — it isn't a full
/// DAO (no permissions, deposits, metadata, etc.), so it only needs to expose
/// functions that match IDAOBTG2's virtue-score signatures. That's enough for
/// MyGovernance to treat its address as an IDAOBTG2 when it's deployed.
/// Access control is inherited from BushidoVirtueAccessControl rather than
/// rebuilt here, so every contract that writes virtue scores enforces the same
/// rule the same way.
contract VirtueAuditRegistry is BushidoVirtueAccessControl {
    /// @notice Each virtue is scored 0.00–10.00, stored on-chain as an integer
    /// scaled by 100 (so "9.2" is stored as 920). This cap enforces that range.
    uint32 public constant MAX_VIRTUE_SCORE = 1000;

    /// @notice A single recorded trade and the virtue breakdown it earned.
    struct Trade {
        address fromToken;
        address toToken;
        uint256 amountIn;
        uint256 amountOut;
        uint32 gi;      // Righteousness — execution fidelity of the swap route
        uint32 yu;      // Courage — position size / conviction
        uint32 jin;     // Benevolence — liquidity depth available
        uint32 rei;     // Respect — slippage adherence
        uint32 makoto;  // Honesty — token transparency (native vs. wrapped)
        uint256 timestamp;
        bytes32 txHash;
    }

    /// @notice Full, public trade history per trader — anyone can audit how a
    /// wallet's score was built up, trade by trade.
    mapping(address => Trade[]) public tradeHistory;

    /// @notice Cumulative Bushido Virtue Score per account. The five trade-related
    /// virtues (Gi, Yu, Jin, Rei, Makoto) accumulate automatically from recorded
    /// trades. The other three (Honour, Duty, Self-Control) aren't trade-related —
    /// they're left for a separate governance-participation mechanism to set via
    /// updateBushidoVirtueScore, and are untouched here.
    mapping(address => IDAOBTG2.BushidoVirtueScore) private _virtueScores;

    event TradeRecorded(
        address indexed trader,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 txHash,
        uint256 tradeIndex
    );

    event BushidoVirtueScoreUpdated(address indexed account, IDAOBTG2.BushidoVirtueScore newScores);

    constructor(address admin) {
        _setupVirtueAccessControl(admin);
    }

    /// @notice Records a completed trade with its virtue breakdown, then adds the
    /// five trade-related virtues onto the trader's running total.
    /// @dev Scores are expected pre-scaled x100 (e.g. 9.2 -> 920). Restricted to
    /// RECORDER_ROLE, which is expected to be the off-chain service computing
    /// these from real execution data — never the trader.
    function recordTrade(
        address trader,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 amountOut,
        uint32 gi,
        uint32 yu,
        uint32 jin,
        uint32 rei,
        uint32 makoto,
        bytes32 txHash
    ) external onlyRecorder {
        require(
            gi <= MAX_VIRTUE_SCORE &&
            yu <= MAX_VIRTUE_SCORE &&
            jin <= MAX_VIRTUE_SCORE &&
            rei <= MAX_VIRTUE_SCORE &&
            makoto <= MAX_VIRTUE_SCORE,
            "virtue score out of range"
        );

        tradeHistory[trader].push(Trade({
            fromToken: fromToken,
            toToken: toToken,
            amountIn: amountIn,
            amountOut: amountOut,
            gi: gi,
            yu: yu,
            jin: jin,
            rei: rei,
            makoto: makoto,
            timestamp: block.timestamp,
            txHash: txHash
        }));

        IDAOBTG2.BushidoVirtueScore storage score = _virtueScores[trader];
        score.righteousness += gi;
        score.courage += yu;
        score.benevolence += jin;
        score.respect += rei;
        score.honesty += makoto;

        emit BushidoVirtueScoreUpdated(trader, score);
        emit TradeRecorded(
            trader,
            fromToken,
            toToken,
            amountIn,
            amountOut,
            txHash,
            tradeHistory[trader].length - 1
        );
    }

    /// @notice Directly sets an account's full virtue score — used for the three
    /// non-trading virtues (Honour, Duty, Self-Control), e.g. based on governance
    /// participation. Also gated to RECORDER_ROLE.
    function updateBushidoVirtueScore(address account, IDAOBTG2.BushidoVirtueScore calldata scores)
        external
        onlyRecorder
    {
        _virtueScores[account] = scores;
        emit BushidoVirtueScoreUpdated(account, scores);
    }

    /// @notice Reads an account's current cumulative Bushido Virtue Score.
    /// Matches IDAOBTG2's signature so MyGovernance can call it directly.
    function getBushidoVirtueScore(address account) external view returns (IDAOBTG2.BushidoVirtueScore memory) {
        return _virtueScores[account];
    }

    /// @notice How many trades a wallet has had recorded.
    function getTradeCount(address trader) external view returns (uint256) {
        return tradeHistory[trader].length;
    }

    /// @notice Fetch one recorded trade by index for a given trader.
    function getTrade(address trader, uint256 index) external view returns (Trade memory) {
        return tradeHistory[trader][index];
    }
}