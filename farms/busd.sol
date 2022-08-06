// SPDX-License-Identifier: MIT

/**
 * Website: https://app.bitstasio.com
 */

pragma solidity ^0.8.0; // solhint-disable-line

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./IToken.sol";

contract BitstasioTokenFarm {
    using SafeMath for uint256;

    struct Referral {
        mapping(address => bool) referredMap; // sender referred which wallets?
        address referredBy; // sender was referred by?
        address[] referred; // list of wallets referred by sender?
        uint256 bitsReceived; // total number of bits sender received from referrals?
        uint256 referralUses; // number of referral uses for sender?
    }

    uint256 public BIT_TO_CONVERT_1SHARE = 2592000;
    uint256 PSN = 10000;
    uint256 PSNH = 5000;
    bool public initialized = false;
    uint8 public feePerc;
    address public admin;
    address public feeReceiver;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public ownedBits;
    mapping(address => uint256) public lastConvert;
    mapping(address => bool) public whitelist;

    mapping(address => Referral) private referrals;

    uint256 public launchBlock;
    uint256 public marketBit;
    IToken public token_farm;
    address erctoken;

    constructor(address _token, uint256 _launchBlock) {
        erctoken = _token;
        admin = msg.sender;
        feePerc = 5; // maximum possible - can be reduced or set back to 5
        feeReceiver = msg.sender;
        token_farm = IToken(erctoken);
        launchBlock = _launchBlock;
        setWhitelist(msg.sender);
    }

    event BuyBits(address from, uint256 amount);
    event CompoundBits(address from, uint256 bitUsed, uint256 sharesReceived, address ref);
    event SellBits(address from, uint256 amount);
    event SendShares(address from, address to, uint256 amount);
    event AddWhitelist(address addr);
    event NewAdmin(address addr);
    event Refer(address ref, uint256 bitsReceived);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin restricted.");
        _;
    }

    modifier onlyFeeReceiver() {
        require(msg.sender == feeReceiver, "Only feeReceiver restricted.");
        _;
    }

    modifier isWhitelisted() {
        require(
            block.number >= launchBlock || whitelist[msg.sender] == true,
            "You are not whitelisted."
        );
        _;
    }

    modifier isNotContract() {
        require(isContract(msg.sender) == false, "Contracts can't buy shares.");
        _;
    }

    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function refer(address referrer, uint256 bitUsed) public {
        Referral storage referral = referrals[referrer];

        uint256 reward = getReferralReward(referrer, bitUsed);

        if (referral.referredMap[msg.sender] == false) {
            referral.referredMap[msg.sender] = true;
            referral.referred.push(msg.sender);
        }

        ownedBits[referrer] = ownedBits[referrer].add(reward);
        referral.referralUses = referral.referralUses.add(1);
        referral.bitsReceived = referral.bitsReceived.add(reward);

        emit Refer(referrer, reward);
    }

    function setWhitelist(address addr) public onlyAdmin {
        whitelist[addr] = true;

        emit AddWhitelist(addr);
    }

    function setManyWhitelist(address[] memory list) public onlyAdmin {
        require(list.length < 250, "The array is too long.");

        for (uint256 i = 0; i < list.length; i++) {
            setWhitelist(list[i]);
        }
    }

    function setFeeReceiver(address _newFeeReceiver) public onlyFeeReceiver {
        feeReceiver = _newFeeReceiver;
    }

    function setFee(uint8 newFees) public onlyFeeReceiver {
        require(newFees <= 5, "New fees is higher than 5.");

        feePerc = newFees;
    }

    function setAdmin(address _newAdmin) public onlyAdmin {
        admin = _newAdmin;

        emit NewAdmin(_newAdmin);
    }

    function sendShares(address to, uint256 amount) public {
        require(
            amount > 0 && amount <= shares[msg.sender],
            "Incorrect share transaction."
        );
        require(to != msg.sender, "You are sending shares to self.");

        shares[to] = shares[to].add(amount);
        shares[msg.sender] = shares[msg.sender].sub(amount);

        emit SendShares(msg.sender, to, amount);
    }

    function compoundBits(address ref) public {
        require(initialized, "Contract is not initialized yet.");

        Referral storage referral = referrals[msg.sender];
        address referredBy = referral.referredBy;
        uint256 bitUsed = getCompoundReward(getBits()); // double rewards from compounding if max level

        if (ref == msg.sender) {
            ref = address(0x0);
        }

        if (ref != address(0x0) && referredBy == address(0x0)) {
            referral.referredBy = ref;
        }

        if (referral.referredBy != address(0x0)) {
            refer(ref, bitUsed);
        }

        uint256 newShares = bitUsed.div(BIT_TO_CONVERT_1SHARE);
        shares[msg.sender] = shares[msg.sender].add(newShares);
        ownedBits[msg.sender] = 0;
        lastConvert[msg.sender] = block.timestamp;

        marketBit = marketBit.add(bitUsed.div(5));

        emit CompoundBits(msg.sender, bitUsed, newShares, ref);
    }

    function sellBits() public {
        require(initialized, "Contract is not initialized yet.");

        uint256 hasBit = getBits();
        uint256 bitValue = calculateBitSell(hasBit);
        uint256 fee = getFee(bitValue);

        ownedBits[msg.sender] = 0;
        lastConvert[msg.sender] = block.timestamp;
        marketBit = SafeMath.add(marketBit, hasBit);

        token_farm.transfer(feeReceiver, fee);
        token_farm.transfer(msg.sender, SafeMath.sub(bitValue, fee));

        emit SellBits(msg.sender, bitValue);
    }

    function buyBits(address ref, uint256 amount)
        public
        isWhitelisted
        isNotContract
    {
        require(amount > 0, "You need to enter an amount.");
        require(initialized, "Contract is not initialized yet.");
        require(
            token_farm.transferFrom(address(msg.sender), address(this), amount),
            "Transfer failed."
        );

        uint256 bitBought = calculateBitBuy(amount, getBalance().sub(amount));

        bitBought = bitBought.sub(getFee(bitBought));

        uint256 fee = getFee(amount);

        ownedBits[msg.sender] = ownedBits[msg.sender].add(bitBought);

        require(token_farm.transfer(feeReceiver, fee), "Transfer failed.");
        compoundBits(ref);

        emit BuyBits(msg.sender, bitBought);
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

        return sharesBought.sub(getFee(sharesBought));
    }

    function getFee(uint256 amount) public view returns (uint256) {
        return (SafeMath.mul(amount, feePerc)).div(100);
    }

    function seedMarket(uint256 amount) public {
        require(
            token_farm.transferFrom(address(msg.sender), address(this), amount),
            "Failed to seed market."
        );
        require(marketBit == 0);
        initialized = true;
        marketBit = 108000000000;
    }

    function getBalance() public view returns (uint256) {
        return token_farm.balanceOf(address(this));
    }

    function getBalanceToken() public view returns (uint256) {
        return token_farm.balanceOf(msg.sender);
    }

    function getCompoundReward(uint256 bitUsed) public view returns (uint256) {
        uint8 level = getReferralLevel(msg.sender);

        // Double compound reward if maximum referral level
        return level >= 3 ? bitUsed.mul(2) : bitUsed;
    }

    function getAllowance() public view returns (uint256) {
        return token_farm.allowance(msg.sender, address(this));
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

    function getWhitelistEnd() public view returns (uint256) {
        return launchBlock;
    }

    function getLastConvert() public view returns (uint256) {
        return lastConvert[msg.sender];
    }

    function getReferralLevel(address referrer) public view returns (uint8) {
        Referral storage referral = referrals[referrer];
        uint256 referred = referral.referred.length;

        if (referred > 50) return 3;
        else if (referred >= 30 && referred <= 50) return 2;
        else if (referred >= 5 && referred < 30) return 1;
        else return 0;
    }

    function getReferredBy(address referred) public view returns (address) {
        Referral storage referral = referrals[referred];

        return referral.referredBy;
    }

    function getReferredAmount(address referred) public view returns (uint256) {
        Referral storage referral = referrals[referred];

        return referral.referred.length;
    }

    function getReferredBitsReceived(address referred) public view returns (uint256) {
        Referral storage referral = referrals[referred];

        return referral.bitsReceived;
    }

    function getReferralUses(address referred) public view returns (uint256) {
        Referral storage referral = referrals[referred];

        return referral.referralUses;
    }

    function getReferralReward(address referrer, uint256 bitUsed)
        public
        view
        returns (uint256)
    {
        uint8 level = getReferralLevel(referrer);

        if (level == 3) return bitUsed.mul(20).div(100);
        // 20%
        else if (level == 2) return bitUsed.mul(15).div(100);
        // 15%
        else if (level == 1) return bitUsed.mul(10).div(100);
        // 10%
        else return bitUsed.mul(5).div(100); // 5%
    }

    function getBitSinceLastConvert(address adr) public view returns (uint256) {
        uint256 secondsPassed = min(
            BIT_TO_CONVERT_1SHARE,
            SafeMath.sub(block.timestamp, lastConvert[adr])
        );
        return SafeMath.mul(secondsPassed, shares[adr]);
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
