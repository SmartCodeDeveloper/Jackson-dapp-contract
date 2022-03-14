// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libs/ReentrancyGuard.sol";
import "./libs/SafeERC20.sol";
import "./libs/IUniswapAmm.sol";
import "./HearnToken.sol";

contract StakingPool is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for HearnToken;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LiquidifyHelper public liquidifyHelper;

    // Whether a limit is set for users
    bool public hasUserLimit;

    // Whether it is initialized
    bool public isInitialized;

    IUniswapV2Router02 public swapRouter;

    // staking token allocation strategy
    uint16 public buybackPercent = 9000;
    uint16 public liquidifyPercent = 1000;

    // staking token allocation strategy when referral link used
    uint16 public referralBuybackPercent = 9000;
    uint16 public referralUplinePercent = 500;
    uint16 public referralLiquidifyPercent = 500;

    // Accrued token per share
    uint256 public accTokenPerShare;

    // The block number when CAKE mining ends.
    uint256 public bonusEndBlock;

    // The block number when CAKE mining starts.
    uint256 public startBlock;

    // The block number of the last pool update
    uint256 public lastRewardBlock;

    // The last block time when the emission value updated
    uint256 public emissionValueUpdatedAt;

    uint16 public constant MAX_DEPOSIT_FEE = 2000;
    uint256 public constant MAX_EMISSION_RATE = 10**10;

    // The deposit fee
    uint16 public depositFee;

    // The fee address
    address public feeAddress;

    // The dev address
    address public devAddress;

    // The pool limit (0 if none)
    uint256 public poolLimitPerUser;

    // CAKE tokens created per block.
    uint256 public rewardPerBlock;

    // The precision factor
    uint256 public PRECISION_FACTOR;

    // The reward token
    HearnToken public rewardToken;

    // The staked token
    IERC20 public stakedToken;

    // Total supply of staked token
    uint256 public stakedSupply;

    // Total buy back staked token amount
    uint256 public totalBuyback;

    // Total bought back reward token amount
    uint256 public totalBoughtback;

    // Total liquidified amount
    uint256 public totalLiquidify;

    // Referral commissions over the protocol
    uint256 public totalReferralCommissions;

    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;

    struct UserInfo {
        uint256 amount; // How many staked tokens the user has provided
        uint256 rewardDebt; // Reward debt
        address referrer; // Referrer
        uint256 referralCommissionEarned; // Earned from referral commission
        uint256 totalEarned; // All-time reward token earned
    }

    enum EmissionUpdateMode {
        MANUAL,
        AUTO
    }

    event AdminTokenRecovery(address tokenRecovered, uint256 amount);
    event Deposited(address indexed user, uint256 amount);
    event EmergencyRewardWithdrawn(uint256 amount);
    event NewStartAndEndBlocks(uint256 startBlock, uint256 endBlock);
    event RewardPerBlockUpdated(
        EmissionUpdateMode mode,
        uint256 oldValue,
        uint256 newValue
    );
    event NewDepositFee(uint16 oldFee, uint16 newFee);
    event NewFeeAddress(address oldAddress, address newAddress);
    event NewDevAddress(address oldAddress, address newAddress);
    event NewPoolLimit(uint256 oldLimit, uint256 newLimit);
    event RewardsStop(uint256 blockNumber);

    constructor() {
        swapRouter = IUniswapV2Router02(
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E)
        );
    }

    /**
     * @notice Initialize the contract
     * @param _stakedToken: staked token address
     * @param _rewardToken: reward token address
     * @param _rewardPerBlock: reward per block (in rewardToken)
     * @param _startBlock: start block
     * @param _bonusEndBlock: end block
     * @param _poolLimitPerUser: pool limit per user in stakedToken (if any, else 0)
     * @param _depositFee: deposit fee
     * @param _feeAddress: fee address
     * @param _devAddress: dev address
     * @param _admin: admin address with ownership
     */
    function initialize(
        IERC20 _stakedToken,
        HearnToken _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _poolLimitPerUser,
        uint16 _depositFee,
        address _feeAddress,
        address _devAddress,
        address _admin
    ) external onlyOwner {
        require(!isInitialized, "Already initialized");
        require(_feeAddress != address(0), "Invalid fee address");
        require(_devAddress != address(0), "Invalid dev address");
        uint256 rewardDecimals = uint256(_rewardToken.decimals());
        require(
            _rewardPerBlock <= MAX_EMISSION_RATE.mul(10**rewardDecimals),
            "Out of maximum emission value"
        );

        _stakedToken.balanceOf(address(this));
        _rewardToken.balanceOf(address(this));
        // require(_stakedToken != _rewardToken, "stakedToken must be different from rewardToken");
        require(_startBlock > block.number, "startBlock cannot be in the past");
        require(
            _startBlock < _bonusEndBlock,
            "startBlock must be lower than endBlock"
        );

        // Make this contract initialized
        isInitialized = true;

        stakedToken = _stakedToken;
        rewardToken = _rewardToken;

        rewardPerBlock = _rewardPerBlock;
        emissionValueUpdatedAt = block.timestamp;
        emit RewardPerBlockUpdated(
            EmissionUpdateMode.MANUAL,
            0,
            rewardPerBlock
        );

        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;

        require(_depositFee <= MAX_DEPOSIT_FEE, "Invalid deposit fee");
        depositFee = _depositFee;

        feeAddress = _feeAddress;
        devAddress = _devAddress;

        if (_poolLimitPerUser > 0) {
            hasUserLimit = true;
            poolLimitPerUser = _poolLimitPerUser;
        }

        uint256 decimalsRewardToken = uint256(rewardToken.decimals());
        require(decimalsRewardToken < 30, "Must be inferior to 30");

        PRECISION_FACTOR = uint256(10**(uint256(30).sub(decimalsRewardToken)));

        // Set the lastRewardBlock as the startBlock
        lastRewardBlock = startBlock;

        // Transfer ownership to the admin address who becomes owner of the contract
        transferOwnership(_admin);
    }

    /**
     * @notice Deposit staked tokens and collect reward tokens (if any)
     * @param _amount: amount to deposit (in staking token)
     * @param _referrer: referrer
     */
    function deposit(uint256 _amount, address _referrer) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        if (hasUserLimit) {
            require(
                _amount.add(user.amount) <= poolLimitPerUser,
                "User amount above limit"
            );
        }

        _updatePool();

        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(accTokenPerShare)
                .div(PRECISION_FACTOR)
                .sub(user.rewardDebt);
            if (pending > 0) {
                safeRewardTransfer(msg.sender, pending);
                user.totalEarned = user.totalEarned.add(pending);
            }
        }

        if (_amount > 0) {
            uint256 balanceBefore = stakedToken.balanceOf(address(this));
            stakedToken.safeTransferFrom(msg.sender, address(this), _amount);
            _amount = stakedToken.balanceOf(address(this)).sub(balanceBefore);
            uint256 feeAmount = 0;

            if (depositFee > 0) {
                feeAmount = _amount.mul(depositFee).div(10000);
                if (feeAmount > 0) {
                    stakedToken.safeTransfer(feeAddress, feeAmount);
                }
            }

            user.amount = user.amount.add(_amount).sub(feeAmount);
            stakedSupply = stakedSupply.add(_amount).sub(feeAmount);
            handleDeposits(msg.sender, _referrer, _amount);
        }

        user.rewardDebt = user.amount.mul(accTokenPerShare).div(
            PRECISION_FACTOR
        );

        emit Deposited(msg.sender, _amount);
    }

    /**
     * @notice Handle deposits to buyback tokens and liquidify, upline
     * @param _from: address which did deposit
     * @param _referrer: referrer address
     * @param _amount: deposited amount
     */
    function handleDeposits(
        address _from,
        address _referrer,
        uint256 _amount
    ) internal {
        // When there is a referrer
        UserInfo storage user = userInfo[_from];
        if (
            user.referrer != _referrer &&
            _referrer != _from &&
            _referrer != address(0)
        ) {
            user.referrer = _referrer;
        }
        if (user.referrer != address(0)) {
            uint256 uplineAmount = _amount.mul(referralUplinePercent).div(
                10000
            );
            if (uplineAmount > 0) {
                stakedToken.safeTransfer(user.referrer, uplineAmount);
                totalReferralCommissions = totalReferralCommissions.add(
                    uplineAmount
                );
                UserInfo storage referrer = userInfo[user.referrer];
                referrer.referralCommissionEarned = referrer
                    .referralCommissionEarned
                    .add(uplineAmount);
                _amount = _amount.sub(uplineAmount);
            }
        }

        if (liquidifyPercent + buybackPercent == 0) {
            return;
        }

        uint256 liquidifyAmount = _amount.mul(liquidifyPercent).div(
            liquidifyPercent + buybackPercent
        );
        uint256 halfAmount = liquidifyAmount.div(2);
        uint256 buybackAmount = _amount.sub(liquidifyAmount);

        if (halfAmount > 0) {
            stakedToken.safeTransfer(
                address(liquidifyHelper),
                liquidifyAmount.sub(halfAmount)
            );
            uint256 swappedAmount = swapStakeTokenForRewardToken(
                halfAmount,
                address(liquidifyHelper)
            );
            if (swappedAmount > 0) {
                liquidifyHelper.liquifyAndBurn();
                totalLiquidify = totalLiquidify.add(liquidifyAmount);
            }
        }

        if (buybackAmount > 0) {
            uint256 boughtBackAmount = swapStakeTokenForRewardToken(
                buybackAmount,
                DEAD
            );
            totalBuyback = totalBuyback.add(buybackAmount);
            totalBoughtback = totalBoughtback.add(boughtBackAmount);
        }
    }

    /**
     * @notice Safe reward transfer, just in case if rounding error causes pool to not have enough reward tokens.
     * @param _to receiver address
     * @param _amount amount to transfer
     */
    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        if (_amount > rewardBalance) {
            rewardToken.safeTransfer(_to, rewardBalance);
        } else {
            rewardToken.safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Withdraw all reward tokens
     * @dev Only callable by owner. Needs to be for emergency.
     */
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        require(
            startBlock > block.number || bonusEndBlock < block.number,
            "Not allowed to remove reward tokens while pool is live"
        );
        safeRewardTransfer(msg.sender, _amount);

        emit EmergencyRewardWithdrawn(_amount);
    }

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of tokens to withdraw
     * @dev This function is only callable by admin.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
        external
        onlyOwner
    {
        require(
            _tokenAddress != address(stakedToken),
            "Cannot be staked token"
        );
        require(
            _tokenAddress != address(rewardToken),
            "Cannot be reward token"
        );

        IERC20(_tokenAddress).safeTransfer(msg.sender, _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /*
     * @notice Stop rewards
     * @dev Only callable by owner
     */
    function stopReward() external onlyOwner {
        require(startBlock < block.number, "Pool has not started");
        require(block.number <= bonusEndBlock, "Pool has ended");
        bonusEndBlock = block.number;

        emit RewardsStop(block.number);
    }

    /**
     * @notice Update swap router
     * @dev Only callable by owner
     */
    function updateSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swap router");
        swapRouter = IUniswapV2Router02(newSwapRouter);
        liquidifyHelper.setSwapRouter(newSwapRouter);
    }

    /**
     * @notice Update liquidify helper
     * @dev Only callable by owner
     */
    function updateLiquidifyHelper(LiquidifyHelper newLiquidifyHelper)
        external
        onlyOwner
    {
        require(
            address(newLiquidifyHelper) != address(0),
            "Invalid liquidify helper"
        );
        liquidifyHelper = newLiquidifyHelper;
    }

    /**
     * @notice Update staking token allocation percents
     * @param _buybackPercent: buyback percent
     * @param _liquidifyPercent: liquidify percent
     * @dev Only callable by owner
     */
    function updateAllocationPercents(
        uint16 _buybackPercent,
        uint16 _liquidifyPercent
    ) external onlyOwner {
        require(_buybackPercent + _liquidifyPercent == 10000, "Invalid input");
        buybackPercent = _buybackPercent;
        liquidifyPercent = _liquidifyPercent;
    }

    /**
     * @notice Update staking token allocation percents when referral link used
     * @param _buybackPercent: buyback percent
     * @param _uplinePercent: upline percent
     * @param _liquidifyPercent: liquidify percent
     * @dev Only callable by owner
     */
    function updateReferralAllocationPercents(
        uint16 _buybackPercent,
        uint16 _uplinePercent,
        uint16 _liquidifyPercent
    ) external onlyOwner {
        require(
            _buybackPercent + _liquidifyPercent + _uplinePercent == 10000,
            "Invalid input"
        );
        referralBuybackPercent = _buybackPercent;
        referralLiquidifyPercent = _liquidifyPercent;
        referralUplinePercent = _uplinePercent;
    }

    /*
     * @notice Update pool limit per user
     * @dev Only callable by owner.
     * @param _hasUserLimit: whether the limit remains forced
     * @param _poolLimitPerUser: new pool limit per user
     */
    function updatePoolLimitPerUser(
        bool _hasUserLimit,
        uint256 _poolLimitPerUser
    ) external onlyOwner {
        require(hasUserLimit, "Must be set");
        if (_hasUserLimit) {
            require(
                _poolLimitPerUser > poolLimitPerUser,
                "New limit must be higher"
            );
            emit NewPoolLimit(poolLimitPerUser, _poolLimitPerUser);
            poolLimitPerUser = _poolLimitPerUser;
        } else {
            hasUserLimit = _hasUserLimit;
            emit NewPoolLimit(poolLimitPerUser, 0);
            poolLimitPerUser = 0;
        }
    }

    /*
     * @notice Update reward per block
     * @dev Only callable by owner.
     * @param _rewardPerBlock: the reward per block
     */
    function updateRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        uint256 rewardDecimals = uint256(rewardToken.decimals());
        require(
            _rewardPerBlock <= MAX_EMISSION_RATE.mul(10**rewardDecimals),
            "Out of maximum emission value"
        );
        _updatePool();
        emit RewardPerBlockUpdated(
            EmissionUpdateMode.MANUAL,
            rewardPerBlock,
            _rewardPerBlock
        );
        rewardPerBlock = _rewardPerBlock;
        emissionValueUpdatedAt = block.timestamp;
    }

    /*
     * @notice Update deposit fee
     * @dev Only callable by owner.
     * @param _depositFee: the deposit fee
     */
    function updateDepositFee(uint16 _depositFee) external onlyOwner {
        require(_depositFee <= MAX_DEPOSIT_FEE, "Invalid deposit fee");
        emit NewDepositFee(depositFee, _depositFee);
        depositFee = _depositFee;
    }

    /*
     * @notice Update fee address
     * @dev Only callable by owner.
     * @param _feeAddress: the fee address
     */
    function updateFeeAddress(address _feeAddress) external onlyOwner {
        require(_feeAddress != address(0), "Invalid zero address");
        require(feeAddress != _feeAddress, "Same fee address already set");
        emit NewFeeAddress(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    /*
     * @notice Update dev address
     * @dev Only callable by owner.
     * @param _devAddress: the dev address
     */
    function updateDevAddress(address _devAddress) external onlyOwner {
        require(_devAddress != address(0), "Invalid zero address");
        require(devAddress != _devAddress, "Same dev address already set");
        emit NewDevAddress(devAddress, _devAddress);
        devAddress = _devAddress;
    }

    /**
     * @notice It allows the admin to update start and end blocks
     * @dev This function is only callable by owner.
     * @param _startBlock: the new start block
     * @param _bonusEndBlock: the new end block
     */
    function updateStartAndEndBlocks(
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) external onlyOwner {
        require(block.number < startBlock, "Pool has started");
        require(
            _startBlock < _bonusEndBlock,
            "New startBlock must be lower than new endBlock"
        );
        require(
            block.number < _startBlock,
            "New startBlock must be higher than current block"
        );

        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;

        // Set the lastRewardBlock as the startBlock
        lastRewardBlock = startBlock;

        emit NewStartAndEndBlocks(_startBlock, _bonusEndBlock);
    }

    /*
     * @notice View function to see pending reward on frontend.
     * @param _user: user address
     * @return Pending reward for a given user
     */
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (block.number > lastRewardBlock && stakedSupply != 0) {
            uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);

            uint256 currentRewardPerBlock = viewEmissionValue();
            uint256 cakeReward = multiplier.mul(currentRewardPerBlock);
            uint256 adjustedTokenPerShare = accTokenPerShare.add(
                cakeReward.mul(PRECISION_FACTOR).div(stakedSupply)
            );
            return
                user
                    .amount
                    .mul(adjustedTokenPerShare)
                    .div(PRECISION_FACTOR)
                    .sub(user.rewardDebt);
        } else {
            return
                user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(
                    user.rewardDebt
                );
        }
    }

    /**
     * @notice Emission value should be reduced by 2% every 30 days
     * @return Current emission value
     */
    function viewEmissionValue() public view returns (uint256) {
        if (block.timestamp > emissionValueUpdatedAt) {
            uint256 times = block.timestamp.sub(emissionValueUpdatedAt).div(
                30 days
            );
            if (times > 0) {
                uint256 deltaValue = rewardPerBlock.mul(2).mul(times).div(100);
                uint256 newRewardPerBlock;
                if (rewardPerBlock > deltaValue) {
                    newRewardPerBlock = rewardPerBlock.sub(deltaValue);
                } else {
                    newRewardPerBlock = rewardPerBlock.mul(2).div(100);
                }
                return newRewardPerBlock;
            }
        }
        return rewardPerBlock;
    }

    /*
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function _updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (stakedSupply == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 currentRewardPerBlock = viewEmissionValue();
        if (currentRewardPerBlock != rewardPerBlock) {
            emit RewardPerBlockUpdated(
                EmissionUpdateMode.AUTO,
                rewardPerBlock,
                currentRewardPerBlock
            );
            rewardPerBlock = currentRewardPerBlock;
            emissionValueUpdatedAt = block.timestamp;
        }

        uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
        uint256 cakeReward = multiplier.mul(rewardPerBlock);

        rewardToken.mint(devAddress, cakeReward.div(10)); // 10% minted to dev wallet
        rewardToken.mint(cakeReward);

        accTokenPerShare = accTokenPerShare.add(
            cakeReward.mul(PRECISION_FACTOR).div(stakedSupply)
        );
        lastRewardBlock = block.number;
    }

    /*
     * @notice Return reward multiplier over the given _from to _to block.
     * @param _from: block to start
     * @param _to: block to finish
     */
    function _getMultiplier(uint256 _from, uint256 _to)
        internal
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from);
        } else if (_from >= bonusEndBlock) {
            return 0;
        } else {
            return bonusEndBlock.sub(_from);
        }
    }

    /**
     * @notice Swap staked token to the reward amount and burn them
     * @return _outAmount
     */
    function swapStakeTokenForRewardToken(uint256 _inAmount, address _to)
        internal
        returns (uint256 _outAmount)
    {
        // generate the uniswap pair path of staked token -> reward token
        address[] memory path = new address[](2);
        path[0] = address(stakedToken);
        path[1] = address(rewardToken);

        stakedToken.approve(address(swapRouter), _inAmount);

        uint256 balanceBefore = rewardToken.balanceOf(_to);

        // make the swap
        swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _inAmount,
            0, // accept any amount of HEARN
            path,
            _to,
            block.timestamp.add(300)
        );
        _outAmount = rewardToken.balanceOf(_to).sub(balanceBefore);
    }

    /**
     * @notice Add liquidity and burn them
     */
    function addLiquidityAndBurn(
        uint256 stakedTokenAmount,
        uint256 rewardTokenAmount
    ) internal {
        // approve token transfer to cover all possible scenarios
        stakedToken.approve(address(swapRouter), stakedTokenAmount);
        rewardToken.approve(address(swapRouter), rewardTokenAmount);

        // add the liquidity
        swapRouter.addLiquidity(
            address(stakedToken),
            address(rewardToken),
            stakedTokenAmount,
            rewardTokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            DEAD,
            block.timestamp.add(300)
        );
    }

    //to recieve ETH from swapRouter when swaping
    receive() external payable {}
}
