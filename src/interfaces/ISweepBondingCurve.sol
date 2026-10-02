// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISweepBondingCurve
 * @author 0xDAVZER
 * @notice The launch market's external surface: what the factory wires, what traders call, what
 * the keeper watches, and what the factory takes at graduation.
 */
interface ISweepBondingCurve {
    function initialize(address token, address creatorFeeRecipient, address launcher) external;

    function buy(uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minEthOut, address recipient) external returns (uint256 ethOut);
    function quoteBuy(uint256 ethIn, address recipient) external view returns (uint256 tokensOut, uint256 snipeTaxBps);
    function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut);

    function sweepFees() external;
    function graduate() external;
    function completeGraduation() external returns (uint256 ethOut, uint256 tokenOut);

    function token() external view returns (address);
    function factory() external view returns (address);
    function creatorFeeRecipient() external view returns (address);
    function launcher() external view returns (address);
    function launchedAt() external view returns (uint256);
    function graduated() external view returns (bool);
    function readyToGraduate() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function realQuoteReserve() external view returns (uint256);
    function sellableTokens() external view returns (uint256);
    function reservedTokens() external view returns (uint256);
    function trackedQuote() external view returns (uint256);
    function trackedTokens() external view returns (uint256);
    function protocolFeeBalance() external view returns (uint256);
    function creatorFeeBalance() external view returns (uint256);
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
}

/**
 * @title ISweepCurveToken
 * @author 0xDAVZER
 * @notice The two things the curve asks of its token beyond ERC-20: which hook the launch was
 * welded to — the curve pays the protocol wherever that hook's recipient points — and the
 * graduation notice the strategy uses to reset its bid ramp.
 */
interface ISweepCurveToken {
    function hook() external view returns (address);
    function markGraduated() external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ISweepCurveHook
 * @author 0xDAVZER
 * @notice The one hook read the curve makes: the live protocol fee recipient, so the single
 * setter that governs protocol revenue on pools governs it on curves too.
 */
interface ISweepCurveHook {
    function protocolFeeRecipient() external view returns (address);
}
