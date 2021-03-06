// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import "./utility/Whitelist.sol";
import "./utility/Lockable.sol";

contract Reward is Ownable, Lockable, Whitelist {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Tamgs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTamgPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTamgPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Tamgs to distribute per block.
        uint256 lastRewardBlock; // Last block number that Tamgs distribution occurs.
        uint256 accTamgPerShare; // Accumulated Tamgs per share, times 1e12. See below.
    }

    // The Tamg TOKEN!
    IERC20 public tamg; 
    // Tamg tokens created per block.
    uint256 public tamgPerBlock;
    // Bonus muliplier for early tamg makers.
    uint256 public BONUS_MULTIPLIER = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Tamg mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        IERC20 _tamg,
        uint256 _tamgPerBlock,
        uint256 _startBlock,
        address _adminAddress
    ) public nonReentrant() {
        tamg = _tamg;
        tamgPerBlock = _tamgPerBlock;
        startBlock = _startBlock;

        addAddress(_adminAddress);
        
        if (_adminAddress != msg.sender) {
            addAddress(msg.sender);
        }
    }

    // ONLY ADMIN

    /**
     * @notice Add a new lp to the pool. Can only be called by the owner.
     * @dev DO NOT add the same LP token more than once. Rewards will be messed up if you do.
     */

    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public  onlyWhitelisted() nonReentrant() {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accTamgPerShare: 0
            })
        );
    }

    // Update the given pool's Tamg allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public  onlyWhitelisted() nonReentrant() {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function updateMultiplier(uint256 _multiplierNumber) public onlyWhitelisted nonReentrant() {
        require( _multiplierNumber != 0, "Invalid value" );
        BONUS_MULTIPLIER = _multiplierNumber;
    }

    function updateTamgPerBlock(uint256 _tamgPerBlock) public onlyWhitelisted nonReentrant() {
        require( _tamgPerBlock != 0, "Invalid value" );
        tamgPerBlock = _tamgPerBlock;
    }

    function addTamg(uint256 _amount) public onlyWhitelisted nonReentrant() {
        require( _amount != 0, "Invalid amount" );

        tamg.safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
    }

    function removeTamg(uint256 _amount) public onlyWhitelisted nonReentrant() {
        require( _amount != 0, "Invalid amount" );
        require( tamg.balanceOf( address(this) ) >= _amount , "Insufficent balance"  );

        tamg.safeTransfer(msg.sender, _amount);
    }

    // PUBLIC

    // total pool in the system
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending Tamgs on frontend.
    function pendingTamg(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTamgPerShare = pool.accTamgPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tamgReward =
                multiplier.mul(tamgPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accTamgPerShare = accTamgPerShare.add(
                tamgReward.mul(1e12).div(lpSupply)
            );
        }
        return
            user.amount.mul(accTamgPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tamgReward =
            multiplier.mul(tamgPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );
        pool.accTamgPerShare = pool.accTamgPerShare.add(
            tamgReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for Tamg allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accTamgPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            safeTamgTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accTamgPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accTamgPerShare).div(1e12).sub(
                user.rewardDebt
            );
        safeTamgTransfer(msg.sender, pending);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
    	    pool.lpToken.safeTransfer(address(msg.sender), _amount);       
        }
        user.rewardDebt = user.amount.mul(pool.accTamgPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
    }


    // INTERNAL

    // Safe tamg transfer function, just in case if rounding error causes pool to not have enough Tamgs.
    function safeTamgTransfer(address _to, uint256 _amount) internal {
        uint256 tamgBal = tamg.balanceOf(address(this));
		if (_amount > tamgBal) {
		tamg.safeTransfer(_to, tamgBal);
		} else {
		tamg.safeTransfer(_to, _amount);
		}
    }
}