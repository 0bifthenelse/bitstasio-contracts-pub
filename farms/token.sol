// SPDX-License-Identifier: MIT

/**
 * Bitstasio Token Farm revision 4
 * Application: https://app.bitstasio.com
 * - 6% automatic share burn on selling, incentivizes investment strategies & punishes TVL draining (bots rekt)
 * - share burning also burns bits, decreasing supply - deflationary behavior
 * - 48 hours rewards cutoff
 * - referrals features have been removed
 * - lowered daily return
 * - automatically swap fees to ETH and distribute them to admin, marketing, dispatcher & influencer wallets
 */

pragma solidity ^0.8.17; // solhint-disable-line

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/IToken.sol";
import "../interfaces/IUniswapRouter.sol";

contract BitstasioTokenFarm {
    using SafeMath for uint256;

    uint256 PSN = 10000;
    uint256 PSNH = 5000;
    bool public initialized = false;

    address public admin;
    address public marketing;
    address public influencer;
    address public dispatcher;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public ownedBits;
    mapping(address => uint256) public lastConvert;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;

    uint256 public marketBit;
    IToken public immutable token_farm;
    address private erctoken;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint16 internal constant PERCENT_DIVIDER = 1e4;
    uint16 internal constant SHARES_TO_BURN = 600; // 6.00%

    // TOTAL DEPOSIT FEES: 5%
    uint256 public constant FEE_DEPOSIT_ADMIN = 150; // 1.50%
    uint256 public constant FEE_DEPOSIT_DISPATCHER = 100; // 1.00%
    uint256 public constant FEE_DEPOSIT_MARKETING = 150; // 1.50%
    uint256 public constant FEE_DEPOSIT_INFLUENCER = 100; // 1.00%
    uint256 public constant FEE_DEPOSIT_TOTAL = 5;

    // TOTAL WITHDRAW FEES: 10%
    uint256 public constant FEE_WITHDRAW_ADMIN = 250; // 2.50%
    uint256 public constant FEE_WITHDRAW_DISPATCHER = 150; // 1.50%
    uint256 public constant FEE_WITHDRAW_MARKETING = 400; // 4.00%
    uint256 public constant FEE_WITHDRAW_INFLUENCER = 200; // 2.00%
    uint256 public constant FEE_WITHDRAW_TOTAL = 10;

    uint256 public constant BIT_TO_CONVERT_1SHARE = 7776000;
    uint256 public constant DAILY_INTEREST = 1000; // 1.000% daily ROI

    IUniswapV2Router public constant router =
        IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E); // Pancakeswap Router

    constructor(
        address _token,
        address _influencer,
        address _marketing,
        address _dispatcher
    ) {
        erctoken = _token;
        token_farm = IToken(erctoken);
        admin = msg.sender;
        influencer = _influencer;
        marketing = _marketing;
        dispatcher = _dispatcher;
    }

    event BuyBits(address indexed from, uint256 amount, uint256 bitBought);
    event CompoundBits(
        address indexed from,
        uint256 bitUsed,
        uint256 sharesReceived
    );
    event SellBits(address indexed from, uint256 amount);
    event BurnShares(address indexed from, uint256 sharesBurned);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin restricted.");
        _;
    }

    function burnShares(uint256 amount) public {
        require(
            amount > 0 && amount <= shares[msg.sender],
            "Incorrect share amount."
        );

        uint256 balance = shares[msg.sender];
        uint256 bits_to_burn = balance.mul(_getBitToShare());

        if (marketBit - bits_to_burn > 0) {
            marketBit = marketBit.sub(bits_to_burn);
        }

        shares[DEAD] = shares[DEAD].add(amount);
        shares[msg.sender] = shares[msg.sender].sub(amount);

        emit BurnShares(msg.sender, amount);
    }

    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function _getPercentage(uint256 value, uint256 percent)
        private
        pure
        returns (uint256)
    {
        return (value * percent) / PERCENT_DIVIDER;
    }

    function _getPercentageSwapped(
        uint256 value,
        uint256 percent,
        uint256 total
    ) private pure returns (uint256) {
        return (value * percent) / (100 * total); // keeps proportions
    }

    function _getCoinAfterSwap(uint256 value) private returns (uint256) {
        uint256 deadline = block.timestamp + 1 minutes;
        address[] memory path = new address[](2);
        path[0] = erctoken;
        path[1] = router.WETH();

        require(token_farm.approve(address(router), value), "Approve failed.");

        uint256 balance_before = address(this).balance;

        router.swapExactTokensForETH(value, 0, path, address(this), deadline);

        return address(this).balance.sub(balance_before);
    }

    function _getFeeDeposit(uint256 value) private returns (uint256) {
        uint256 feeAdmin_token = _getPercentage(value, FEE_DEPOSIT_ADMIN);
        uint256 feeMarketing_token = _getPercentage(
            value,
            FEE_DEPOSIT_MARKETING
        );
        uint256 feeDispatcher_token = _getPercentage(
            value,
            FEE_DEPOSIT_DISPATCHER
        );
        uint256 feeInfluencer_token = _getPercentage(
            value,
            FEE_DEPOSIT_INFLUENCER
        );

        uint256 total_to_swap = feeAdmin_token +
            feeMarketing_token +
            feeDispatcher_token +
            feeInfluencer_token;

        uint256 swapped_coins = _getCoinAfterSwap(total_to_swap);

        uint256 feeAdmin = _getPercentageSwapped(
            swapped_coins,
            FEE_DEPOSIT_ADMIN,
            FEE_DEPOSIT_TOTAL
        );
        uint256 feeMarketing = _getPercentageSwapped(
            swapped_coins,
            FEE_DEPOSIT_MARKETING,
            FEE_DEPOSIT_TOTAL
        );
        uint256 feeDispatcher = _getPercentageSwapped(
            swapped_coins,
            FEE_DEPOSIT_DISPATCHER,
            FEE_DEPOSIT_TOTAL
        );
        uint256 feeInfluencer = _getPercentageSwapped(
            swapped_coins,
            FEE_DEPOSIT_INFLUENCER,
            FEE_DEPOSIT_TOTAL
        );

        payable(admin).transfer(feeAdmin);
        payable(dispatcher).transfer(feeDispatcher);
        payable(influencer).transfer(feeInfluencer);
        payable(marketing).transfer(feeMarketing);

        return
            value -
            feeAdmin_token -
            feeMarketing_token -
            feeInfluencer_token -
            feeDispatcher_token;
    }

    function _getFeeDepositSimple(uint256 value)
        private
        pure
        returns (uint256)
    {
        uint256 feeAdmin = _getPercentage(value, FEE_DEPOSIT_ADMIN);
        uint256 feeMarketing = _getPercentage(value, FEE_DEPOSIT_MARKETING);
        uint256 feeDispatcher = _getPercentage(value, FEE_DEPOSIT_DISPATCHER);
        uint256 feeInfluencer = _getPercentage(value, FEE_DEPOSIT_INFLUENCER);

        return value - feeAdmin - feeMarketing - feeInfluencer - feeDispatcher;
    }

    function _getFeeWithdraw(uint256 value) private returns (uint256) {
        uint256 feeAdmin_token = _getPercentage(value, FEE_WITHDRAW_ADMIN);
        uint256 feeMarketing_token = _getPercentage(
            value,
            FEE_WITHDRAW_MARKETING
        );
        uint256 feeDispatcher_token = _getPercentage(
            value,
            FEE_WITHDRAW_DISPATCHER
        );
        uint256 feeInfluencer_token = _getPercentage(
            value,
            FEE_WITHDRAW_INFLUENCER
        );

        uint256 total_to_swap = feeAdmin_token +
            feeMarketing_token +
            feeDispatcher_token +
            feeInfluencer_token;

        uint256 swapped_coins = _getCoinAfterSwap(total_to_swap);

        uint256 feeAdmin = _getPercentageSwapped(
            swapped_coins,
            FEE_WITHDRAW_ADMIN,
            FEE_WITHDRAW_TOTAL
        );
        uint256 feeMarketing = _getPercentageSwapped(
            swapped_coins,
            FEE_WITHDRAW_MARKETING,
            FEE_WITHDRAW_TOTAL
        );
        uint256 feeDispatcher = _getPercentageSwapped(
            swapped_coins,
            FEE_WITHDRAW_DISPATCHER,
            FEE_WITHDRAW_TOTAL
        );
        uint256 feeInfluencer = _getPercentageSwapped(
            swapped_coins,
            FEE_WITHDRAW_INFLUENCER,
            FEE_WITHDRAW_TOTAL
        );

        payable(admin).transfer(feeAdmin);
        payable(dispatcher).transfer(feeDispatcher);
        payable(influencer).transfer(feeInfluencer);
        payable(marketing).transfer(feeMarketing);

        return
            value -
            feeAdmin_token -
            feeMarketing_token -
            feeInfluencer_token -
            feeDispatcher_token;
    }

    function _getFeeWithdrawSimple(uint256 value)
        private
        pure
        returns (uint256)
    {
        uint256 feeAdmin = _getPercentage(value, FEE_WITHDRAW_ADMIN);
        uint256 feeMarketing = _getPercentage(value, FEE_WITHDRAW_MARKETING);
        uint256 feeDispatcher = _getPercentage(value, FEE_WITHDRAW_DISPATCHER);
        uint256 feeInfluencer = _getPercentage(value, FEE_WITHDRAW_INFLUENCER);

        return value - feeAdmin - feeMarketing - feeInfluencer - feeDispatcher;
    }

    function _getBitToShare() private pure returns (uint256) {
        return 7776e6 / DAILY_INTEREST;
    }

    function _getBitSinceLastConvert(address adr)
        private
        view
        returns (uint256)
    {
        uint256 secondsPassed = min(
            2 days,
            SafeMath.sub(block.timestamp, lastConvert[adr])
        );

        return SafeMath.mul(secondsPassed, shares[adr]);
    }

    function getPercentageSwapped(
        uint256 value,
        uint256 percent,
        uint256 total
    ) external pure returns (uint256) {
        return _getPercentageSwapped(value, percent, total);
    }

    function getBitToShare() external pure returns (uint256) {
        return _getBitToShare();
    }

    function seedMarket(uint256 amount) public onlyAdmin {
        require(!initialized, "Already initialized.");
        require(marketBit == 0);
        require(
            token_farm.transferFrom(msg.sender, address(this), amount),
            "Transaction failed."
        );
        initialized = true;
        marketBit = 108000000000;
    }

    function getBalance() public view returns (uint256) {
        return token_farm.balanceOf(address(this));
    }

    function getShares() public view returns (uint256) {
        return shares[msg.sender];
    }

    function getBits() public view returns (uint256) {
        return
            SafeMath.add(
                ownedBits[msg.sender],
                _getBitSinceLastConvert(msg.sender)
            );
    }

    function getLastConvert() public view returns (uint256) {
        return lastConvert[msg.sender];
    }

    function getBitSinceLastConvert(address adr)
        external
        view
        returns (uint256)
    {
        return _getBitSinceLastConvert(adr);
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function setDispatcher(address _dispatcher) external onlyAdmin {
        dispatcher = _dispatcher;
    }

    function setInfluencer(address _influencer) external onlyAdmin {
        influencer = _influencer;
    }

    function setMarketing(address _marketing) external onlyAdmin {
        marketing = _marketing;
    }

    function compoundBits() public {
        require(initialized, "Contract is not initialized yet.");

        uint256 bitUsed = getBits();

        uint256 newShares = bitUsed.div(_getBitToShare());
        shares[msg.sender] = shares[msg.sender].add(newShares);
        ownedBits[msg.sender] = 0;
        lastConvert[msg.sender] = block.timestamp;

        marketBit = marketBit.add(bitUsed.div(5));

        emit CompoundBits(msg.sender, bitUsed, newShares);
    }

    function sellBits() external {
        require(initialized, "Contract is not initialized yet.");

        uint256 sharesOwned = shares[msg.sender];

        require(sharesOwned > 0, "You must own shares to claim.");

        uint256 hasBit = getBits();
        uint256 bitValue = calculateBitSell(hasBit);
        uint256 fee = _getFeeWithdrawSimple(bitValue);
        uint256 sharesToBurn = (sharesOwned.mul(SHARES_TO_BURN)).div(
            PERCENT_DIVIDER
        );

        ownedBits[msg.sender] = 0;
        lastConvert[msg.sender] = block.timestamp;
        marketBit = marketBit.add(hasBit);
        withdrawn[msg.sender] += bitValue.sub(fee);

        if (sharesOwned >= 100) {
            burnShares(sharesToBurn); // burn 6% shares
        }

        fee = _getFeeWithdraw(bitValue);

        token_farm.transfer(msg.sender, bitValue.sub(fee));

        emit SellBits(msg.sender, bitValue);
    }

    function buyBits(uint256 amount) external {
        require(amount > 0, "You need to enter an amount.");
        require(initialized, "Contract is not initialized yet.");
        require(
            token_farm.transferFrom(address(msg.sender), address(this), amount),
            "Transfer failed."
        );

        uint256 bitBought = calculateBitBuy(amount, getBalance().sub(amount));
        bitBought = bitBought.sub(_getFeeDepositSimple(bitBought));
        ownedBits[msg.sender] += bitBought;
        deposited[msg.sender] += _getFeeDepositSimple(amount);

        compoundBits();

        _getFeeDeposit(amount);

        emit BuyBits(msg.sender, amount, bitBought);
    }

    function calculateTrade(
        uint256 rt,
        uint256 rs,
        uint256 bs
    ) public view returns (uint256) {
        return
            SafeMath.div(
                SafeMath.mul(PSN, bs),
                SafeMath.add(
                    PSNH,
                    SafeMath.div(
                        SafeMath.add(
                            SafeMath.mul(PSN, rs),
                            SafeMath.mul(PSNH, rt)
                        ),
                        rt
                    )
                )
            );
    }

    function calculateBitSell(uint256 bit) public view returns (uint256) {
        return calculateTrade(bit, marketBit, getBalance());
    }

    function calculateBitBuy(uint256 token, uint256 contractBalance)
        public
        view
        returns (uint256)
    {
        return calculateTrade(token, contractBalance, marketBit);
    }

    function calculateBitBuySimple(uint256 eth) public view returns (uint256) {
        return calculateBitBuy(eth, getBalance());
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    receive() external payable {}
}
