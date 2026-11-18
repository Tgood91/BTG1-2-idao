// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IDAOBTG2.sol";

/// @title BushidoVirtueAccessControl
/// @notice The reusable access-control piece for anything that writes Bushido
/// Virtue Scores. Interfaces (like IDAOBTG2) can only describe what functions
/// exist — they can't hold rules about who's allowed to call them. This contract
/// is that missing piece: inherit it, and "only a trusted recorder can update
/// virtue scores" is baked in automatically, instead of every implementation
/// having to rebuild the same restriction from scratch.
abstract contract BushidoVirtueAccessControl is AccessControl {
    /// @notice Holders of this role are trusted to record trades and set virtue
    /// scores. This should be an off-chain scoring service, a multisig, or an
    /// oracle network — never a trader acting on their own account.
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    /// @notice Reverts with IDAOBTG2.UnauthorizedVirtueScoreUpdate if the caller
    /// doesn't hold RECORDER_ROLE, so every contract in the system fails the same
    /// recognizable way for the same reason.
    modifier onlyRecorder() {
        if (!hasRole(RECORDER_ROLE, msg.sender)) {
            revert IDAOBTG2.UnauthorizedVirtueScoreUpdate(msg.sender);
        }
        _;
    }

    /// @dev Grants both the admin role and an initial recorder role to `admin`.
    /// Call this from the inheriting contract's constructor.
    function _setupVirtueAccessControl(address admin) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECORDER_ROLE, admin);
    }
}