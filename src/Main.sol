// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Main is ReentrancyGuard {
    uint256 private constant MIN_WIDTH = 10;
    uint256 private constant MAX_WIDTH = 5000;
    uint256 private constant PERCENTAGE_BASE = 100;
    uint256 private constant PRICE_PRECISION = 10000;
    uint256 private constant DEADLINE_MINUTES = 15 minutes;
    uint256 private constant MIN_DESIRED_AMOUNT = 1;
    uint8 private constant MAX_SLIPPAGE = 100;
    uint8 private constant MIN_SLIPPAGE = 0;

    event LiquidityProvided(
        address indexed user,
        address indexed pool,
        uint256 indexed tokenId,
        uint256 amount0Used,
        uint256 amount1Used,
        int24 lowerTick,
        int24 upperTick
    );

    event LiquidityWithdrawn(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount0,
        uint256 amount1
    );

    event LiquidityIncreased(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount0Added,
        uint256 amount1Added,
        uint256 liquidityAdded
    );

    event FeesCollected(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount0,
        uint256 amount1
    );

    event TokensReturned(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    event TokenReturnFailed(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    error TransferFailed(
        address token,
        address from,
        address to,
        uint256 amount
    );
    error InvalidTickRange();
    error AmountTooSmall(uint256 amount);
    error WidthTooSmall(uint24 width);
    error WidthTooLarge(uint24 width);
    error WidthCalculationError(uint256 calculated, uint24 expected);
    error ApprovalFailed(address token, address spender, uint256 amount);
    error NotTheOwner(address caller, address owner);
    error SlippageTooHigh(uint8 slippage);
    error SlippageTooLow(uint8 slippage);
    INonfungiblePositionManager public immutable positionManager;

    constructor(address _positionManager) {
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    struct PoolParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
    }

    /**
     * @notice Предоставляет ликвидность в пул Uniswap V3
     * @param pool Адрес пула Uniswap V3
     * @param amount0Desired Желаемое количество токена 0
     * @param amount1Desired Желаемое количество токена 1
     * @param width Ширина диапазона в процентах (умноженная на 100)
     * @param slippage Допустимый процент проскальзывания
     */
    function provideLiquidity(
        address pool,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint24 width,
        uint8 slippage
    )
        external
        nonReentrant
        returns (uint256 tokenId, uint256 amount0Used, uint256 amount1Used)
    {
        if (slippage > MAX_SLIPPAGE) revert SlippageTooHigh(slippage);
        if (slippage < MIN_SLIPPAGE) revert SlippageTooLow(slippage);
        if (amount0Desired < MIN_DESIRED_AMOUNT)
            revert AmountTooSmall(amount0Desired);
        if (amount1Desired < MIN_DESIRED_AMOUNT)
            revert AmountTooSmall(amount1Desired);
        if (width < MIN_WIDTH) revert WidthTooSmall(width);
        if (width > MAX_WIDTH) revert WidthTooLarge(width);

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(pool);
        address token0 = uniswapPool.token0();
        address token1 = uniswapPool.token1();
        uint24 fee = uniswapPool.fee();
        int24 tickSpacing = uniswapPool.tickSpacing();

        (, int24 currentTick, , , , , ) = uniswapPool.slot0();

        (int24 lowerTick, int24 upperTick) = calculateTickRange(
            currentTick,
            tickSpacing,
            width
        );

        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount0Desired
        );
        TransferHelper.safeTransferFrom(
            token1,
            msg.sender,
            address(this),
            amount1Desired
        );

        _safeApprove(token0, address(positionManager), amount0Desired);
        _safeApprove(token1, address(positionManager), amount1Desired);

        uint256 amount0Min = (amount0Desired * slippage) / PERCENTAGE_BASE;
        uint256 amount1Min = (amount1Desired * slippage) / PERCENTAGE_BASE;

        (tokenId, , amount0Used, amount1Used) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: lowerTick,
                tickUpper: upperTick,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: msg.sender,
                deadline: block.timestamp + DEADLINE_MINUTES
            })
        );

        _returnUnusedTokens(token0, msg.sender);
        _returnUnusedTokens(token1, msg.sender);

        emit LiquidityProvided(
            msg.sender,
            pool,
            tokenId,
            amount0Used,
            amount1Used,
            lowerTick,
            upperTick
        );
    }

    /**
     * @notice Снимает всю ликвидность из позиции
     * @param tokenId ID NFT-токена позиции
     */
    function withdrawLiquidity(
        uint256 tokenId
    ) external nonReentrant returns (uint256 collected0, uint256 collected1) {
        _checkOwnership(tokenId);

        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(
            tokenId
        );

        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + DEADLINE_MINUTES
            })
        );

        (collected0, collected1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        emit LiquidityWithdrawn(msg.sender, tokenId, collected0, collected1);
    }

    /**
     * @notice Собирает накопленные комиссии из позиции
     * @param tokenId ID NFT-токена позиции
     */
    function collectFees(uint256 tokenId) external nonReentrant {
        _checkOwnership(tokenId);

        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        emit FeesCollected(msg.sender, tokenId, amount0, amount1);
    }

    /**
     * @notice Увеличивает ликвидность в существующей позиции
     * @param tokenId ID NFT-токена позиции
     * @param amount0Desired Желаемое количество токена 0
     * @param amount1Desired Желаемое количество токена 1
     * @param slippage Допустимый процент проскальзывания
     */
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint8 slippage
    )
        external
        nonReentrant
        returns (
            uint256 addedLiquidity,
            uint256 amount0Used,
            uint256 amount1Used
        )
    {
        if (amount0Desired < MIN_DESIRED_AMOUNT)
            revert AmountTooSmall(amount0Desired);
        if (amount1Desired < MIN_DESIRED_AMOUNT)
            revert AmountTooSmall(amount1Desired);
        if (slippage > MAX_SLIPPAGE) revert SlippageTooHigh(slippage);
        if (slippage < MIN_SLIPPAGE) revert SlippageTooLow(slippage);

        _checkOwnership(tokenId);

        (, , address token0, address token1, , , , , , , , ) = positionManager
            .positions(tokenId);

        TransferHelper.safeTransferFrom(
            token0,
            msg.sender,
            address(this),
            amount0Desired
        );
        TransferHelper.safeTransferFrom(
            token1,
            msg.sender,
            address(this),
            amount1Desired
        );

        _safeApprove(token0, address(positionManager), amount0Desired);
        _safeApprove(token1, address(positionManager), amount1Desired);

        uint256 amount0Min = (amount0Desired * (PERCENTAGE_BASE - slippage)) /
            PERCENTAGE_BASE;
        uint256 amount1Min = (amount1Desired * (PERCENTAGE_BASE - slippage)) /
            PERCENTAGE_BASE;
        (addedLiquidity, amount0Used, amount1Used) = positionManager
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp + DEADLINE_MINUTES
                })
            );

        _returnUnusedTokens(token0, msg.sender);
        _returnUnusedTokens(token1, msg.sender);

        emit LiquidityIncreased(
            msg.sender,
            tokenId,
            amount0Used,
            amount1Used,
            addedLiquidity
        );
    }

    /**
     * @notice Рассчитывает ликвидность для заданных параметров
     */
    function calculateLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        int24 lowerTick,
        int24 upperTick
    ) external pure returns (uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        );
    }

    /**
     * @notice Рассчитывает диапазон тиков для заданной ширины
     * @param currentTick Текущий тик пула
     * @param tickSpacing Интервал между тиками в пуле
     * @param width Ширина диапазона в процентах (умноженная на 100)
     */
    function calculateTickRange(
        int24 currentTick,
        int24 tickSpacing,
        uint24 width
    ) internal pure returns (int24 lowerTick, int24 upperTick) {
        uint256 currentPrice = tickToPrice(currentTick);

        uint256 priceDelta = FullMath.mulDiv(
            currentPrice,
            width,
            PRICE_PRECISION
        );

        uint256 lowerPrice = currentPrice > priceDelta
            ? currentPrice - priceDelta
            : 1;
        uint256 upperPrice = currentPrice + priceDelta;

        int24 rawLowerTick = priceToTick(lowerPrice);
        int24 rawUpperTick = priceToTick(upperPrice);

        lowerTick = (rawLowerTick / tickSpacing) * tickSpacing;
        upperTick =
            ((rawUpperTick + tickSpacing - 1) / tickSpacing) *
            tickSpacing;

        if (lowerTick >= currentTick) {
            lowerTick -= tickSpacing;
        }
        if (upperTick <= currentTick) {
            upperTick += tickSpacing;
        }

        if (upperTick > TickMath.MAX_TICK) {
            upperTick = TickMath.MAX_TICK;
        }
        if (lowerTick < TickMath.MIN_TICK) {
            lowerTick = TickMath.MIN_TICK;
        }

        if (lowerTick >= upperTick) {
            revert InvalidTickRange();
        }
    }

    /**
     * @notice Преобразует цену в тик
     * @param price Цена в обычном формате
     */
    function priceToTick(uint256 price) internal pure returns (int24) {
        if (price == 0) return TickMath.MIN_TICK;

        uint256 sqrtPrice = Math.sqrt(price);

        uint256 sqrtPriceX96 = FullMath.mulDiv(sqrtPrice, 1 << 96, 1);

        if (sqrtPriceX96 > type(uint160).max) {
            return TickMath.getTickAtSqrtRatio(type(uint160).max);
        }

        if (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO) {
            return TickMath.MIN_TICK;
        }

        if (sqrtPriceX96 > TickMath.MAX_SQRT_RATIO) {
            return TickMath.MAX_TICK;
        }

        return TickMath.getTickAtSqrtRatio(uint160(sqrtPriceX96));
    }

    /**
     * @notice Преобразует тик в цену
     * @param tick Тик
     */
    function tickToPrice(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        return priceFromSqrtPriceX96(sqrtPriceX96);
    }

    /**
     * @notice Преобразует sqrtPriceX96 в обычную цену
     * @param sqrtPriceX96 Квадратный корень из цены в формате Q96
     */
    function priceFromSqrtPriceX96(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                1,
                1 << 192
            );
    }

    /**
     * @notice Проверяет владение NFT-токеном позиции
     * @param tokenId ID NFT-токена позиции
     */
    function _checkOwnership(uint256 tokenId) internal view {
        address owner = positionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert NotTheOwner(msg.sender, owner);
        }
    }

    /**
     * @notice Безопасно одобряет токены для использования
     * @param token Адрес токена
     * @param spender Получатель разрешения
     * @param amount Количество токенов
     */
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).approve(spender, 0);

        bool success = IERC20(token).approve(spender, amount);
        if (!success) {
            revert ApprovalFailed(token, spender, amount);
        }
    }

    /**
     * @notice Возвращает неиспользованные токены пользователю
     * @param token Адрес токена
     * @param recipient Получатель
     */
    function _returnUnusedTokens(address token, address recipient) internal {
        uint256 remainingBalance = IERC20(token).balanceOf(address(this));

        if (remainingBalance > 0) {
            bool success = IERC20(token).transfer(recipient, remainingBalance);
            if (success) {
                emit TokensReturned(token, recipient, remainingBalance);
            } else {
                emit TokenReturnFailed(token, recipient, remainingBalance);
            }
        }
    }
}
