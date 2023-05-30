// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/IDividends.sol";
import "./interfaces/IXEasyTokenUsage.sol";

contract Dividends is Ownable, ReentrancyGuard, IXEasyTokenUsage, IDividends {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserInfo {
        uint256 pendingDividends;
        uint256 rewardDebt;
    }

    struct DividendsInfo {
        uint256 currentDistributionAmount; // total amount to distribute during the current cycle
        uint256 currentCycleDistributedAmount; // amount already distributed for the current cycle (times 1e2)
        uint256 pendingAmount; // total amount in the pending slot, not distributed yet
        uint256 distributedAmount; // total amount that has been distributed since initialization
        uint256 accDividendsPerShare; // accumulated dividends per share (times 1e18)
        uint256 lastUpdateTime; // last time the dividends distribution occurred
        uint256 cycleDividendsPercent; // fixed part of the pending dividends to assign to currentDistributionAmount on every cycle
        bool distributionDisabled; // deactivate a token distribution (for temporary dividends)
    }

    // actively distributed tokens
    EnumerableSet.AddressSet private _distributedTokens;
    uint256 public constant MAX_DISTRIBUTED_TOKENS = 10;

    // dividends info for every dividends token
    mapping(address => DividendsInfo) public dividendsInfo;
    mapping(address => mapping(address => UserInfo)) public users;

    address public immutable xEasyToken; // xEasyToken contract

    mapping(address => uint256) public usersAllocation; // User's xEasy allocation
    uint256 public totalAllocation; // Contract's total xEasy allocation

    uint256 public constant MIN_CYCLE_DIVIDENDS_PERCENT = 1; // 0.01%
    uint256 public constant DEFAULT_CYCLE_DIVIDENDS_PERCENT = 100; // 1%
    uint256 public constant MAX_CYCLE_DIVIDENDS_PERCENT = 10000; // 100%
    // dividends will be added to the currentDistributionAmount on each new cycle
    uint256 internal _cycleDurationSeconds = 7 days;
    uint256 public currentCycleStartTime;

    constructor(address _xEasyToken) {
        require(_xEasyToken != address(0), "zero address");
        xEasyToken = _xEasyToken;
        currentCycleStartTime = block.timestamp + (60 * 60 * 24 * 365);
    }

    /********************************************/
    /****************** EVENTS ******************/
    /********************************************/

    event UserUpdated(
        address indexed user,
        uint256 previousBalance,
        uint256 newBalance
    );
    event DividendsCollected(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event CycleDividendsPercentUpdated(
        address indexed token,
        uint256 previousValue,
        uint256 newValue
    );
    event DividendsAddedToPending(address indexed token, uint256 amount);
    event DistributedTokenDisabled(address indexed token);
    event DistributedTokenRemoved(address indexed token);
    event DistributedTokenEnabled(address indexed token);

    /***********************************************/
    /****************** MODIFIERS ******************/
    /***********************************************/

    /**
     * @dev Checks if an index exists
     */
    modifier validateDistributedTokensIndex(uint256 index) {
        require(
            index < _distributedTokens.length(),
            "validateDistributedTokensIndex: index exists?"
        );
        _;
    }

    /**
     * @dev Checks if token exists
     */
    modifier validateDistributedToken(address token) {
        require(
            _distributedTokens.contains(token),
            "validateDistributedTokens: token does not exists"
        );
        _;
    }

    /**
     * @dev Checks if caller is the xEasyToken contract
     */
    modifier xEasyTokenOnly() {
        require(
            msg.sender == xEasyToken,
            "xEasyTokenOnly: caller should be xEasyToken"
        );
        _;
    }

    /*******************************************/
    /****************** VIEWS ******************/
    /*******************************************/

    function cycleDurationSeconds() external view returns (uint256) {
        return _cycleDurationSeconds;
    }

    /**
     * @dev Returns the number of dividends tokens
     */
    function distributedTokensLength()
        external
        view
        override
        returns (uint256)
    {
        return _distributedTokens.length();
    }

    /**
     * @dev Returns dividends token address from given index
     */
    function distributedToken(
        uint256 index
    )
        external
        view
        override
        validateDistributedTokensIndex(index)
        returns (address)
    {
        return address(_distributedTokens.at(index));
    }

    /**
     * @dev Returns true if given token is a dividends token
     */
    function isDistributedToken(
        address token
    ) external view override returns (bool) {
        return _distributedTokens.contains(token);
    }

    /**
     * @dev Returns time at which the next cycle will start
     */
    function nextCycleStartTime() public view returns (uint256) {
        return currentCycleStartTime + _cycleDurationSeconds;
    }

    /**
     * @dev Returns user's dividends pending amount for a given token
     */
    function pendingDividendsAmount(
        address token,
        address userAddress
    ) external view returns (uint256) {
        if (totalAllocation == 0) {
            return 0;
        }

        DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

        uint256 accDividendsPerShare = dividendsInfo_.accDividendsPerShare;
        uint256 lastUpdateTime = dividendsInfo_.lastUpdateTime;
        uint256 dividendAmountPerSecond_ = _dividendsAmountPerSecond(token);

        // check if the current cycle has changed since last update
        if (_currentBlockTimestamp() > nextCycleStartTime()) {
            // get remaining rewards from last cycle
            accDividendsPerShare +=
                ((nextCycleStartTime() - lastUpdateTime) *
                    dividendAmountPerSecond_ *
                    1e16) /
                totalAllocation;

            lastUpdateTime = nextCycleStartTime();
            dividendAmountPerSecond_ =
                (dividendsInfo_.pendingAmount *
                    dividendsInfo_.cycleDividendsPercent) /
                (100 * _cycleDurationSeconds);
        }

        // get pending rewards from current cycle
        accDividendsPerShare +=
            ((_currentBlockTimestamp() - lastUpdateTime) *
                (dividendAmountPerSecond_ * 1e16)) /
            totalAllocation;

        return
            ((usersAllocation[userAddress] * accDividendsPerShare) / 1e18) -
            users[token][userAddress].rewardDebt +
            users[token][userAddress].pendingDividends;
    }

    /**************************************************/
    /****************** PUBLIC FUNCTIONS **************/
    /**************************************************/

    /**
     * @dev Updates the current cycle start time if previous cycle has ended
     */
    function updateCurrentCycleStartTime() public {
        uint256 nextCycleStartTime_ = nextCycleStartTime();

        if (_currentBlockTimestamp() >= nextCycleStartTime_) {
            currentCycleStartTime = nextCycleStartTime_;
        }
    }

    /**
     * @dev Updates dividends info for a given token
     */
    function updateDividendsInfo(
        address token
    ) external validateDistributedToken(token) {
        _updateDividendsInfo(token);
    }

    /****************************************************************/
    /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
    /****************************************************************/

    /**
     * @dev Updates all dividendsInfo
     */
    function massUpdateDividendsInfo() external {
        uint256 length = _distributedTokens.length();
        for (uint256 index = 0; index < length; ++index) {
            _updateDividendsInfo(_distributedTokens.at(index));
        }
    }

    /**
     * @dev Harvests caller's pending dividends of a given token
     */
    function harvestDividends(address token) external nonReentrant {
        if (!_distributedTokens.contains(token)) {
            require(
                dividendsInfo[token].distributedAmount > 0,
                "harvestDividends: invalid token"
            );
        }

        _harvestDividends(token);
    }

    /**
     * @dev Harvests all caller's pending dividends
     */
    function harvestAllDividends() external nonReentrant {
        uint256 length = _distributedTokens.length();
        for (uint256 index = 0; index < length; ++index) {
            _harvestDividends(_distributedTokens.at(index));
        }
    }

    /**
     * @dev Transfers the given amount of token from caller to pendingAmount
     *
     * Must only be called by a trustable address
     */
    function addDividendsToPending(
        address token,
        uint256 amount
    ) external override nonReentrant {
        uint256 prevTokenBalance = IERC20(token).balanceOf(address(this));
        DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // handle tokens with transfer tax
        uint256 receivedAmount = IERC20(token).balanceOf(address(this)) -
            prevTokenBalance;
        dividendsInfo_.pendingAmount =
            dividendsInfo_.pendingAmount +
            receivedAmount;

        emit DividendsAddedToPending(token, receivedAmount);
    }

    /*****************************************************************/
    /****************** OWNABLE FUNCTIONS  ******************/
    /*****************************************************************/

    /**
     * Allocates "userAddress" user's "amount" of xEasy to this dividends contract
     *
     * Can only be called by xEasyToken contract, which is trusted to verify amounts
     * "data" is only here for compatibility reasons (IXEasyTokenUsage)
     */
    function allocate(
        address userAddress,
        uint256 amount,
        bytes calldata /*data*/
    ) external override nonReentrant xEasyTokenOnly {
        uint256 newUserAllocation = usersAllocation[userAddress] + amount;
        uint256 newTotalAllocation = totalAllocation + amount;
        _updateUser(userAddress, newUserAllocation, newTotalAllocation);
    }

    /**
     * Deallocates "userAddress" user's "amount" of xEasy allocation from this dividends contract
     *
     * Can only be called by xEasyToken contract, which is trusted to verify amounts
     * "data" is only here for compatibility reasons (IXEasyTokenUsage)
     */
    function deallocate(
        address userAddress,
        uint256 amount,
        bytes calldata /*data*/
    ) external override nonReentrant xEasyTokenOnly {
        uint256 newUserAllocation = usersAllocation[userAddress] - amount;
        uint256 newTotalAllocation = totalAllocation - amount;
        _updateUser(userAddress, newUserAllocation, newTotalAllocation);
    }

    /**
     * @dev Enables a given token to be distributed as dividends
     *
     * Effective from the next cycle
     */
    function enableDistributedToken(address token) external onlyOwner {
        DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
        require(
            dividendsInfo_.lastUpdateTime == 0 ||
                dividendsInfo_.distributionDisabled,
            "enableDistributedToken: Already enabled dividends token"
        );
        require(
            _distributedTokens.length() <= MAX_DISTRIBUTED_TOKENS,
            "enableDistributedToken: too many distributedTokens"
        );
        // initialize lastUpdateTime if never set before
        if (dividendsInfo_.lastUpdateTime == 0) {
            dividendsInfo_.lastUpdateTime = _currentBlockTimestamp();
        }
        // initialize cycleDividendsPercent to the minimum if never set before
        if (dividendsInfo_.cycleDividendsPercent == 0) {
            dividendsInfo_
                .cycleDividendsPercent = DEFAULT_CYCLE_DIVIDENDS_PERCENT;
        }
        dividendsInfo_.distributionDisabled = false;
        _distributedTokens.add(token);
        emit DistributedTokenEnabled(token);
    }

    /**
     * @dev Disables distribution of a given token as dividends
     *
     * Effective from the next cycle
     */
    function disableDistributedToken(address token) external onlyOwner {
        DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
        require(
            dividendsInfo_.lastUpdateTime > 0 &&
                !dividendsInfo_.distributionDisabled,
            "disableDistributedToken: Already disabled dividends token"
        );
        dividendsInfo_.distributionDisabled = true;
        emit DistributedTokenDisabled(token);
    }

    /**
     * @dev Updates the percentage of pending dividends that will be distributed during the next cycle
     *
     * Must be a value between MIN_CYCLE_DIVIDENDS_PERCENT and MAX_CYCLE_DIVIDENDS_PERCENT
     */
    function updateCycleDividendsPercent(
        address token,
        uint256 percent
    ) external onlyOwner {
        require(
            percent <= MAX_CYCLE_DIVIDENDS_PERCENT,
            "updateCycleDividendsPercent: percent mustn't exceed maximum"
        );
        require(
            percent >= MIN_CYCLE_DIVIDENDS_PERCENT,
            "updateCycleDividendsPercent: percent mustn't exceed minimum"
        );
        DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
        uint256 previousPercent = dividendsInfo_.cycleDividendsPercent;
        dividendsInfo_.cycleDividendsPercent = percent;
        emit CycleDividendsPercentUpdated(
            token,
            previousPercent,
            dividendsInfo_.cycleDividendsPercent
        );
    }

    function startDistribution() external onlyOwner {
        require(
            block.timestamp < currentCycleStartTime,
            "distribution already started"
        );
        currentCycleStartTime = block.timestamp;
    }

    /**
     * @dev remove an address from _distributedTokens
     *
     * Can only be valid for a disabled dividends token and if the distribution has ended
     */
    function removeTokenFromDistributedTokens(
        address tokenToRemove
    ) external onlyOwner {
        DividendsInfo storage _dividendsInfo = dividendsInfo[tokenToRemove];
        require(
            _dividendsInfo.distributionDisabled &&
                _dividendsInfo.currentDistributionAmount == 0,
            "removeTokenFromDistributedTokens: cannot be removed"
        );
        _distributedTokens.remove(tokenToRemove);
        emit DistributedTokenRemoved(tokenToRemove);
    }

    /********************************************************/
    /****************** INTERNAL FUNCTIONS ******************/
    /********************************************************/

    /**
     * @dev Returns the amount of dividends token distributed every second (times 1e2)
     */
    function _dividendsAmountPerSecond(
        address token
    ) internal view returns (uint256) {
        if (!_distributedTokens.contains(token)) return 0;

        return
            (dividendsInfo[token].currentDistributionAmount * 1e2) /
            _cycleDurationSeconds;
    }

    /**
     * @dev Updates every user's rewards allocation for each distributed token
     */
    function _updateDividendsInfo(address token) internal {
        uint256 currentBlockTimestamp = _currentBlockTimestamp();
        DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

        updateCurrentCycleStartTime();

        uint256 lastUpdateTime = dividendsInfo_.lastUpdateTime;
        uint256 accDividendsPerShare = dividendsInfo_.accDividendsPerShare;
        if (currentBlockTimestamp <= lastUpdateTime) {
            return;
        }

        // if no xEasy is allocated or initial distribution has not started yet
        if (
            totalAllocation == 0 ||
            currentBlockTimestamp < currentCycleStartTime
        ) {
            dividendsInfo_.lastUpdateTime = currentBlockTimestamp;
            return;
        }

        uint256 currentDistributionAmount = dividendsInfo_
            .currentDistributionAmount; // gas saving
        uint256 currentCycleDistributedAmount = dividendsInfo_
            .currentCycleDistributedAmount; // gas saving

        // check if the current cycle has changed since last update
        if (lastUpdateTime < currentCycleStartTime) {
            // update accDividendPerShare for the end of the previous cycle
            accDividendsPerShare =
                accDividendsPerShare +
                (((currentDistributionAmount * 1e2) -
                    currentCycleDistributedAmount) * 1e16) /
                totalAllocation;

            // check if distribution is enabled
            if (!dividendsInfo_.distributionDisabled) {
                // transfer the token's cycleDividendsPercent part from the pending slot to the distribution slot
                dividendsInfo_.distributedAmount =
                    dividendsInfo_.distributedAmount +
                    currentDistributionAmount;

                uint256 pendingAmount = dividendsInfo_.pendingAmount;
                currentDistributionAmount =
                    (pendingAmount * dividendsInfo_.cycleDividendsPercent) /
                    10000;

                dividendsInfo_
                    .currentDistributionAmount = currentDistributionAmount;
                dividendsInfo_.pendingAmount =
                    pendingAmount -
                    currentDistributionAmount;
            } else {
                // stop the token's distribution on next cycle
                dividendsInfo_.distributedAmount =
                    dividendsInfo_.distributedAmount +
                    currentDistributionAmount;
                currentDistributionAmount = 0;
                dividendsInfo_.currentDistributionAmount = 0;
            }

            currentCycleDistributedAmount = 0;
            lastUpdateTime = currentCycleStartTime;
        }
        uint256 toDistribute = (currentBlockTimestamp - lastUpdateTime) *
            _dividendsAmountPerSecond(token);

        // ensure that we can't distribute more than currentDistributionAmount (for instance w/ a > 24h service interruption)
        if (
            currentCycleDistributedAmount + toDistribute >
            currentDistributionAmount * 1e2
        ) {
            toDistribute =
                (currentDistributionAmount * 1e2) -
                currentCycleDistributedAmount;
        }

        dividendsInfo_.currentCycleDistributedAmount =
            currentCycleDistributedAmount +
            toDistribute;

        dividendsInfo_.accDividendsPerShare =
            accDividendsPerShare +
            ((toDistribute * 1e16) / totalAllocation);

        dividendsInfo_.lastUpdateTime = currentBlockTimestamp;
    }

    /**
     * Updates "userAddress" user's and total allocations for each distributed token
     */
    function _updateUser(
        address userAddress,
        uint256 newUserAllocation,
        uint256 newTotalAllocation
    ) internal {
        uint256 previousUserAllocation = usersAllocation[userAddress];

        // for each distributedToken
        uint256 length = _distributedTokens.length();
        for (uint256 index = 0; index < length; ++index) {
            address token = _distributedTokens.at(index);
            _updateDividendsInfo(token);

            UserInfo storage user = users[token][userAddress];
            uint256 accDividendsPerShare = dividendsInfo[token]
                .accDividendsPerShare;

            uint256 pending = ((previousUserAllocation * accDividendsPerShare) /
                1e18) - user.rewardDebt;
            user.pendingDividends = user.pendingDividends + pending;
            user.rewardDebt = (newUserAllocation * accDividendsPerShare) / 1e18;
        }

        usersAllocation[userAddress] = newUserAllocation;
        totalAllocation = newTotalAllocation;

        emit UserUpdated(
            userAddress,
            previousUserAllocation,
            newUserAllocation
        );
    }

    /**
     * @dev Harvests msg.sender's pending dividends of a given token
     */
    function _harvestDividends(address token) internal {
        _updateDividendsInfo(token);

        UserInfo storage user = users[token][msg.sender];
        uint256 accDividendsPerShare = dividendsInfo[token]
            .accDividendsPerShare;

        uint256 userxEasyAllocation = usersAllocation[msg.sender];
        uint256 pending = user.pendingDividends +
            (
                (((userxEasyAllocation * accDividendsPerShare) / 1e18) -
                    user.rewardDebt)
            );

        user.pendingDividends = 0;
        user.rewardDebt = (userxEasyAllocation * accDividendsPerShare) / 1e18;

        _safeTokenTransfer(IERC20(token), msg.sender, pending);
        emit DividendsCollected(msg.sender, token, pending);
    }

    /**
     * @dev Safe token transfer function, in case rounding error causes pool to not have enough tokens
     */
    function _safeTokenTransfer(
        IERC20 token,
        address to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            uint256 tokenBal = token.balanceOf(address(this));
            if (amount > tokenBal) {
                token.safeTransfer(to, tokenBal);
            } else {
                token.safeTransfer(to, amount);
            }
        }
    }

    /**
     * @dev Utility function to get the current block timestamp
     */
    function _currentBlockTimestamp() internal view virtual returns (uint256) {
        /* solhint-disable not-rely-on-time */
        return block.timestamp;
    }
}
