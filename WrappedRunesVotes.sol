// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

/// @title WrappedRunesVotes (wRunes)
/// @notice The BTG governance token. Runes (a plain ERC-20 on Base) does not track votes, so holders deposit Runes
/// here 1:1 to get wRunes, which do. wRunes can be turned back into Runes at any time (withdrawTo).
/// To vote, a holder must delegate their wRunes (to themselves or someone else) with `delegate`.
/// @dev Uses a timestamp clock (ERC-6372 "mode=timestamp"), so MyGovernance's delay and voting period are seconds
/// and do not depend on block speed. Runes takes no fee on transfer (checked in its verified source on Basescan),
/// which a 1:1 wrapper requires.
contract WrappedRunesVotes is ERC20, ERC20Permit, ERC20Votes, ERC20Wrapper {
    /// @notice Runes on Base (chain 8453).
    address public constant RUNES = 0x68E63f682AB383A9132317349125fF7618C96e01;

    constructor()
        ERC20("Wrapped Runes Votes", "wRunes")
        ERC20Permit("Wrapped Runes Votes")
        ERC20Wrapper(IERC20(RUNES))
    {}

    /// @dev Votes are checkpointed by timestamp, not block number.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // --- Required overrides: OpenZeppelin wiring only, no custom logic ---

    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return super.decimals();
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
