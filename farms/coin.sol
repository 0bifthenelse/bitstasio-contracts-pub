// SPDX-License-Identifier: MIT

/**
 * Bitstasio Coin Farm revision 2
 * Application: https://app.bitstasio.com
 * - 6% automatic share burn on selling, incentivizes investment strategies & punishes TVL draining
 * - share burning also burns bits, decreasing supply - deflationary behavior
 * - 48 hours rewards cutoff
 * - referrals features have been removed
 */

pragma solidity ^0.8.0; // solhint-disable-line

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract BitstasioCoinFarm {
    using SafeMath for uint256;

    uint256 public BIT_TO_CONVERT_1SHARE = 2592000;
    uint256 PSN = 10000;
    uint256 PSNH = 5000;
    bool public initialized = false;
    address public admin;
    address public feeReceiver;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public ownedBits;
    mapping(address => uint256) public lastConvert;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;

    uint256 public marketBit;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 internal constant PERCENT_DIVIDER = 1e4;
    uint16 internal constant SHARES_TO_BURN = 600;

    uint16 public constant FEE_DEPOSIT = 500; // 5%
    uint16 public constant FEE_WITHDRAW = 1000; // 10%

    constructor() {
        admin = msg.sender;
        feeReceiver = msg.sender;
    }

    event BuyBits(address indexed from, uint256 amount, uint256 bitBought);
    event CompoundBits(
        address indexed from,
        uint256 bitUsed,
        uint256 sharesReceived
    );
    event SellBits(address indexed from, uint256 amount);
    event BurnShares(address indexed from, uint256 sharesBurned);

    modifier onlyFeeReceiver() {
        require(msg.sender == feeReceiver, "Only feeReceiver restricted.");
        _;
    }

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
        uint256 bits_to_burn = balance.mul(BIT_TO_CONVERT_1SHARE);

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

    function setAdmin(address _newAdmin) public onlyAdmin {
        admin = _newAdmin;
    }

    function setFeeReceiver(address _newFeeReceiver) public onlyFeeReceiver {
        feeReceiver = _newFeeReceiver;
    }

    function compoundBits() public {
        require(initialized, "Contract is not initialized yet.");

        uint256 bitUsed = getBits();

        uint256 newShares = bitUsed.div(BIT_TO_CONVERT_1SHARE);
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
        uint256 fee = getFeeWithdraw(bitValue);
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

        payable(feeReceiver).transfer(fee);
        payable(msg.sender).transfer(bitValue.sub(fee));

        emit SellBits(msg.sender, bitValue);
    }

    function buyBits() external payable {
        require(msg.value > 0, "You need to enter an amount.");
        require(initialized, "Contract is not initialized yet.");

        uint256 bitBought = calculateBitBuy(msg.value, getBalance().sub(msg.value));
        bitBought = bitBought.sub(getFeeDeposit(bitBought));
        uint256 fee = getFeeDeposit(msg.value);
        ownedBits[msg.sender] = ownedBits[msg.sender].add(bitBought);
        deposited[msg.sender] += bitBought;

        payable(feeReceiver).transfer(fee);
        compoundBits();

        emit BuyBits(msg.sender, msg.value, bitBought);
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

    function calculateShareBuySimple(uint256 amount)
        public
        view
        returns (uint256)
    {
        uint256 sharesBought = calculateBitBuySimple(amount).div(
            BIT_TO_CONVERT_1SHARE
        );

        return sharesBought.sub(getFeeDeposit(sharesBought));
    }

    function getFeeDeposit(uint256 amount) public pure returns (uint256) {
        return (amount.mul(FEE_DEPOSIT)).div(PERCENT_DIVIDER);
    }

    function getFeeWithdraw(uint256 amount) public pure returns (uint256) {
        return (amount.mul(FEE_WITHDRAW)).div(PERCENT_DIVIDER);
    }

    function seedMarket() public payable onlyAdmin {
        require(!initialized, "Already initialized.");
        require(marketBit == 0);
        initialized = true;
        marketBit = 108000000000;
    }

    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getShares() public view returns (uint256) {
        return shares[msg.sender];
    }

    function getBits() public view returns (uint256) {
        return
            SafeMath.add(
                ownedBits[msg.sender],
                getBitSinceLastConvert(msg.sender)
            );
    }

    function getLastConvert() public view returns (uint256) {
        return lastConvert[msg.sender];
    }

    function getBitSinceLastConvert(address adr) public view returns (uint256) {
        uint256 secondsPassed = min(
            2 days,
            SafeMath.sub(block.timestamp, lastConvert[adr])
        );

        return SafeMath.mul(secondsPassed, shares[adr]);
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
