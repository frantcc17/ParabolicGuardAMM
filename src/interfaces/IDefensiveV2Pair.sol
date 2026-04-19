// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IDefensiveV2Pair {
    // Eventos para indexación y transparencia
    event Swap(address indexed sender, uint256 amountAIn, uint256 amountBIn, uint256 amountAOut, uint256 amountBOut, address indexed to);
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB);
    event ResistanceApplied(address indexed trader, uint256 gammaNumerator, uint256 treasuryShare, uint256 lpBenefit);
    event Sync(uint112 reserveA, uint112 reserveB);
    event LpShareUpdated(uint256 newLpShareBps);
    event ParametersUpdated(uint256 newKFactor, uint256 newThreshold);
    event TreasuryWithdrawn(address indexed taxRecipient, uint256 amount);

    // Funciones de vista
    function getReserves() external view returns (uint112 _reserveA, uint112 _reserveB, uint32 _blockTimestampLast);
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);
    
    // Funciones de estado
    function protocolSurplus() external view returns (uint256);
}
