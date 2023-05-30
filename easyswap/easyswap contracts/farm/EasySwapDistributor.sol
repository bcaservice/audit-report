// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./libraries/BoringERC20.sol";
import "../interfaces/IXEasyToken.sol";

contract EasySwapDistributor is Ownable, ReentrancyGuard {
    using BoringERC20 for IBoringERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
    }

    // Info of each pool.
    struct PoolInfo {
        IBoringERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Easy to distribute per block.
        uint256 lastRewardTimestamp; // Last block number that Easy distribution occurs.
        uint256 accEasyPerShare; // Accumulated Easy per share, times 1e18. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 harvestInterval; // Harvest interval in seconds
        uint256 totalLp; // Total token in Pool
    }

    IBoringERC20 public easy;

    // Easy tokens created per second
    uint256 public easyPerSec;

    // Max harvest interval: 14 days
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Maximum deposit fee rate: 10%
    uint16 public constant MAXIMUM_DEPOSIT_FEE_RATE = 1000;

    // Info of each pool
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The timestamp when Easy emissions starts.
    uint256 public startTimestamp;

    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Total Easy in Easy Pools (can be multiple pools)
    uint256 public totalEasyInPools;

    // core address.
    address public coreAddress;

    // deposit fee address if deposit fee is turned on
    address public feeAddress;

    // Percentage of pool rewards that go to the core contributors
    uint256 public corePercent = 200; // 20%

    // Percentage of pool rewards that go to the ecosystem and partnerships
    uint256 public ecosystemPercent = 200; // 20%

    // ecosystem wallet address
    address public ecosystemAddress;

    // xEasySwap Token rate
    uint256 public xEasyTokenRate = 30; // 30%

    // xEasySwap Token address
    IXEasyToken public immutable xEasyToken;

    // The precision factor
    uint256 internal constant ACC_TOKEN_PRECISION = 1e12;

    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    event Add(
        uint256 indexed pid,
        uint256 allocPoint,
        IBoringERC20 indexed lpToken,
        uint16 depositFeeBP,
        uint256 harvestInterval
    );

    event Set(
        uint256 indexed pid,
        uint256 allocPoint,
        uint16 depositFeeBP,
        uint256 harvestInterval
    );

    event UpdatePool(
        uint256 indexed pid,
        uint256 lastRewardTimestamp,
        uint256 lpSupply,
        uint256 accEasyPerShare
    );

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event EmissionRateUpdated(
        address indexed caller,
        uint256 previousValue,
        uint256 newValue
    );

    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );

    event AllocPointsUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );

    event SetFeeAddress(address indexed oldAddress, address indexed newAddress);

    constructor(
        IBoringERC20 _easy,
        uint256 _easyPerSec,
        address _coreAddress,
        address _ecosystemAddress,
        address _feeAddress,
        IXEasyToken _xEasyToken
    ) {
        easy = _easy;
        easyPerSec = _easyPerSec;
        coreAddress = _coreAddress;
        ecosystemAddress = _ecosystemAddress;
        feeAddress = _feeAddress;
        IERC20(address(_easy)).approve(address(_xEasyToken), type(uint256).max);
        xEasyToken = _xEasyToken;
        startTimestamp = block.timestamp + (60 * 60 * 24 * 365);
    }

    // Set farming start LFG
    function startFarming() public onlyOwner {
        require(block.timestamp < startTimestamp, "farm already started");

        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardTimestamp = block.timestamp;
        }

        startTimestamp = block.timestamp;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // Can add multiple pool with same lp token without messing up rewards, because each pool's balance is tracked using its own totalLp
    function add(
        uint256 _allocPoint,
        IBoringERC20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _harvestInterval
    ) public onlyOwner {
        require(
            _depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE,
            "add: deposit fee too high"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );

        _massUpdatePools();

        uint256 lastRewardTimestamp = block.timestamp > startTimestamp
            ? block.timestamp
            : startTimestamp;

        totalAllocPoint += _allocPoint;

        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: lastRewardTimestamp,
                accEasyPerShare: 0,
                depositFeeBP: _depositFeeBP,
                harvestInterval: _harvestInterval,
                totalLp: 0
            })
        );

        emit Add(
            poolInfo.length - 1,
            _allocPoint,
            _lpToken,
            _depositFeeBP,
            _harvestInterval
        );
    }

    // Update the given pool's Easy allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint256 _harvestInterval
    ) public onlyOwner validatePoolByPid(_pid) {
        require(
            _depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE,
            "set: deposit fee too high"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "set: invalid harvest interval"
        );

        _massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;

        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;

        emit Set(_pid, _allocPoint, _depositFeeBP, _harvestInterval);
    }

    // View function to see pending rewards on frontend.
    function pendingTokens(
        uint256 _pid,
        address _user
    )
        external
        view
        validatePoolByPid(_pid)
        returns (
            address[] memory addresses,
            string[] memory symbols,
            uint256[] memory decimals,
            uint256[] memory amounts
        )
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accEasyPerShare = pool.accEasyPerShare;
        uint256 lpSupply = pool.totalLp;

        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            uint256 multiplier = block.timestamp - pool.lastRewardTimestamp;
            uint256 total = 1000;
            uint256 lpPercent = total - corePercent;

            uint256 easyReward = (multiplier *
                easyPerSec *
                pool.allocPoint *
                lpPercent) /
                totalAllocPoint /
                total;

            accEasyPerShare += (
                ((easyReward * ACC_TOKEN_PRECISION) / lpSupply)
            );
        }

        uint256 pendingEasy = (((user.amount * accEasyPerShare) /
            ACC_TOKEN_PRECISION) - user.rewardDebt) + user.rewardLockedUp;

        addresses = new address[](1);
        symbols = new string[](1);
        amounts = new uint256[](1);
        decimals = new uint256[](1);

        addresses[0] = address(easy);
        symbols[0] = IBoringERC20(easy).safeSymbol();
        decimals[0] = IBoringERC20(easy).safeDecimals();
        amounts[0] = pendingEasy;
    }

    /// @notice View function to see pool rewards per sec
    function poolRewardsPerSec(
        uint256 _pid
    )
        external
        view
        validatePoolByPid(_pid)
        returns (
            address[] memory addresses,
            string[] memory symbols,
            uint256[] memory decimals,
            uint256[] memory rewardsPerSec
        )
    {
        PoolInfo storage pool = poolInfo[_pid];

        addresses = new address[](1);
        symbols = new string[](1);
        decimals = new uint256[](1);
        rewardsPerSec = new uint256[](1);

        addresses[0] = address(easy);
        symbols[0] = IBoringERC20(easy).safeSymbol();
        decimals[0] = IBoringERC20(easy).safeDecimals();

        uint256 total = 1000;
        uint256 lpPercent = total - corePercent;

        rewardsPerSec[0] =
            (pool.allocPoint * easyPerSec * lpPercent) /
            totalAllocPoint /
            total;
    }

    // View function to see if user can harvest Easy.
    function canHarvest(
        uint256 _pid,
        address _user
    ) public view validatePoolByPid(_pid) returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return
            block.timestamp >= startTimestamp &&
            block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() external nonReentrant {
        _massUpdatePools();
    }

    // Internal method for massUpdatePools
    function _massUpdatePools() internal {
        for (uint256 pid = 0; pid < poolInfo.length; ++pid) {
            _updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) external nonReentrant {
        _updatePool(_pid);
    }

    function _updatePool(uint256 _pid) internal validatePoolByPid(_pid) {
        // Internal method for _updatePool

        PoolInfo storage pool = poolInfo[_pid];

        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }

        uint256 lpSupply = pool.totalLp;

        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }

        uint256 multiplier = block.timestamp - pool.lastRewardTimestamp;

        uint256 easyReward = ((multiplier * easyPerSec) * pool.allocPoint) /
            totalAllocPoint;

        uint256 total = 1000;
        uint256 lpPercent = total - corePercent - ecosystemPercent;

        if (corePercent > 0) {
            easy.mint(coreAddress, (easyReward * corePercent) / total);
        }

        if (ecosystemPercent > 0) {
            easy.mint(
                ecosystemAddress,
                (easyReward * ecosystemPercent) / total
            );
        }

        easy.mint(address(this), (easyReward * lpPercent) / total);

        pool.accEasyPerShare +=
            (easyReward * ACC_TOKEN_PRECISION * lpPercent) /
            pool.totalLp /
            total;

        pool.lastRewardTimestamp = block.timestamp;

        emit UpdatePool(
            _pid,
            pool.lastRewardTimestamp,
            lpSupply,
            pool.accEasyPerShare
        );
    }

    // Deposit tokens for Easy allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        _deposit(_pid, _amount);
    }

    // Deposit tokens for Easy allocation.
    function _deposit(
        uint256 _pid,
        uint256 _amount
    ) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _updatePool(_pid);

        payOrLockupPendingEasy(_pid);

        if (_amount > 0) {
            uint256 beforeDeposit = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            uint256 afterDeposit = pool.lpToken.balanceOf(address(this));

            _amount = afterDeposit - beforeDeposit;

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (_amount * pool.depositFeeBP) / 10000;
                pool.lpToken.safeTransfer(feeAddress, depositFee);

                _amount = _amount - depositFee;
            }

            user.amount += _amount;

            if (address(pool.lpToken) == address(easy)) {
                totalEasyInPools += _amount;
            }
        }
        user.rewardDebt =
            (user.amount * pool.accEasyPerShare) /
            ACC_TOKEN_PRECISION;

        if (_amount > 0) {
            pool.totalLp += _amount;
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    //withdraw tokens
    function withdraw(
        uint256 _pid,
        uint256 _amount
    ) public nonReentrant validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        //this will make sure that user can only withdraw from his pool
        require(user.amount >= _amount, "withdraw: user amount not enough");

        //cannot withdraw more than pool's balance
        require(pool.totalLp >= _amount, "withdraw: pool total not enough");

        _updatePool(_pid);

        payOrLockupPendingEasy(_pid);

        if (_amount > 0) {
            user.amount -= _amount;
            if (address(pool.lpToken) == address(easy)) {
                totalEasyInPools -= _amount;
            }
            pool.lpToken.safeTransfer(msg.sender, _amount);
        }

        user.rewardDebt =
            (user.amount * pool.accEasyPerShare) /
            ACC_TOKEN_PRECISION;

        if (_amount > 0) {
            pool.totalLp -= _amount;
        }

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;

        //Cannot withdraw more than pool's balance
        require(
            pool.totalLp >= amount,
            "emergency withdraw: pool total not enough"
        );

        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.totalLp -= amount;

        if (address(pool.lpToken) == address(easy)) {
            totalEasyInPools -= amount;
        }

        pool.lpToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending Easy Token
    function payOrLockupPendingEasy(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0 && block.timestamp >= startTimestamp) {
            user.nextHarvestUntil = block.timestamp + pool.harvestInterval;
        }

        if (user.nextHarvestUntil != 0 && pool.harvestInterval == 0) {
            user.nextHarvestUntil = 0;
        }

        uint256 pending = ((user.amount * pool.accEasyPerShare) /
            ACC_TOKEN_PRECISION) - user.rewardDebt;

        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 pendingRewards = pending + user.rewardLockedUp;

                // reset lockup
                totalLockedUpRewards -= user.rewardLockedUp;
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp + pool.harvestInterval;
                uint256 xEasyAmount = (pendingRewards * xEasyTokenRate) / 100;
                if (xEasyAmount > 0) {
                    xEasyToken.convertTo(xEasyAmount, msg.sender);
                }
                safeEasyTransfer(msg.sender, pendingRewards - xEasyAmount);
            }
        } else if (pending > 0) {
            totalLockedUpRewards += pending;
            user.rewardLockedUp += pending;
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    function safeEasyTransfer(address _to, uint256 _amount) internal {
        if (easy.balanceOf(address(this)) > totalEasyInPools) {
            uint256 easyBal = easy.balanceOf(address(this)) - totalEasyInPools;
            if (_amount >= easyBal) {
                easy.safeTransfer(_to, easyBal);
            } else if (_amount > 0) {
                easy.safeTransfer(_to, _amount);
            }
        }
    }

    function updateAllocPoint(
        uint256 _pid,
        uint256 _allocPoint
    ) public onlyOwner {
        _massUpdatePools();

        emit AllocPointsUpdated(
            msg.sender,
            poolInfo[_pid].allocPoint,
            _allocPoint
        );

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function updateEmissionRate(uint256 _easyPerSec) public onlyOwner {
        _massUpdatePools();

        emit EmissionRateUpdated(msg.sender, easyPerSec, _easyPerSec);

        easyPerSec = _easyPerSec;
    }

    function poolTotalLp(uint256 pid) external view returns (uint256) {
        return poolInfo[pid].totalLp;
    }

    // Function to harvest many pools in a single transaction
    function harvestMany(uint256[] calldata _pids) public nonReentrant {
        require(_pids.length <= 30, "harvest many: too many pool ids");
        uint256 length = _pids.length; // gas optimisation
        for (uint256 index = 0; index < length; ) {
            _deposit(_pids[index], 0);
            unchecked {
                ++index; // gas optimisation
            }
        }
    }

    function setCoreAddress(address _coreAddress) public onlyOwner {
        require(_coreAddress != address(0), "invalid new marketing address");
        coreAddress = _coreAddress;
    }

    function setEcosystemAddress(address _ecosystemAddress) public onlyOwner {
        require(_ecosystemAddress != address(0), "invalid new team address");
        ecosystemAddress = _ecosystemAddress;
    }

    function setCorePercent(uint256 _newcorePercent) public onlyOwner {
        require(_newcorePercent <= 500, "invalid percent value");
        _massUpdatePools();
        corePercent = _newcorePercent;
    }

    function setEcosystemPercent(
        uint256 _newecosystemPercent
    ) public onlyOwner {
        require(_newecosystemPercent <= 500, "invalid percent value");
        _massUpdatePools();
        ecosystemPercent = _newecosystemPercent;
    }

    function setFeeAddress(address _feeAddress) public onlyOwner {
        require(_feeAddress != address(0), "wrong address");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function getEasyPerSec() public view returns (uint256) {
        return easyPerSec;
    }

    function setXEasyTokenRate(uint256 _amount) external onlyOwner {
        require(_amount <= 100, "max is 100");
        xEasyTokenRate = _amount;
    }
}
