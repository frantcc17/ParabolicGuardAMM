// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title DefensiveV2Pair
 * @notice AMM con resistencia parabólica, incentivos para LPs y compatibilidad con agregadores.
 */
contract DefensiveV2Pair is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
   using SafeCast for uint256;

    // --- ESTADO ---
    address public immutable tokenA;
    address public immutable tokenB;

    uint112 private reserveA;
    uint112 private reserveB;
    uint32  private blockTimestampLast;

    uint256 public priceUpdateBlock;
    uint256 public lastObservedPriceA;

    uint256 public priceImpactThresholdBps = 500; // 5%
    uint256 public kFactor = 1e18;
    uint256 public lpFeeShareBps = 3000; // 30% del excedente para LPs

    address public treasuryAddress;
    uint256 public protocolSurplus;
    uint256 public constant SURPLUS_LOCK_BLOCKS = 50;
    uint256 public lastSurplusWithdrawBlock;

    // --- EVENTOS ---
    event Swap(address indexed sender, uint256 amountAIn, uint256 amountBIn, uint256 amountAOut, uint256 amountBOut, address indexed to);
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB);
    event ResistanceApplied(address indexed trader, uint256 gammaNumerator, uint256 treasuryShare, uint256 lpBenefit);
    event Sync(uint112 reserveA, uint112 reserveB);
    event LpShareUpdated(uint256 newLpShareBps);
    event ParametersUpdated(uint256 newKFactor, uint256 newThreshold);
    event TreasuryWithdrawn(address indexed taxRecipient, uint256 amount);

    constructor(address _tokenA, address _tokenB, address _treasury) Ownable(msg.sender) {
        tokenA = _tokenA;
        tokenB = _tokenB;
        treasuryAddress = _treasury;
    }

    // --- VISTAS ---
    function getReserves() public view returns (uint112 _reserveA, uint112 _reserveB, uint32 _blockTimestampLast) {
        _reserveA = reserveA;
        _reserveB = reserveB;
        _blockTimestampLast = blockTimestampLast;
    }
    
    function getAmountOut(uint256 amountIn, address tokenIn) public view returns (uint256 amountOut) {
        bool isSellingA = (tokenIn == tokenA);
        (uint112 _rA, uint112 _rB,) = getReserves();
        
        uint256 rIn = isSellingA ? _rA : _rB;
        uint256 rOut = isSellingA ? _rB : _rA;

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * rOut;
        uint256 denominator = (rIn * 1000) + amountInWithFee;
        uint256 amountOutStd = numerator / denominator;

        if (!isSellingA) return amountOutStd;

        uint256 gamma = _computeGamma(rIn, rOut, amountIn);
        amountOut = (amountOutStd * 1e18) / gamma;
    }

    // --- LÓGICA CORE ---

    function swap(uint256 amountAIn, uint256 amountBIn, address to) external nonReentrant {
        require(amountAIn > 0 || amountBIn > 0, "INSUFFICIENT_INPUT");
        (uint112 _rA, uint112 _rB,) = getReserves();
        
        _updatePriceReference(_rA, _rB);
        
        uint256 amountOut;
        if (amountAIn > 0) {
            amountOut = getAmountOut(amountAIn, tokenA);
            uint256 amountOutStd = (amountAIn * 997 * _rB) / (uint256(_rA) * 1000 + amountAIn * 997);
            uint256 totalSurplus = amountOutStd - amountOut;

            IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountAIn);
            IERC20(tokenB).safeTransfer(to, amountOut);

            if (totalSurplus > 0) {
                uint256 lpBenefit = (totalSurplus * lpFeeShareBps) / 10000;
                uint256 treasuryShare = totalSurplus - lpBenefit;
                protocolSurplus += treasuryShare;
                emit ResistanceApplied(msg.sender, _computeGamma(_rA, _rB, amountAIn), treasuryShare, lpBenefit);
            }
            emit Swap(msg.sender, amountAIn, 0, 0, amountOut, to);
        } else {
            amountOut = getAmountOut(amountBIn, tokenB);
            IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBIn);
            IERC20(tokenA).safeTransfer(to, amountOut);
            emit Swap(msg.sender, 0, amountBIn, amountOut, 0, to);
        }

        _updateReserves();
    }

    function addLiquidity(uint256 amountA, uint256 amountB) external nonReentrant {
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
        _updateReserves();
        emit LiquidityAdded(msg.sender, amountA, amountB);
    }

   function _updateReserves() internal {
    // 1. Obtenemos los balances actuales del contrato 
    uint256 balA = IERC20(tokenA).balanceOf(address(this));
    uint256 balB = IERC20(tokenB).balanceOf(address(this));

    // 2. Calculamos el balance activo (descontando el surplus del protocolo) [cite: 75]
    uint256 activeB = balB > protocolSurplus ? balB - protocolSurplus : 0;

    // 3. ASIGNACIÓN: Actualizamos las variables de estado globales [cite: 76]
    // Usamos toUint112() para convertir de uint256 a uint112 de forma segura
    reserveA = balA.toUint112();
    reserveB = activeB.toUint112();

    blockTimestampLast = uint32(block.timestamp);
    emit Sync(reserveA, reserveB);
}
    function _computeGamma(uint256 rIn, uint256 rOut, uint256 amountIn) internal view returns (uint256) {
        uint256 priceBefore = (rOut * 1e18) / rIn;
        uint256 amountOutStdRaw = (amountIn * rOut) / (rIn + amountIn);
        uint256 priceAfter = ((rOut - amountOutStdRaw) * 1e18) / (rIn + amountIn);
        
        if (priceAfter >= priceBefore) return 1e18;

        uint256 deltaP_bps = ((priceBefore - priceAfter) * 10_000) / priceBefore;
        if (deltaP_bps <= priceImpactThresholdBps) return 1e18;

        uint256 ratio = ((deltaP_bps - priceImpactThresholdBps) * 1e18) / priceImpactThresholdBps;
        return 1e18 + (kFactor * ((ratio * ratio) / 1e18)) / 1e18;
    }

    function _updatePriceReference(uint112 _rA, uint112 _rB) internal {
        if (block.number > priceUpdateBlock && _rA > 0) {
            lastObservedPriceA = (uint256(_rB) * 1e18) / uint256(_rA);
            priceUpdateBlock = block.number;
        }
    }

    // --- GOBERNANZA ---

    function setParams(uint256 _k, uint256 _threshold) external onlyOwner {
        kFactor = _k;
        priceImpactThresholdBps = _threshold;
        emit ParametersUpdated(_k, _threshold);
    }

    function setLpShare(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "MAX_10000");
        lpFeeShareBps = _bps;
        emit LpShareUpdated(_bps);
    }

    function withdrawSurplus(uint256 amount) external onlyOwner nonReentrant {
        require(block.number >= lastSurplusWithdrawBlock + SURPLUS_LOCK_BLOCKS, "COOLDOWN");
        require(amount <= protocolSurplus, "EXCEEDS_SURPLUS");
        protocolSurplus -= amount;
        lastSurplusWithdrawBlock = block.number;
        IERC20(tokenB).safeTransfer(treasuryAddress, amount);
        emit TreasuryWithdrawn(treasuryAddress, amount);
    }
}
