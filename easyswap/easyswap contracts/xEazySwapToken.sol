// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces//IEasyToken.sol";
import "./interfaces/IXEasyToken.sol";
import "./interfaces/IXEasyTokenUsage.sol";

contract xEazySwapToken is
    Ownable,
    ReentrancyGuard,
    ERC20("xEazySwapToken", "xEAZY"),
    IXEasyToken
{
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IEasyToken;

    struct XEasyerBalance {
        uint256 allocatedAmount; // Amount of xEASY allocated to a Usage
        uint256 redeemingAmount; // Total amount of xEASY currently being redeemed
    }

    struct RedeemInfo {
        uint256 easyAmount; // EASY amount to receive when vesting has ended
        uint256 xEasyerAmount; // xEASY amount to redeem
        uint256 endTime; // end time of redeeming if left for the desired duration
        IXEasyTokenUsage dividendsAddress;
        uint256 dividendsAllocation; // Share of redeeming xEASY to allocate to the Dividends Usage contract
        uint256 startTime; // start time of redeem action
    }

    IEasyToken public immutable easyToken; // EASY token to convert to/from
    IXEasyTokenUsage public dividendsAddress; // Easyerswap dividends contract

    EnumerableSet.AddressSet private _transferWhitelist; // addresses allowed to send/receive xEASY

    mapping(address => mapping(address => uint256)) public usageApprovals; // Usage approvals to allocate xEASY
    mapping(address => mapping(address => uint256))
        public
        override usageAllocations; // Active xEASY allocations to usages

    uint256 public constant MAX_DEALLOCATION_FEE = 200; // 2%
    mapping(address => uint256) public usagesDeallocationFee; // Fee paid when deallocating xEASY

    uint256 public constant MAX_FIXED_RATIO = 1 ether; // 100%

    // Redeeming min/max settings
    uint256 public minRedeemRatio = MAX_FIXED_RATIO / 2; // 1:0.5 precision is 1**18
    uint256 public maxRedeemRatio = MAX_FIXED_RATIO; // 1:1 precision is 1**18
    uint256 public minRedeemDuration = 14 days;
    uint256 public maxRedeemDuration = 180 days;
    // Adjusted dividends rewards for redeeming xEASY
    uint256 public redeemDividendsAdjustment = MAX_FIXED_RATIO / 2; // 50% precision is 1**18

    address internal constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    mapping(address => XEasyerBalance) public xEasyerBalances; // User's xEASY balances
    mapping(address => RedeemInfo[]) public userRedeems; // User's redeeming instances

    constructor(IEasyToken _easyToken) {
        easyToken = _easyToken;
        _transferWhitelist.add(address(this));
    }

    /********************************************/
    /****************** EVENTS ******************/
    /********************************************/

    event ApproveUsage(
        address indexed userAddress,
        address indexed usageAddress,
        uint256 amount
    );
    event Convert(address indexed from, address to, uint256 amount);
    event UpdateRedeemSettings(
        uint256 minRedeemRatio,
        uint256 maxRedeemRatio,
        uint256 minRedeemDuration,
        uint256 maxRedeemDuration,
        uint256 redeemDividendsAdjustment
    );
    event UpdateDividendsAddress(
        address previousDividendsAddress,
        address newDividendsAddress
    );
    event UpdateDeallocationFee(address indexed usageAddress, uint256 fee);
    event SetTransferWhitelist(address account, bool add);
    event Redeem(
        address indexed userAddress,
        uint256 xEasyerAmount,
        uint256 easyAmount,
        uint256 duration
    );
    event FinalizeRedeem(
        address indexed userAddress,
        uint256 xEasyerAmount,
        uint256 easyAmount
    );
    event CancelRedeem(address indexed userAddress, uint256 xEasyerAmount);
    event UpdateRedeemDividendsAddress(
        address indexed userAddress,
        uint256 redeemIndex,
        address previousDividendsAddress,
        address newDividendsAddress
    );
    event Allocate(
        address indexed userAddress,
        address indexed usageAddress,
        uint256 amount
    );
    event Deallocate(
        address indexed userAddress,
        address indexed usageAddress,
        uint256 amount,
        uint256 fee
    );

    /***********************************************/
    /****************** MODIFIERS ******************/
    /***********************************************/

    /*
     * @dev Check if a redeem entry exists
     */
    modifier validateRedeem(address userAddress, uint256 redeemIndex) {
        require(
            redeemIndex < userRedeems[userAddress].length,
            "validateRedeem: redeem entry does not exist"
        );
        _;
    }

    /**************************************************/
    /****************** PUBLIC VIEWS ******************/
    /**************************************************/

    /*
     * @dev Returns user's xEASY balances
     */
    function getXEasyerBalance(
        address userAddress
    ) external view returns (uint256 allocatedAmount, uint256 redeemingAmount) {
        XEasyerBalance storage balance = xEasyerBalances[userAddress];
        return (balance.allocatedAmount, balance.redeemingAmount);
    }

    /*
     * @dev returns redeemable EASY for "amount" of xEASY vested for "duration" seconds
     */
    function getEasyerByVestingDuration(
        uint256 amount,
        uint256 duration
    ) public view returns (uint256) {
        if (duration < minRedeemDuration) {
            return 0;
        }

        // capped to maxRedeemDuration
        if (duration > maxRedeemDuration) {
            return (amount * maxRedeemRatio) / MAX_FIXED_RATIO;
        }

        uint256 ratio = minRedeemRatio +
            ((duration - minRedeemDuration) *
                (maxRedeemRatio - minRedeemRatio)) /
            (maxRedeemDuration - minRedeemDuration);

        return (amount * ratio) / MAX_FIXED_RATIO;
    }

    /**
     * @dev returns quantity of "userAddress" pending redeems
     */
    function getUserRedeemsLength(
        address userAddress
    ) external view returns (uint256) {
        return userRedeems[userAddress].length;
    }

    /**
     * @dev returns "userAddress" info for a pending redeem identified by "redeemIndex"
     */
    function getUserRedeem(
        address userAddress,
        uint256 redeemIndex
    )
        external
        view
        validateRedeem(userAddress, redeemIndex)
        returns (
            uint256 easyAmount,
            uint256 xEasyerAmount,
            uint256 endTime,
            address dividendsContract,
            uint256 dividendsAllocation
        )
    {
        RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
        return (
            _redeem.easyAmount,
            _redeem.xEasyerAmount,
            _redeem.endTime,
            address(_redeem.dividendsAddress),
            _redeem.dividendsAllocation
        );
    }

    /**
     * @dev returns approved xToken to allocate from "userAddress" to "usageAddress"
     */
    function getUsageApproval(
        address userAddress,
        address usageAddress
    ) external view returns (uint256) {
        return usageApprovals[userAddress][usageAddress];
    }

    /**
     * @dev returns allocated xToken from "userAddress" to "usageAddress"
     */
    function getUsageAllocation(
        address userAddress,
        address usageAddress
    ) external view returns (uint256) {
        return usageAllocations[userAddress][usageAddress];
    }

    /**
     * @dev returns length of transferWhitelist array
     */
    function transferWhitelistLength() external view returns (uint256) {
        return _transferWhitelist.length();
    }

    /**
     * @dev returns transferWhitelist array item's address for "index"
     */
    function transferWhitelist(uint256 index) external view returns (address) {
        return _transferWhitelist.at(index);
    }

    /**
     * @dev returns if "account" is allowed to send/receive xEASY
     */
    function isTransferWhitelisted(
        address account
    ) external view override returns (bool) {
        return _transferWhitelist.contains(account);
    }

    /*******************************************************/
    /****************** OWNABLE FUNCTIONS ******************/
    /*******************************************************/

    /**
     * @dev Updates all redeem ratios and durations
     *
     * Must only be called by owner
     */
    function updateRedeemSettings(
        uint256 minRedeemRatio_,
        uint256 maxRedeemRatio_,
        uint256 minRedeemDuration_,
        uint256 maxRedeemDuration_,
        uint256 redeemDividendsAdjustment_
    ) external onlyOwner {
        require(
            minRedeemRatio_ <= maxRedeemRatio_,
            "updateRedeemSettings: wrong ratio values"
        );
        require(
            minRedeemDuration_ < maxRedeemDuration_,
            "updateRedeemSettings: wrong duration values"
        );
        // should never exceed 100%
        require(
            maxRedeemRatio_ <= MAX_FIXED_RATIO &&
                redeemDividendsAdjustment_ <= MAX_FIXED_RATIO,
            "updateRedeemSettings: wrong ratio values"
        );

        minRedeemRatio = minRedeemRatio_;
        maxRedeemRatio = maxRedeemRatio_;
        minRedeemDuration = minRedeemDuration_;
        maxRedeemDuration = maxRedeemDuration_;
        redeemDividendsAdjustment = redeemDividendsAdjustment_;

        emit UpdateRedeemSettings(
            minRedeemRatio_,
            maxRedeemRatio_,
            minRedeemDuration_,
            maxRedeemDuration_,
            redeemDividendsAdjustment_
        );
    }

    /**
     * @dev Updates dividends contract address
     *
     * Must only be called by owner
     */
    function updateDividendsAddress(
        IXEasyTokenUsage dividendsAddress_
    ) external onlyOwner {
        // if set to 0, also set divs earnings while redeeming to 0
        if (address(dividendsAddress_) == address(0)) {
            redeemDividendsAdjustment = 0;
        }

        emit UpdateDividendsAddress(
            address(dividendsAddress),
            address(dividendsAddress_)
        );
        dividendsAddress = dividendsAddress_;
    }

    /**
     * @dev Updates fee paid by users when deallocating from "usageAddress"
     */
    function updateDeallocationFee(
        address usageAddress,
        uint256 fee
    ) external onlyOwner {
        require(fee <= MAX_DEALLOCATION_FEE, "updateDeallocationFee: too high");

        usagesDeallocationFee[usageAddress] = fee;
        emit UpdateDeallocationFee(usageAddress, fee);
    }

    /**
     * @dev Adds or removes addresses from the transferWhitelist
     */
    function updateTransferWhitelist(
        address account,
        bool add
    ) external onlyOwner {
        require(
            account != address(this),
            "updateTransferWhitelist: Cannot remove xToken from whitelist"
        );

        if (add) _transferWhitelist.add(account);
        else _transferWhitelist.remove(account);

        emit SetTransferWhitelist(account, add);
    }

    /*****************************************************************/
    /******************  EXTERNAL PUBLIC FUNCTIONS  ******************/
    /*****************************************************************/

    /**
     * @dev Approves "usage" address to get allocations up to "amount" of xEASY from msg.sender
     */
    function approveUsage(
        IXEasyTokenUsage usage,
        uint256 amount
    ) external nonReentrant {
        require(
            address(usage) != address(0),
            "approveUsage: approve to the zero address"
        );

        usageApprovals[msg.sender][address(usage)] = amount;
        emit ApproveUsage(msg.sender, address(usage), amount);
    }

    /**
     * @dev Convert caller's "amount" of EASY to xEASY
     */
    function convert(uint256 amount) external nonReentrant {
        _convert(amount, msg.sender);
    }

    /**
     * @dev Convert caller's "amount" of EASY to xEASY to "to" address
     */
    function convertTo(
        uint256 amount,
        address to
    ) external override nonReentrant {
        require(address(msg.sender).isContract(), "convertTo: not allowed");
        _convert(amount, to);
    }

    /**
     * @dev Initiates redeem process (xEASY to EASY)
     *
     * Handles dividends' compensation allocation during the vesting process if needed
     */
    function redeem(
        uint256 xEasyerAmount,
        uint256 duration
    ) external nonReentrant {
        require(xEasyerAmount > 0, "redeem: xEasyerAmount cannot be null");
        require(duration >= minRedeemDuration, "redeem: duration too low");

        _transfer(msg.sender, address(this), xEasyerAmount);
        XEasyerBalance storage balance = xEasyerBalances[msg.sender];

        // get corresponding EASY amount
        uint256 easyAmount = getEasyerByVestingDuration(
            xEasyerAmount,
            duration
        );
        emit Redeem(msg.sender, xEasyerAmount, easyAmount, duration);

        // if redeeming is not immediate, go through vesting process
        if (duration > 0) {
            // add to total
            balance.redeemingAmount += xEasyerAmount;

            // handle dividends during the vesting process
            uint256 dividendsAllocation = easyAmount;

            // only if compensation is active
            if (dividendsAllocation > 0) {
                // allocate to dividends
                dividendsAddress.allocate(
                    msg.sender,
                    dividendsAllocation,
                    new bytes(0)
                );
            }

            // add redeeming entry
            userRedeems[msg.sender].push(
                RedeemInfo(
                    easyAmount,
                    xEasyerAmount,
                    _currentBlockTimestamp() + duration,
                    dividendsAddress,
                    dividendsAllocation,
                    _currentBlockTimestamp()
                )
            );
        } else {
            // immediately redeem for EASY
            _finalizeRedeem(msg.sender, xEasyerAmount, easyAmount);
        }
    }

    /**
     * @dev Finalizes redeem process when vesting duration has been reached
     *
     * Can only be called by the redeem entry owner
     */
    function finalizeRedeem(
        uint256 redeemIndex
    ) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        XEasyerBalance storage balance = xEasyerBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
        require(
            _currentBlockTimestamp() >= _redeem.startTime + minRedeemDuration,
            "finalizeRedeem: min duration before redeem"
        );

        // remove from total
        balance.redeemingAmount -= _redeem.xEasyerAmount;

        uint256 duration = _currentBlockTimestamp() - _redeem.startTime;
        uint256 easyAmount = getEasyerByVestingDuration(
            _redeem.xEasyerAmount,
            duration
        );
        _finalizeRedeem(msg.sender, _redeem.xEasyerAmount, easyAmount);

        // handle dividends compensation if any was active
        if (_redeem.dividendsAllocation > 0) {
            // deallocate from dividends
            IXEasyTokenUsage(_redeem.dividendsAddress).deallocate(
                msg.sender,
                _redeem.dividendsAllocation,
                new bytes(0)
            );
        }

        // remove redeem entry
        _deleteRedeemEntry(redeemIndex);
    }

    /**
     * @dev Updates dividends address for an existing active redeeming process
     *
     * Can only be called by the involved user
     * Should only be used if dividends contract was to be migrated
     */
    function updateRedeemDividendsAddress(
        uint256 redeemIndex
    ) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        // only if the active dividends contract is not the same anymore
        if (
            dividendsAddress != _redeem.dividendsAddress &&
            address(dividendsAddress) != address(0)
        ) {
            if (_redeem.dividendsAllocation > 0) {
                // deallocate from old dividends contract
                _redeem.dividendsAddress.deallocate(
                    msg.sender,
                    _redeem.dividendsAllocation,
                    new bytes(0)
                );
                // allocate to new used dividends contract
                dividendsAddress.allocate(
                    msg.sender,
                    _redeem.dividendsAllocation,
                    new bytes(0)
                );
            }

            emit UpdateRedeemDividendsAddress(
                msg.sender,
                redeemIndex,
                address(_redeem.dividendsAddress),
                address(dividendsAddress)
            );
            _redeem.dividendsAddress = dividendsAddress;
        }
    }

    /**
     * @dev Cancels an ongoing redeem entry
     *
     * Can only be called by its owner
     */
    function cancelRedeem(
        uint256 redeemIndex
    ) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        XEasyerBalance storage balance = xEasyerBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        // make redeeming xEASY available again
        balance.redeemingAmount -= _redeem.xEasyerAmount;

        _transfer(address(this), msg.sender, _redeem.xEasyerAmount);

        // handle dividends compensation if any was active
        if (_redeem.dividendsAllocation > 0) {
            // deallocate from dividends
            IXEasyTokenUsage(_redeem.dividendsAddress).deallocate(
                msg.sender,
                _redeem.dividendsAllocation,
                new bytes(0)
            );
        }

        emit CancelRedeem(msg.sender, _redeem.xEasyerAmount);

        // remove redeem entry
        _deleteRedeemEntry(redeemIndex);
    }

    /**
     * @dev Allocates caller's "amount" of available xEASY to "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function allocate(
        address usageAddress,
        uint256 amount,
        bytes calldata usageData
    ) external nonReentrant {
        _allocate(msg.sender, usageAddress, amount);

        // allocates xEASY to usageContract
        IXEasyTokenUsage(usageAddress).allocate(msg.sender, amount, usageData);
    }

    /**
     * @dev Allocates "amount" of available xEASY from "userAddress" to caller (ie usage contract)
     *
     * Caller must have an allocation approval for the required xToken xEASY from "userAddress"
     */
    function allocateFromUsage(
        address userAddress,
        uint256 amount
    ) external override nonReentrant {
        _allocate(userAddress, msg.sender, amount);
    }

    /**
     * @dev Deallocates caller's "amount" of available xEASY from "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function deallocate(
        address usageAddress,
        uint256 amount,
        bytes calldata usageData
    ) external nonReentrant {
        _deallocate(msg.sender, usageAddress, amount);

        // deallocate xEASY into usageContract
        IXEasyTokenUsage(usageAddress).deallocate(
            msg.sender,
            amount,
            usageData
        );
    }

    /**
     * @dev Deallocates "amount" of allocated xEASY belonging to "userAddress" from caller (ie usage contract)
     *
     * Caller can only deallocate xEASY from itself
     */
    function deallocateFromUsage(
        address userAddress,
        uint256 amount
    ) external override nonReentrant {
        _deallocate(userAddress, msg.sender, amount);
    }

    /********************************************************/
    /****************** INTERNAL FUNCTIONS ******************/
    /********************************************************/

    /**
     * @dev Convert caller's "amount" of EASY into xEASY to "to"
     */
    function _convert(uint256 amount, address to) internal {
        require(amount != 0, "convert: amount cannot be null");

        // mint new xEASY
        _mint(to, amount);

        emit Convert(msg.sender, to, amount);
        easyToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Finalizes the redeeming process for "userAddress" by transferring him "easyAmount" and removing "xEasyerAmount" from supply
     *
     * Any vesting check should be ran before calling this
     * EASY excess is automatically burnt
     */
    function _finalizeRedeem(
        address userAddress,
        uint256 xEasyerAmount,
        uint256 easyAmount
    ) internal {
        uint256 easyExcess = xEasyerAmount - easyAmount;

        // sends due EASY tokens
        easyToken.safeTransfer(userAddress, easyAmount);

        // burns EASY excess if any
        if (easyExcess > 0) {
            easyToken.safeTransfer(BURN_ADDRESS, easyExcess);
        }

        _burn(address(this), xEasyerAmount);

        emit FinalizeRedeem(userAddress, xEasyerAmount, easyAmount);
    }

    /**
     * @dev Allocates "userAddress" user's "amount" of available xEASY to "usageAddress" contract
     *
     */
    function _allocate(
        address userAddress,
        address usageAddress,
        uint256 amount
    ) internal {
        require(amount > 0, "allocate: amount cannot be null");

        XEasyerBalance storage balance = xEasyerBalances[userAddress];

        // approval checks if allocation request amount has been approved by userAddress to be allocated to this usageAddress
        uint256 approvedXEasyer = usageApprovals[userAddress][usageAddress];
        require(approvedXEasyer >= amount, "allocate: non authorized amount");

        // remove allocated amount from usage's approved amount
        usageApprovals[userAddress][usageAddress] = approvedXEasyer - amount;

        // update usage's allocatedAmount for userAddress
        usageAllocations[userAddress][usageAddress] =
            usageAllocations[userAddress][usageAddress] +
            amount;

        // adjust user's xEASY balances
        balance.allocatedAmount = balance.allocatedAmount + amount;
        _transfer(userAddress, address(this), amount);

        emit Allocate(userAddress, usageAddress, amount);
    }

    /**
     * @dev Deallocates "amount" of available xEASY to "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function _deallocate(
        address userAddress,
        address usageAddress,
        uint256 amount
    ) internal {
        require(amount > 0, "deallocate: amount cannot be null");

        // check if there is enough allocated xEASY to this usage to deallocate
        uint256 allocatedAmount = usageAllocations[userAddress][usageAddress];
        require(allocatedAmount >= amount, "deallocate: non authorized amount");

        // remove deallocated amount from usage's allocation
        usageAllocations[userAddress][usageAddress] = allocatedAmount - amount;

        uint256 deallocationFeeAmount = (amount *
            usagesDeallocationFee[usageAddress]) / 10000;

        // adjust user's xEASY balances
        XEasyerBalance storage balance = xEasyerBalances[userAddress];
        balance.allocatedAmount -= amount;

        _transfer(address(this), userAddress, amount - deallocationFeeAmount);
        // burn corresponding EASY and XSYNTH
        easyToken.safeTransfer(BURN_ADDRESS, deallocationFeeAmount);
        _burn(address(this), deallocationFeeAmount);

        emit Deallocate(
            userAddress,
            usageAddress,
            amount,
            deallocationFeeAmount
        );
    }

    function _deleteRedeemEntry(uint256 index) internal {
        userRedeems[msg.sender][index] = userRedeems[msg.sender][
            userRedeems[msg.sender].length - 1
        ];
        userRedeems[msg.sender].pop();
    }

    /**
     * @dev Hook override to forbid transfers except from whitelisted addresses and minting
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 /*amount*/
    ) internal view override {
        require(
            from == address(0) ||
                _transferWhitelist.contains(from) ||
                _transferWhitelist.contains(to),
            "transfer: not allowed"
        );
    }

    /**
     * @dev Utility function to get the current block timestamp
     */
    function _currentBlockTimestamp() internal view virtual returns (uint256) {
        /* solhint-disable not-rely-on-time */
        return block.timestamp;
    }
}
