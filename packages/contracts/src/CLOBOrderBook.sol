// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

/// @title CLOBOrderBook
/// @notice Central Limit Order Book for prediction market outcome tokens.
///         - BUY orders: trader commits USDC, receives outcome tokens when matched.
///         - SELL orders: trader commits outcome tokens, receives USDC when matched.
///         - Price: USDC per outcome token, scaled 1e6. Range [1, 999999] = [$0.000001, $0.999999].
///         - Matching: price-time priority. Best bid (highest price) vs best ask (lowest price).
///         - Fee: maker/taker fee in bps deducted from trade proceeds.
contract CLOBOrderBook is Ownable, Pausable, ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Side {
        BUY,
        SELL
    }

    enum OrderStatus {
        Open,
        Filled,
        PartiallyFilled,
        Cancelled
    }

    enum OrderType {
        Limit,
        Market
    }

    struct Order {
        bytes32 orderId;
        address trader;
        Side side;
        OrderType orderType;
        uint256 outcomeIndex; // 0=YES, 1=NO
        uint256 price; // USDC per outcome token (scaled 1e6)
        uint256 originalAmount; // outcome tokens
        uint256 remainingAmount; // unfilled outcome tokens
        uint256 usdcCommitted; // USDC locked (for BUY orders)
        OrderStatus status;
        uint256 createdAt;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event OrderPlaced(
        bytes32 indexed orderId,
        address indexed trader,
        Side side,
        uint256 outcomeIndex,
        uint256 price,
        uint256 amount
    );

    event OrderFilled(
        bytes32 indexed orderId,
        bytes32 indexed matchedOrderId,
        address indexed trader,
        uint256 filledAmount,
        uint256 price
    );

    event OrderPartiallyFilled(bytes32 indexed orderId, uint256 filledAmount, uint256 remainingAmount);

    event OrderCancelled(bytes32 indexed orderId, address indexed trader, uint256 refundAmount);

    event TradeExecuted(
        bytes32 indexed buyOrderId,
        bytes32 indexed sellOrderId,
        uint256 outcomeIndex,
        uint256 price,
        uint256 amount
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidPrice();
    error InvalidAmount();
    error InvalidOutcomeIndex();
    error OrderNotFound();
    error NotOrderOwner();
    error OrderNotCancellable();
    error InsufficientBalance();
    error SlippageExceeded();
    error ZeroAddress();
    error InvalidFee();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant PRICE_DENOMINATOR = 1e6; // price is in units of 1e-6 USDC per token
    uint256 public constant MAX_PRICE = 999_999; // < 1.0 USDC
    uint256 public constant MIN_PRICE = 1; // > 0.0 USDC
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant OUTCOME_COUNT = 2; // binary market

    // ─── State ────────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IConditionalTokens public immutable conditionalTokens;
    bytes32 public immutable conditionId;

    uint256 public makerFeeBps; // fee for maker (order that was already in book)
    uint256 public takerFeeBps; // fee for taker (order that crosses the spread)
    address public feeRecipient;

    uint256 public orderCount;

    mapping(bytes32 => Order) public orders;

    /// @dev Per-outcome buy order IDs sorted descending by price (best bid first)
    mapping(uint256 => bytes32[]) internal buyOrderIds;

    /// @dev Per-outcome sell order IDs sorted ascending by price (best ask first)
    mapping(uint256 => bytes32[]) internal sellOrderIds;

    mapping(address => bytes32[]) public userOrders;

    /// @dev Index sets for conditional token positions [1, 2]
    uint256[] internal _indexSets;

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        IERC20 _usdc,
        IConditionalTokens _conditionalTokens,
        bytes32 _conditionId,
        uint256 _makerFeeBps,
        uint256 _takerFeeBps,
        address _feeRecipient,
        address _owner
    ) Ownable(_owner) {
        if (address(_usdc) == address(0)) revert ZeroAddress();
        if (address(_conditionalTokens) == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_makerFeeBps > 500 || _takerFeeBps > 500) revert InvalidFee();

        usdc = _usdc;
        conditionalTokens = _conditionalTokens;
        conditionId = _conditionId;
        makerFeeBps = _makerFeeBps;
        takerFeeBps = _takerFeeBps;
        feeRecipient = _feeRecipient;

        _indexSets = new uint256[](2);
        _indexSets[0] = 1; // YES
        _indexSets[1] = 2; // NO
    }

    // ─── Order Placement ──────────────────────────────────────────────────────

    /// @notice Place a limit order.
    ///         BUY: locks USDC = price * amount / PRICE_DENOMINATOR.
    ///         SELL: locks outcome tokens = amount.
    /// @param side BUY or SELL
    /// @param outcomeIndex 0=YES, 1=NO
    /// @param price USDC per outcome token * 1e6 (range 1 to 999999)
    /// @param amount Number of outcome tokens (18 decimals)
    /// @return orderId The new order ID
    function placeLimitOrder(Side side, uint256 outcomeIndex, uint256 price, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 orderId)
    {
        if (price < MIN_PRICE || price > MAX_PRICE) revert InvalidPrice();
        if (amount == 0) revert InvalidAmount();
        if (outcomeIndex >= OUTCOME_COUNT) revert InvalidOutcomeIndex();

        orderId = _generateOrderId(msg.sender);

        uint256 usdcNeeded = 0;
        if (side == Side.BUY) {
            // Lock USDC inclusive of taker fee so the contract can settle the full fill.
            // baseUsdc = price * amount / PRICE_DENOMINATOR (the raw cost)
            // committed  = baseUsdc * (BPS_DENOMINATOR + takerFeeBps) / BPS_DENOMINATOR
            uint256 baseUsdc = (price * amount) / PRICE_DENOMINATOR;
            if (baseUsdc == 0) revert InvalidAmount();
            usdcNeeded = (baseUsdc * (BPS_DENOMINATOR + takerFeeBps)) / BPS_DENOMINATOR;
            usdc.safeTransferFrom(msg.sender, address(this), usdcNeeded);
        } else {
            // Lock outcome tokens
            bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[outcomeIndex]);
            uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
            uint256 balance = conditionalTokens.balanceOf(msg.sender, positionId);
            if (balance < amount) revert InsufficientBalance();
            conditionalTokens.safeTransferFrom(msg.sender, address(this), positionId, amount, "");
        }

        orders[orderId] = Order({
            orderId: orderId,
            trader: msg.sender,
            side: side,
            orderType: OrderType.Limit,
            outcomeIndex: outcomeIndex,
            price: price,
            originalAmount: amount,
            remainingAmount: amount,
            usdcCommitted: usdcNeeded,
            status: OrderStatus.Open,
            createdAt: block.timestamp
        });

        userOrders[msg.sender].push(orderId);

        // Insert into sorted order book
        if (side == Side.BUY) {
            _insertBuyOrder(outcomeIndex, orderId, price);
        } else {
            _insertSellOrder(outcomeIndex, orderId, price);
        }

        emit OrderPlaced(orderId, msg.sender, side, outcomeIndex, price, amount);

        // Attempt to match
        _matchOrders(outcomeIndex);
    }

    /// @notice Place a market order — fills at best available prices.
    /// @param side BUY or SELL
    /// @param outcomeIndex 0=YES, 1=NO
    /// @param amount Number of outcome tokens to buy/sell
    /// @param maxSlippage Worst acceptable price * 1e6 (0 = no limit)
    /// @return filled Total outcome tokens filled
    function placeMarketOrder(Side side, uint256 outcomeIndex, uint256 amount, uint256 maxSlippage)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 filled)
    {
        if (amount == 0) revert InvalidAmount();
        if (outcomeIndex >= OUTCOME_COUNT) revert InvalidOutcomeIndex();

        if (side == Side.BUY) {
            filled = _marketBuy(outcomeIndex, amount, maxSlippage);
        } else {
            filled = _marketSell(outcomeIndex, amount, maxSlippage);
        }
    }

    /// @dev Internal market buy: sweep ask book up to maxPrice, lock USDC upfront (fee-inclusive), refund remainder
    function _marketBuy(uint256 outcomeIndex, uint256 amount, uint256 maxSlippage)
        internal
        returns (uint256 filled)
    {
        uint256 maxPrice = maxSlippage == 0 ? MAX_PRICE : maxSlippage;
        // Lock max USDC inclusive of taker fee
        uint256 baseMaxUsdc = (maxPrice * amount) / PRICE_DENOMINATOR;
        if (baseMaxUsdc == 0) revert InvalidAmount();
        uint256 maxUsdcNeeded = (baseMaxUsdc * (BPS_DENOMINATOR + takerFeeBps)) / BPS_DENOMINATOR;
        usdc.safeTransferFrom(msg.sender, address(this), maxUsdcNeeded);

        uint256 remainingAmount = amount;
        uint256 usdcSpentTotal = 0; // includes taker fee

        bytes32[] storage askIds = sellOrderIds[outcomeIndex];
        uint256 i = 0;
        while (i < askIds.length && remainingAmount > 0) {
            Order storage ask = orders[askIds[i]];

            if (ask.status != OrderStatus.Open && ask.status != OrderStatus.PartiallyFilled) {
                i++;
                continue;
            }

            if (ask.price > maxPrice) break;

            uint256 fillAmount = remainingAmount < ask.remainingAmount ? remainingAmount : ask.remainingAmount;
            uint256 fillUsdc = (ask.price * fillAmount) / PRICE_DENOMINATOR;
            uint256 fillTakerFee = (fillUsdc * takerFeeBps) / BPS_DENOMINATOR;
            usdcSpentTotal += fillUsdc + fillTakerFee;
            address askTrader = ask.trader;
            uint256 askPrice = ask.price;

            _executeTrade(bytes32(0), askIds[i], outcomeIndex, askPrice, fillAmount, msg.sender, askTrader, false);

            remainingAmount -= fillAmount;
            filled += fillAmount;

            if (ask.remainingAmount == 0) {
                _removeFromSellBook(outcomeIndex, i);
            } else {
                i++;
            }
        }

        uint256 usdcRefund = maxUsdcNeeded - usdcSpentTotal;
        if (usdcRefund > 0) {
            usdc.safeTransfer(msg.sender, usdcRefund);
        }
    }

    /// @dev Internal market sell: lock outcome tokens upfront, sweep bid book down to minPrice, refund remainder
    function _marketSell(uint256 outcomeIndex, uint256 amount, uint256 maxSlippage)
        internal
        returns (uint256 filled)
    {
        uint256 minPrice = maxSlippage == 0 ? MIN_PRICE : maxSlippage;

        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[outcomeIndex]);
        uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
        if (conditionalTokens.balanceOf(msg.sender, positionId) < amount) revert InsufficientBalance();
        conditionalTokens.safeTransferFrom(msg.sender, address(this), positionId, amount, "");

        uint256 remainingAmount = amount;

        bytes32[] storage bidIds = buyOrderIds[outcomeIndex];
        uint256 i = 0;
        while (i < bidIds.length && remainingAmount > 0) {
            Order storage bid = orders[bidIds[i]];

            if (bid.status != OrderStatus.Open && bid.status != OrderStatus.PartiallyFilled) {
                i++;
                continue;
            }

            if (bid.price < minPrice) break;

            uint256 fillAmount = remainingAmount < bid.remainingAmount ? remainingAmount : bid.remainingAmount;
            address bidTrader = bid.trader;
            uint256 bidPrice = bid.price;

            _executeTrade(bidIds[i], bytes32(0), outcomeIndex, bidPrice, fillAmount, bidTrader, msg.sender, false);

            remainingAmount -= fillAmount;
            filled += fillAmount;

            if (bid.remainingAmount == 0) {
                _removeFromBuyBook(outcomeIndex, i);
            } else {
                i++;
            }
        }

        if (remainingAmount > 0) {
            conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, remainingAmount, "");
        }
    }

    /// @notice Cancel an open or partially-filled order. Refunds locked assets.
    /// @param orderId The order to cancel
    function cancelOrder(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.trader == address(0)) revert OrderNotFound();
        if (order.trader != msg.sender) revert NotOrderOwner();
        if (order.status != OrderStatus.Open && order.status != OrderStatus.PartiallyFilled) {
            revert OrderNotCancellable();
        }

        order.status = OrderStatus.Cancelled;
        uint256 refund = 0;

        if (order.side == Side.BUY) {
            // Refund remaining committed USDC (fee-inclusive, proportional to remaining amount)
            uint256 usdcForRemaining = (order.usdcCommitted * order.remainingAmount) / order.originalAmount;
            if (usdcForRemaining > 0) {
                usdc.safeTransfer(msg.sender, usdcForRemaining);
                refund = usdcForRemaining;
            }
            _removeOrderFromBuyBook(order.outcomeIndex, orderId);
        } else {
            // Refund remaining locked outcome tokens
            if (order.remainingAmount > 0) {
                bytes32 collectionId =
                    conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[order.outcomeIndex]);
                uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
                conditionalTokens.safeTransferFrom(address(this), msg.sender, positionId, order.remainingAmount, "");
                refund = order.remainingAmount;
            }
            _removeOrderFromSellBook(order.outcomeIndex, orderId);
        }

        emit OrderCancelled(orderId, msg.sender, refund);
    }

    /// @notice Cancel all open orders for an outcome (admin function, e.g. on resolution).
    /// @param outcomeIndex The outcome index to cancel orders for
    function adminCancelAll(uint256 outcomeIndex) external onlyOwner nonReentrant {
        if (outcomeIndex >= OUTCOME_COUNT) revert InvalidOutcomeIndex();

        _cancelAllSide(outcomeIndex, Side.BUY);
        _cancelAllSide(outcomeIndex, Side.SELL);
    }

    // ─── Matching Engine ──────────────────────────────────────────────────────

    /// @notice Match existing orders in the book. Called after every new order placement.
    /// @param outcomeIndex Outcome to match orders for
    function _matchOrders(uint256 outcomeIndex) internal {
        bytes32[] storage bids = buyOrderIds[outcomeIndex];
        bytes32[] storage asks = sellOrderIds[outcomeIndex];

        while (bids.length > 0 && asks.length > 0) {
            bytes32 bidId = bids[0];
            bytes32 askId = asks[0];

            Order storage bid = orders[bidId];
            Order storage ask = orders[askId];

            // Skip dead orders
            while (bids.length > 0 && (bid.status == OrderStatus.Filled || bid.status == OrderStatus.Cancelled)) {
                _removeFromBuyBook(outcomeIndex, 0);
                if (bids.length == 0) return;
                bidId = bids[0];
                bid = orders[bidId];
            }
            while (asks.length > 0 && (ask.status == OrderStatus.Filled || ask.status == OrderStatus.Cancelled)) {
                _removeFromSellBook(outcomeIndex, 0);
                if (asks.length == 0) return;
                askId = asks[0];
                ask = orders[askId];
            }

            if (bids.length == 0 || asks.length == 0) return;

            // Price check: bid price >= ask price (spread crossed)
            if (bid.price < ask.price) return; // no match

            // Determine fill amount and execution price (maker price = ask price for taker buy)
            uint256 fillAmount = bid.remainingAmount < ask.remainingAmount ? bid.remainingAmount : ask.remainingAmount;
            uint256 execPrice = ask.price; // maker gets ask price (FIFO: ask was placed first or equal)

            _executeTrade(bidId, askId, outcomeIndex, execPrice, fillAmount, bid.trader, ask.trader, true);

            if (bid.remainingAmount == 0) {
                _removeFromBuyBook(outcomeIndex, 0);
            }
            if (ask.remainingAmount == 0) {
                _removeFromSellBook(outcomeIndex, 0);
            }
        }
    }

    /// @dev Execute a single trade between buyer and seller.
    function _executeTrade(
        bytes32 buyOrderId,
        bytes32 sellOrderId,
        uint256 outcomeIndex,
        uint256 price,
        uint256 fillAmount,
        address buyer,
        address seller,
        bool fromBook
    ) internal {
        // USDC cost for this fill
        uint256 usdcAmount = (price * fillAmount) / PRICE_DENOMINATOR;

        // Compute fees
        uint256 makerFee = (usdcAmount * makerFeeBps) / BPS_DENOMINATOR;
        uint256 takerFee = (usdcAmount * takerFeeBps) / BPS_DENOMINATOR;
        uint256 totalFee = makerFee + takerFee;

        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[outcomeIndex]);
        uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));

        if (fromBook) {
            // Both orders are in the book
            Order storage buyOrder = orders[buyOrderId];
            Order storage sellOrder = orders[sellOrderId];

            // Update order states
            buyOrder.remainingAmount -= fillAmount;
            sellOrder.remainingAmount -= fillAmount;

            if (buyOrder.remainingAmount == 0) {
                buyOrder.status = OrderStatus.Filled;
            } else {
                buyOrder.status = OrderStatus.PartiallyFilled;
            }

            if (sellOrder.remainingAmount == 0) {
                sellOrder.status = OrderStatus.Filled;
            } else {
                sellOrder.status = OrderStatus.PartiallyFilled;
            }

            // Transfer outcome tokens to buyer
            conditionalTokens.safeTransferFrom(address(this), buyer, positionId, fillAmount, "");

            // Transfer USDC to seller (minus fees)
            uint256 sellerReceives = usdcAmount - makerFee;
            if (sellerReceives > 0) {
                usdc.safeTransfer(seller, sellerReceives);
            }

            // Refund excess USDC to buyer (committed fee-inclusive at order price, executed at ask price).
            // Committed amount for this fill is proportional to fill vs original.
            uint256 buyerCommittedUsdc = (buyOrder.usdcCommitted * fillAmount) / buyOrder.originalAmount;
            if (buyerCommittedUsdc > usdcAmount + takerFee) {
                usdc.safeTransfer(buyer, buyerCommittedUsdc - usdcAmount - takerFee);
            }

            if (totalFee > 0) {
                usdc.safeTransfer(feeRecipient, totalFee);
            }

            if (buyOrderId != bytes32(0)) {
                emit OrderFilled(buyOrderId, sellOrderId, buyer, fillAmount, price);
            }
            if (sellOrderId != bytes32(0)) {
                emit OrderFilled(sellOrderId, buyOrderId, seller, fillAmount, price);
            }
        } else {
            // Market order: one side is a market order (orderId = bytes32(0))
            if (buyOrderId == bytes32(0)) {
                // buyer is market order, seller is book order
                Order storage sellOrder = orders[sellOrderId];
                sellOrder.remainingAmount -= fillAmount;
                if (sellOrder.remainingAmount == 0) {
                    sellOrder.status = OrderStatus.Filled;
                } else {
                    sellOrder.status = OrderStatus.PartiallyFilled;
                }

                // Transfer outcome tokens to buyer
                conditionalTokens.safeTransferFrom(address(this), buyer, positionId, fillAmount, "");

                // Transfer USDC to seller minus maker fee
                uint256 sellerReceives = usdcAmount - makerFee;
                if (sellerReceives > 0) {
                    usdc.safeTransfer(seller, sellerReceives);
                }

                if (totalFee > 0) {
                    usdc.safeTransfer(feeRecipient, totalFee);
                }
            } else {
                // seller is market order, buyer is book order (buyer = maker, seller = taker)
                Order storage buyOrder = orders[buyOrderId];
                buyOrder.remainingAmount -= fillAmount;
                if (buyOrder.remainingAmount == 0) {
                    buyOrder.status = OrderStatus.Filled;
                } else {
                    buyOrder.status = OrderStatus.PartiallyFilled;
                }

                // Transfer outcome tokens to book buyer
                conditionalTokens.safeTransferFrom(address(this), buyer, positionId, fillAmount, "");

                // Transfer USDC to market seller minus taker fee (seller is taker)
                uint256 sellerReceives = usdcAmount - takerFee;
                if (sellerReceives > 0) {
                    usdc.safeTransfer(seller, sellerReceives);
                }

                if (totalFee > 0) {
                    usdc.safeTransfer(feeRecipient, totalFee);
                }

                // Refund excess USDC to book buyer (committed fee-inclusive at takerFee rate, used at makerFee rate)
                uint256 buyerCommittedUsdc = (buyOrder.usdcCommitted * fillAmount) / buyOrder.originalAmount;
                uint256 totalDeducted = usdcAmount + makerFee;
                if (buyerCommittedUsdc > totalDeducted) {
                    usdc.safeTransfer(buyer, buyerCommittedUsdc - totalDeducted);
                }
            }
        }

        emit TradeExecuted(buyOrderId, sellOrderId, outcomeIndex, price, fillAmount);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Get a full Order struct by ID (convenience over the auto-generated tuple getter)
    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @notice Get best bid price and total available amount at that price
    function getBestBid(uint256 outcomeIndex) external view returns (uint256 price, uint256 amount) {
        bytes32[] storage bids = buyOrderIds[outcomeIndex];
        for (uint256 i = 0; i < bids.length; i++) {
            Order storage order = orders[bids[i]];
            if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                price = order.price;
                amount = order.remainingAmount;
                // Sum same-price orders
                for (uint256 j = i + 1; j < bids.length; j++) {
                    Order storage o2 = orders[bids[j]];
                    if (o2.price == price && (o2.status == OrderStatus.Open || o2.status == OrderStatus.PartiallyFilled)) {
                        amount += o2.remainingAmount;
                    } else {
                        break;
                    }
                }
                return (price, amount);
            }
        }
        return (0, 0);
    }

    /// @notice Get best ask price and total available amount at that price
    function getBestAsk(uint256 outcomeIndex) external view returns (uint256 price, uint256 amount) {
        bytes32[] storage asks = sellOrderIds[outcomeIndex];
        for (uint256 i = 0; i < asks.length; i++) {
            Order storage order = orders[asks[i]];
            if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                price = order.price;
                amount = order.remainingAmount;
                // Sum same-price orders
                for (uint256 j = i + 1; j < asks.length; j++) {
                    Order storage o2 = orders[asks[j]];
                    if (o2.price == price && (o2.status == OrderStatus.Open || o2.status == OrderStatus.PartiallyFilled)) {
                        amount += o2.remainingAmount;
                    } else {
                        break;
                    }
                }
                return (price, amount);
            }
        }
        return (0, 0);
    }

    /// @notice Get order book depth up to `depth` levels
    /// @param outcomeIndex Outcome index
    /// @param depth Number of price levels to return
    function getOrderBook(uint256 outcomeIndex, uint256 depth)
        external
        view
        returns (
            uint256[] memory bidPrices,
            uint256[] memory bidAmounts,
            uint256[] memory askPrices,
            uint256[] memory askAmounts
        )
    {
        bidPrices = new uint256[](depth);
        bidAmounts = new uint256[](depth);
        askPrices = new uint256[](depth);
        askAmounts = new uint256[](depth);

        // Fill bids
        uint256 levelCount = 0;
        uint256 currentPrice = 0;
        bytes32[] storage bids = buyOrderIds[outcomeIndex];
        for (uint256 i = 0; i < bids.length && levelCount < depth; i++) {
            Order storage order = orders[bids[i]];
            if (order.status != OrderStatus.Open && order.status != OrderStatus.PartiallyFilled) continue;
            if (order.price != currentPrice) {
                if (currentPrice != 0) levelCount++;
                if (levelCount >= depth) break;
                currentPrice = order.price;
                bidPrices[levelCount] = currentPrice;
            }
            bidAmounts[levelCount] += order.remainingAmount;
        }

        // Fill asks
        levelCount = 0;
        currentPrice = 0;
        bytes32[] storage asks = sellOrderIds[outcomeIndex];
        for (uint256 i = 0; i < asks.length && levelCount < depth; i++) {
            Order storage order = orders[asks[i]];
            if (order.status != OrderStatus.Open && order.status != OrderStatus.PartiallyFilled) continue;
            if (order.price != currentPrice) {
                if (currentPrice != 0) levelCount++;
                if (levelCount >= depth) break;
                currentPrice = order.price;
                askPrices[levelCount] = currentPrice;
            }
            askAmounts[levelCount] += order.remainingAmount;
        }
    }

    /// @notice Get all order IDs for a user
    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return userOrders[user];
    }

    // ─── ERC-1155 Receiver ────────────────────────────────────────────────────

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    function _generateOrderId(address trader) internal returns (bytes32) {
        return keccak256(abi.encode(trader, ++orderCount, block.timestamp, block.prevrandao));
    }

    /// @dev Insert buy order in descending price order (best bid first)
    function _insertBuyOrder(uint256 outcomeIndex, bytes32 orderId, uint256 price) internal {
        bytes32[] storage bids = buyOrderIds[outcomeIndex];
        bids.push(orderId);

        // Bubble up to maintain descending order
        uint256 i = bids.length - 1;
        while (i > 0) {
            Order storage prev = orders[bids[i - 1]];
            if (prev.price >= price) break;
            bytes32 tmp = bids[i - 1];
            bids[i - 1] = bids[i];
            bids[i] = tmp;
            i--;
        }
    }

    /// @dev Insert sell order in ascending price order (best ask first)
    function _insertSellOrder(uint256 outcomeIndex, bytes32 orderId, uint256 price) internal {
        bytes32[] storage asks = sellOrderIds[outcomeIndex];
        asks.push(orderId);

        // Bubble up to maintain ascending order
        uint256 i = asks.length - 1;
        while (i > 0) {
            Order storage prev = orders[asks[i - 1]];
            if (prev.price <= price) break;
            bytes32 tmp = asks[i - 1];
            asks[i - 1] = asks[i];
            asks[i] = tmp;
            i--;
        }
    }

    /// @dev Remove buy order from book by index (shift left)
    function _removeFromBuyBook(uint256 outcomeIndex, uint256 index) internal {
        bytes32[] storage bids = buyOrderIds[outcomeIndex];
        require(index < bids.length, "CLOB: index OOB");
        for (uint256 i = index; i < bids.length - 1; i++) {
            bids[i] = bids[i + 1];
        }
        bids.pop();
    }

    /// @dev Remove sell order from book by index (shift left)
    function _removeFromSellBook(uint256 outcomeIndex, uint256 index) internal {
        bytes32[] storage asks = sellOrderIds[outcomeIndex];
        require(index < asks.length, "CLOB: index OOB");
        for (uint256 i = index; i < asks.length - 1; i++) {
            asks[i] = asks[i + 1];
        }
        asks.pop();
    }

    /// @dev Remove specific order from buy book by ID
    function _removeOrderFromBuyBook(uint256 outcomeIndex, bytes32 orderId) internal {
        bytes32[] storage bids = buyOrderIds[outcomeIndex];
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i] == orderId) {
                _removeFromBuyBook(outcomeIndex, i);
                return;
            }
        }
    }

    /// @dev Remove specific order from sell book by ID
    function _removeOrderFromSellBook(uint256 outcomeIndex, bytes32 orderId) internal {
        bytes32[] storage asks = sellOrderIds[outcomeIndex];
        for (uint256 i = 0; i < asks.length; i++) {
            if (asks[i] == orderId) {
                _removeFromSellBook(outcomeIndex, i);
                return;
            }
        }
    }

    /// @dev Cancel all orders on one side for an outcome
    function _cancelAllSide(uint256 outcomeIndex, Side side) internal {
        if (side == Side.BUY) {
            bytes32[] storage bids = buyOrderIds[outcomeIndex];
            while (bids.length > 0) {
                bytes32 orderId = bids[0];
                Order storage order = orders[orderId];
                if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                    order.status = OrderStatus.Cancelled;
                    uint256 usdcRefund = (order.usdcCommitted * order.remainingAmount) / order.originalAmount;
                    if (usdcRefund > 0) {
                        usdc.safeTransfer(order.trader, usdcRefund);
                    }
                    emit OrderCancelled(orderId, order.trader, usdcRefund);
                }
                _removeFromBuyBook(outcomeIndex, 0);
            }
        } else {
            bytes32[] storage asks = sellOrderIds[outcomeIndex];
            while (asks.length > 0) {
                bytes32 orderId = asks[0];
                Order storage order = orders[orderId];
                if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                    order.status = OrderStatus.Cancelled;
                    if (order.remainingAmount > 0) {
                        bytes32 collectionId =
                            conditionalTokens.getCollectionId(bytes32(0), conditionId, _indexSets[outcomeIndex]);
                        uint256 positionId = uint256(conditionalTokens.getPositionId(usdc, collectionId));
                        conditionalTokens.safeTransferFrom(
                            address(this), order.trader, positionId, order.remainingAmount, ""
                        );
                    }
                    emit OrderCancelled(orderId, order.trader, order.remainingAmount);
                }
                _removeFromSellBook(outcomeIndex, 0);
            }
        }
    }
}
