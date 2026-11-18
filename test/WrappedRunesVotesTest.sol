// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

/// @title WrappedRunesVotesTest (TESTNET ONLY)
/// @notice Same as WrappedRunesVotes, except the wrapped token is passed in (MockRunes on Base Sepolia) instead of
/// being fixed to the real Runes address. Keep the two in step.
contract WrappedRunesVotesTest is ERC20, ERC20Permit, ERC20Votes, ERC20Wrapper {
    constructor(IERC20 underlying)
        ERC20("Test Wrapped Runes", "TWRunes")
        ERC20Permit("Test Wrapped Runes")
        ERC20Wrapper(underlying)
    {}

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

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
