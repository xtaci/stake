// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "interfaces/iface.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";


contract RockXStaking is Initializable, PausableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address payable;
    using Address for address;

    // stored credentials
    struct ValidatorCredential {
        bytes pubkey;
        bytes signature;
        bool stopped;
    }
    
    // track ether debts to return to async caller
    struct Debt {
        address account;
        uint256 amount;
    }

    /**
        Incorrect storage preservation:

        |Implementation_v0   |Implementation_v1        |
        |--------------------|-------------------------|
        |address _owner      |address _lastContributor | <=== Storage collision!
        |mapping _balances   |address _owner           |
        |uint256 _supply     |mapping _balances        |
        |...                 |uint256 _supply          |
        |                    |...                      |
        Correct storage preservation:

        |Implementation_v0   |Implementation_v1        |
        |--------------------|-------------------------|
        |address _owner      |address _owner           |
        |mapping _balances   |mapping _balances        |
        |uint256 _supply     |uint256 _supply          |
        |...                 |address _lastContributor | <=== Storage extension.
        |                    |...                      |
    */

    // Always extend storage instead of modifying it
    // Variables in implementation v0 
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 private constant MULTIPLIER = 1e18; 
    uint256 private constant DEPOSIT_AMOUNT_UNIT = 1000000000 wei;
    uint256 private constant SIGNATURE_LENGTH = 96;
    uint256 private constant PUBKEY_LENGTH = 48;
    
    uint256 private DEPOSIT_SIZE; 			// deposit_size adjustable via func
    address public ethDepositContract;      // ETH 2.0 Deposit contract
    address public xETHAddress;             // xETH token address
    address public debtContract;            // debt contract for user to pull ethers

    uint256 public managerFeeShare;         // manager's fee in 1/1000
    bytes32 public withdrawalCredentials;   // WithdrawCredential for all validator
    
    // credentials, pushed by owner
    ValidatorCredential [] private validatorRegistry;
    mapping(bytes32 => bool) private pubkeyIndices;

    // next validator id
    uint256 private nextValidatorId;

    // exchange ratio related variables
    // track user deposits & redeem (xETH mint & burn)
    // based on the variables following, the total ether balance is equal to 
    // currentEthers := accDeposited - accWithdrawed + accountedUserRevenue - currentDebts [1]
    uint256 private accDeposited;           // track accumulated deposited ethers from users
    uint256 private accWithdrawed;          // track accumulated withdrawed ethers from users
    uint256 private accStaked;              // track accumulated staked ethers for validators, rounded to 32 ethers

    uint256 private currentDebts;           // track current unpaid debts
    uint256 private swapPool;               // track swappable ethers for redeem()/redeemUnderlying()

    // FIFO of debts from redeemFromValidators
    mapping(uint256=>Debt) private etherDebts;
    uint256 private firstDebt;
    uint256 private lastDebt;
    mapping(address=>uint256) private userDebts;    // debts from user's perspective

    // track revenue from validators to form exchange ratio
    uint256 private accountedUserRevenue;    // accounted shared user revenue
    uint256 private accountedManagerRevenue; // accounted manager's revenue

    // revenue related variables
    // track beacon validator & balance
    uint256 private accValidators;
    uint256 private accValidatorBalance;

    // track stopped validators
    uint256 private accStoppedBalance;      // track accumulated balance of stopped validators
    uint256 private lastStopTimestamp;      // record timestamp of last stop
    bytes [] private stoppedValidators;     // track stopped validator pubkey

    // phase switch from 0 to 1
    uint256 private phase;

    /** 
     * ======================================================================================
     * 
     * SYSTEM SETTINGS, OPERATED VIA OWNER(DAO/TIMELOCK)
     * 
     * ======================================================================================
     */

    /**
     * @dev only phase
     */
    modifier onlyPhase(uint256 requiredPhase) {
        require(phase >= requiredPhase, "PHASE_MISMATCH");
        _;
    }

    /**
     * @dev pause the contract
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev unpause the contract
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev initialization address
     */
    function initialize() initializer public {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        // init default values
        managerFeeShare = 100;
        firstDebt = 1;
        lastDebt = 0;
        phase = 0;
        DEPOSIT_SIZE = 32 ether;
    }

    /**
     * @dev adjust deposit_size
     */
    function setDepositSize(uint256 depositSize) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(depositSize > 0, "INVALID_DEPOSIT_SIZE");
        DEPOSIT_SIZE = depositSize;
    }

    /**
     * @dev phase switch
     */
    function switchPhase(uint256 newPhase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require (newPhase >= phase, "PHASE_ROLLBACK");
        phase = newPhase;
    }

    /**
     * @dev register a validator
     */
    function registerValidator(bytes calldata pubkey, bytes calldata signature) external onlyRole(OPERATOR_ROLE) {
        require(signature.length == SIGNATURE_LENGTH, "INCONSISTENT_SIG_LEN");
        require(pubkey.length == PUBKEY_LENGTH, "INCONSISTENT_PUBKEY_LEN");

        bytes32 pubkeyHash = keccak256(pubkey);
        require(!pubkeyIndices[pubkeyHash], "DUPLICATED_PUBKEY");
        validatorRegistry.push(ValidatorCredential({pubkey:pubkey, signature:signature, stopped:false}));
        pubkeyIndices[pubkeyHash] = true;
    }

    /**
     * @dev replace a validator in case of msitakes
     */
    function replaceValidator(uint256 index, bytes calldata pubkey, bytes calldata signature) external onlyRole(OPERATOR_ROLE) {
        require(index < validatorRegistry.length, "OUT_OF_RANGE");
        require(index < nextValidatorId, "ALREADY_ACTIVATED");
        require(pubkey.length == PUBKEY_LENGTH, "INCONSISTENT_PUBKEY_LEN");
        require(signature.length == SIGNATURE_LENGTH, "INCONSISTENT_SIG_LEN");

        // mark old pub key to false
        bytes32 oldPubKeyHash = keccak256(validatorRegistry[index].pubkey);
        pubkeyIndices[oldPubKeyHash] = false;

        // set new pubkey
        bytes32 pubkeyHash = keccak256(pubkey);
        require(!pubkeyIndices[pubkeyHash], "DUPLICATED_PUBKEY");
        validatorRegistry[index] = ValidatorCredential({pubkey:pubkey, signature:signature, stopped:false});
        pubkeyIndices[pubkeyHash] = true;
    }

    /**
     * @dev register a batch of validators
     */
    function registerValidators(bytes [] calldata pubkeys, bytes [] calldata signatures) external onlyRole(OPERATOR_ROLE) {
        require(pubkeys.length == signatures.length, "LENGTH_NOT_EQUAL");
        uint256 n = pubkeys.length;
        for(uint256 i=0;i<n;i++) {
            require(pubkeys[i].length == PUBKEY_LENGTH, "INCONSISTENT_PUBKEY_LEN");
            require(signatures[i].length == SIGNATURE_LENGTH, "INCONSISTENT_SIG_LEN");
            bytes32 pubkeyHash = keccak256(pubkeys[i]);
            require(!pubkeyIndices[pubkeyHash], "DUPLICATED_PUBKEY");
            validatorRegistry.push(ValidatorCredential({pubkey:pubkeys[i], signature:signatures[i], stopped:false}));
            pubkeyIndices[pubkeyHash] = true;
        }
    }
    
    /**
     * @dev set manager's fee in 1/1000
     */
    function setManagerFeeShare(uint256 milli) external onlyRole(DEFAULT_ADMIN_ROLE)  {
        require(milli >=0 && milli <=1000, "OUT_OF_RANGE");
        managerFeeShare = milli;

        emit ManagerFeeSet(milli);
    }


    /**
     * @dev set xETH token contract address
     */
    function setXETHContractAddress(address _xETHContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        xETHAddress = _xETHContract;

        emit XETHContractSet(_xETHContract);
    }

    /**
     * @dev set eth deposit contract address
     */
    function setETHDepositContract(address _ethDepositContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ethDepositContract = _ethDepositContract;

        emit DepositContractSet(_ethDepositContract);
    }

    /**
     * @dev set debt contract
     */
    function setDebtContract(address _debtContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        debtContract = _debtContract;

        emit DebtContractSet(_debtContract);
    }


    /**
     @dev set withdraw credential to receive revenue, usually this should be the contract itself.
     */
    function setWithdrawCredential(bytes32 withdrawalCredentials_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawalCredentials = withdrawalCredentials_;
        emit WithdrawCredentialSet(withdrawalCredentials);
    } 

    /**
     * @dev manager withdraw fees
     */
    function withdrawManagerFee(uint256 amount, address to) external nonReentrant onlyRole(MANAGER_ROLE)  {
        require(accountedManagerRevenue >= amount, "INSUFFICIENT_MANAGER_FEE");
        require(swapPool >= amount, "INSUFFICIENT_ETHERS");
        accountedManagerRevenue -= amount;
        payable(to).sendValue(amount);
        swapPool -= amount;

        emit ManagerFeeWithdrawed(amount, to);
    }

    /**
     * @dev report validators count and total balance
     */
    function pushBeacon(uint256 _aliveValidators, uint256 _aliveBalance, uint256 ts) external onlyRole(ORACLE_ROLE) {
        require(_aliveValidators + stoppedValidators.length <= nextValidatorId, "REPORTED_MORE_DEPOSITED");
        require(_aliveValidators + stoppedValidators.length >= accValidators, "REPORTED_DECREASING_VALIDATORS");
        require(_aliveBalance >= _aliveValidators * DEPOSIT_SIZE, "REPORTED_LESS_VALUE");
        //require(block.timestamp >= ts, "REPORTED_CLOCK_DRIFT");
        require(ts > lastStopTimestamp, "REPORTED_EXPIRED_TIMESTAMP");

        // step 1. check if new validator launched
        // and adjust rewardBase to include the new validators value
        uint256 rewardBase = accValidatorBalance;
        if (_aliveValidators + stoppedValidators.length > accValidators) {         
            // newly appeared validators
            uint256 newValidators = _aliveValidators + stoppedValidators.length - accValidators;
            rewardBase += newValidators * DEPOSIT_SIZE;
        }

        // step 2. update accValidators
        // take snapshot of current balances & validators,including stopped ones
        accValidatorBalance = _aliveBalance + accStoppedBalance; 
        accValidators = _aliveValidators + stoppedValidators.length;

        // step 3. calc rewards
        // the actual increase in balance is the reward
        if (accValidatorBalance > rewardBase) {
            uint256 rewards = accValidatorBalance - rewardBase;
            _distributeRewards(rewards);
        }
    }

    /**
     * @dev operator stops validator and return ethers staked along with revenue;
     * the overall balance will be stored in this contract
     */
    function validatorStopped(uint256 [] calldata stoppedIDs) external payable nonReentrant onlyRole(OPERATOR_ROLE) {
        require(stoppedIDs.length > 0, "EMPTY_CALLDATA");
        require(stoppedIDs.length + stoppedValidators.length <= nextValidatorId, "REPORTED_MORE_STOPPED_VALIDATORS");
        require(msg.value >= stoppedIDs.length * DEPOSIT_SIZE, "RETURNED_LESS_ETHERS"); 

        // record stopped validators snapshot.
        for (uint i=0;i<stoppedIDs.length;i++) {
            require(stoppedIDs[i] < nextValidatorId, "ID_OUT_OF_RANGE");
            require(!validatorRegistry[stoppedIDs[i]].stopped, "ID_ALREADY_STOPPED");

            validatorRegistry[stoppedIDs[i]].stopped = true;
            stoppedValidators.push(validatorRegistry[stoppedIDs[i]].pubkey);
        }
        accStoppedBalance += msg.value;
        
        // record timestamp to avoid expired pushBeacon transaction
        lastStopTimestamp = block.timestamp;

        // pay debt
        uint256 paied = _payDebts(msg.value);

        // the remaining ethers are aggregated to swap pool
        swapPool += msg.value - paied;

        // log
        emit ValidatorStopped(stoppedIDs);
    }

    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */

    /**
     * @dev returns current reserve of ethers
     */
    function currentReserve() public view returns(uint256) {
        return accDeposited - accWithdrawed + accountedUserRevenue - currentDebts;
    }

    /**
     * @dev return accumulated deposited ethers
     */
    function getAccumulatedDeposited() external view returns (uint256) { return  accDeposited; }

    /**
     * @dev return accumulated withdrawed ethers
     */
    function getAccumulatedWithdrawed() external view returns (uint256) { return  accWithdrawed; }

    /**
     * @dev return accumulated staked ethers
     */
    function getAccumulatedStaked() external view returns (uint256) { return  accStaked; }

    /**
     * @dev return current debts
     */
    function getCurrentDebts() external view returns (uint256) { return currentDebts; }
    
    /**
     * @dev return the amount of ethers that could be swapped instantly
     */
    function getSwapPool() external view returns (uint256) { return swapPool; }

    /**
     * @dev returns the accounted user revenue
     */
    function getAccountedUserRevenue() external view returns (uint256) { return accountedUserRevenue; }

    /**
     * @dev returns the accounted manager's revenue
     */
    function getAccountedManagerRevenue() external view returns (uint256) { return accountedManagerRevenue; }

    /*
     * @dev returns accumulated beacon validators
     */
    function getAccumulatedValidators() external view returns (uint256) { return accValidators; }

    /*
     * @dev returns accumulated balance snapshot
     */
    function getAccumulatedValidatorBalance() external view returns (uint256) { return accValidatorBalance; }

    /*
     * @dev returns accumulated balance of stopped validators
     */
    function getAccumulatedStoppedBalance() external view returns (uint256) { return accStoppedBalance; }

    /**
     * @dev return debt for an account
     */
    function debtOf(address account) external view returns (uint256) {
        return userDebts[account];
    }

    /**
     * @dev return number of registered validator
     */
    function getRegisteredValidatorsCount() external view returns (uint256) {
        return validatorRegistry.length;
    }
    
    /**
     * @dev return a batch of validators credential
     */
    function getRegisteredValidators(uint256 idx_from, uint256 idx_to) external view returns (bytes [] memory pubkeys, bytes [] memory signatures) {
        pubkeys = new bytes[](idx_to - idx_from);
        signatures = new bytes[](idx_to - idx_from);

        uint counter = 0;
        for (uint i = idx_from; i < idx_to;i++) {
            pubkeys[counter] = validatorRegistry[i].pubkey;
            signatures[counter] = validatorRegistry[i].signature;
            counter++;
        }
    }

    /**
     * @dev return next validator id
     */
    function getNextValidatorId() external view returns (uint256) {
        return nextValidatorId;
    }

    /**
     * @dev return exchange ratio of xETH:ETH, multiplied by 1e18
     */
    function exchangeRatio() external view returns (uint256) {
        uint256 xETHAmount = IERC20(xETHAddress).totalSupply();
        if (xETHAmount == 0) {
            return 1 * MULTIPLIER;
        }

        uint256 ratio = currentReserve() * MULTIPLIER / xETHAmount;
        return ratio;
    }

    /**
     * @dev return debt of index
     */
    function checkDebt(uint256 index) external view returns (address account, uint256 amount) {
        Debt memory debt = etherDebts[index];
        return (debt.account, debt.amount);
    }
    /**
     * @dev return debt queue index
     */
    function getDebtQueue() external view returns (uint256 first, uint256 last) {
        return (firstDebt, lastDebt);
    }

    /**
     * @dev get stopped validators count
     */
    function getStoppedValidatorsCount() external view returns (uint256) {
        return stoppedValidators.length;
    }
    
    /**
     * @dev get stopped validators ID range
     */
    function getStoppedValidators(uint256 idx_from, uint256 idx_to) external view returns (bytes[] memory) {
        bytes[] memory result = new bytes[](idx_to - idx_from);
        uint counter = 0;
        for (uint i = idx_from; i < idx_to;i++) {
            result[counter] = stoppedValidators[i];
            counter++;
        }
        return result;
    }

    /**
     * ======================================================================================
     * 
     * EXTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    /**
     * @dev mint xETH with ETH
     */
    function mint(uint256 minToMint) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "MINT_ZERO");

        // mint xETH while keep the exchange ratio invariant
        //
        // reserve := accDeposited - accWithdrawed + accountedUserRevenue - currentDebts
        // amount XETH to mint = xETH * (msg.value/reserve)
        //
        // For every user operation related to ETH, xETH is minted or burned, so the swap ratio is bounded to:
        // (TotalDeposited - TotalWithdrawed + Validator Revenue - Total Ether Debts) / total xETH supply
        // 
        // 
        uint256 amountXETH = IERC20(xETHAddress).totalSupply();
        uint256 currentEthers = currentReserve();
        uint256 toMint = msg.value;  // default exchange ratio 1:1
        require(toMint >= minToMint, "EXCEEDED_SLIPPAGE");

        if (currentEthers > 0) { // avert division overflow
            toMint = amountXETH * msg.value / currentEthers;
        }
        // mint xETH
        IMintableContract(xETHAddress).mint(msg.sender, toMint);

        // pay debts in priority
        uint256 debtPaied = _payDebts(msg.value);
        accDeposited += msg.value - debtPaied; 

        // spin up n nodes
        uint256 numValidators = (accDeposited - accStaked) / DEPOSIT_SIZE;
        for (uint256 i = 0;i<numValidators;i++) {
            _spinup();
        }
    }

    /**
     * @dev redeem N * 32Ethers, which will turn off validadators,
     * note this function is asynchronous, the caller will only receive his ethers
     * after the validator has turned off.
     *
     * this function is dedicated for institutional operations.
     * 
     * redeem keeps the ratio invariant
     */
    function redeemFromValidators(uint256 ethersToRedeem, uint256 maxToBurn) external nonReentrant onlyPhase(1) {
        require(ethersToRedeem % DEPOSIT_SIZE == 0, "REDEEM_NOT_IN_32ETHERS");

        uint256 totalXETH = IERC20(xETHAddress).totalSupply();
        uint256 xETHToBurn = totalXETH * ethersToRedeem / currentReserve();
        require(xETHToBurn <= maxToBurn, "EXCEEDED_SLIPPAGE");
        
        // transfer xETH from sender & burn
        IERC20(xETHAddress).safeTransferFrom(msg.sender, address(this), xETHToBurn);
        IMintableContract(xETHAddress).burn(xETHToBurn);

        // pay debts from swap pool at first
        uint256 paid = _payDebts(swapPool);
        swapPool -= paid;

        // check if there is debt remaining
        uint256 debt = ethersToRedeem - paid;
        if (debt > 0) {
            // track ether debts
            _enqueueDebt(msg.sender, debt);
            userDebts[msg.sender] += debt;

            // total debts increased
            currentDebts += debt;

            // log
            emit DebtQueued(msg.sender, debt);
        }
    }

    /**
     * @dev redeem ETH by burning xETH with current exchange ratio, 
     * approve xETH to this contract first.
     *
     * amount xETH to burn:
     *      xETH * ethers_to_redeem/current_ethers
     *
     * redeem keeps the ratio invariant
     */
    function redeemUnderlying(uint256 ethersToRedeem, uint256 maxToBurn) external nonReentrant {
        require(swapPool >= ethersToRedeem, "INSUFFICIENT_ETHERS");

        uint256 totalXETH = IERC20(xETHAddress).totalSupply();
        uint256 xETHToBurn = totalXETH * ethersToRedeem / currentReserve();
        require(xETHToBurn <= maxToBurn, "EXCEEDED_SLIPPAGE");

        // transfer xETH from sender & burn
        IERC20(xETHAddress).safeTransferFrom(msg.sender, address(this), xETHToBurn);
        IMintableContract(xETHAddress).burn(xETHToBurn);

        // send ethers back to sender
        payable(msg.sender).sendValue(ethersToRedeem);
        swapPool -= ethersToRedeem;

        // record withdrawed ethers
        accWithdrawed += ethersToRedeem;

        // emit amount withdrawed
        emit Redeemed(xETHToBurn, ethersToRedeem);
    }

    /**
     * @dev redeem ETH by burning xETH with current exchange ratio, 
     * approve xETH to this contract first.
     * 
     * amount ethers to return:
     *  current_ethers * xETHToBurn/ xETH
     *
     * redeem keeps the ratio invariant
     */
    function redeem(uint256 xETHToBurn, uint256 minToRedeem) external nonReentrant {
        uint256 totalXETH = IERC20(xETHAddress).totalSupply();
        uint256 ethersToRedeem = currentReserve() * xETHToBurn / totalXETH;
        require(swapPool >= ethersToRedeem, "INSUFFICIENT_ETHERS");
        require(ethersToRedeem >= minToRedeem, "EXCEEDED_SLIPPAGE");

        // transfer xETH from sender & burn
        IERC20(xETHAddress).safeTransferFrom(msg.sender, address(this), xETHToBurn);
        IMintableContract(xETHAddress).burn(xETHToBurn);

        // send ethers back to sender
        payable(msg.sender).sendValue(ethersToRedeem);
        swapPool -= ethersToRedeem;

        // record withdrawed ethers
        accWithdrawed += ethersToRedeem;

        // emit amount withdrawed
        emit Redeemed(xETHToBurn, ethersToRedeem);
    }

    /** 
     * ======================================================================================
     * 
     * INTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    function _enqueueDebt(address account, uint256 amount) internal {
        lastDebt += 1;
        etherDebts[lastDebt] = Debt({account:account, amount:amount});
    }

    function _dequeueDebt() internal returns (Debt memory debt) {
        require(lastDebt >= firstDebt);  // non-empty queue
        debt = etherDebts[firstDebt];
        delete etherDebts[firstDebt];
        firstDebt += 1;
    }

    /**
     * @dev pay debts for a given amount
     */
    function _payDebts(uint256 total) internal returns(uint256 amountPaied) {
        require(address(debtContract) != address(0x0), "DEBT_CONTRACT_NOT_SET");

        // ethers to pay
        for (uint i=firstDebt;i<=lastDebt;i++) {
            if (total == 0) {
                break;
            }

            Debt storage debt = etherDebts[i];

            // clean debts
            uint256 toPay = debt.amount <= total? debt.amount:total;
            debt.amount -= toPay;
            total -= toPay;
            userDebts[debt.account] -= toPay;
            amountPaied += toPay;

            // transfer money to debt contract
            IRockXDebts(debtContract).pay{value:toPay}(debt.account);

            // dequeue if cleared 
            if (debt.amount == 0) {
                _dequeueDebt();
            }
        }
        
        currentDebts -= amountPaied;
        accWithdrawed += amountPaied;
    }

    /**
     * @dev distribute revenue
     */
    function _distributeRewards(uint256 rewards) internal {
        // rewards distribution
        uint256 fee = rewards * managerFeeShare / 1000;
        accountedManagerRevenue += fee;
        accountedUserRevenue += rewards - fee;
        emit RevenueAccounted(rewards);
    }

    /**
     * @dev spin up the node
     */
    function _spinup() internal {
        // emit a log
        emit ValidatorActivated(nextValidatorId);

        // deposit to ethereum contract
        require(nextValidatorId < validatorRegistry.length, "REGISTRY_VALIDATORS_DEPLETED");

         // load credential
        ValidatorCredential memory cred = validatorRegistry[nextValidatorId];
        _stake(cred.pubkey, cred.signature);

        accStaked += DEPOSIT_SIZE;
        nextValidatorId++;        
    }

    /**
     * @dev Invokes a deposit call to the official Deposit contract
     */
    function _stake(bytes memory pubkey, bytes memory signature) internal {
        require(withdrawalCredentials != bytes32(0x0), "WITHDRAWAL_CREDENTIALS_NOT_SET");
        uint256 value = DEPOSIT_SIZE;
        uint256 depositAmount = DEPOSIT_SIZE / DEPOSIT_AMOUNT_UNIT;
        assert(depositAmount * DEPOSIT_AMOUNT_UNIT == value);    // properly rounded

        // Compute deposit data root (`DepositData` hash tree root)
        // https://etherscan.io/address/0x00000000219ab540356cbb839cbe05303d7705fa#code
        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));
        bytes32 signature_root = sha256(abi.encodePacked(
            sha256(BytesLib.slice(signature, 0, 64)),
            sha256(abi.encodePacked(BytesLib.slice(signature, 64, SIGNATURE_LENGTH - 64), bytes32(0)))
        ));
        
        bytes memory amount = to_little_endian_64(uint64(depositAmount));

        bytes32 depositDataRoot = sha256(abi.encodePacked(
            sha256(abi.encodePacked(pubkey_root, withdrawalCredentials)),
            sha256(abi.encodePacked(amount, bytes24(0), signature_root))
        ));

        IDepositContract(ethDepositContract).deposit{value:DEPOSIT_SIZE} (
            pubkey, abi.encodePacked(withdrawalCredentials), signature, depositDataRoot);
    }

    /**
     * @dev to little endian
     * https://etherscan.io/address/0x00000000219ab540356cbb839cbe05303d7705fa#code
     */
    function to_little_endian_64(uint64 value) internal pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        // Byteswapping during copying to bytes.
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }

    /**
     * ======================================================================================
     * 
     * ROCKX SYSTEM EVENTS
     *
     * ======================================================================================
     */
    event ValidatorActivated(uint256 node_id);
    event ValidatorStopped(uint256 [] stoppedIDs);
    event RevenueAccounted(uint256 amount);
    event ManagerAccountSet(address account);
    event ManagerFeeSet(uint256 milli);
    event ManagerFeeWithdrawed(uint256 amount, address);
    event Redeemed(uint256 amountXETH, uint256 amountETH);
    event RedeemFromValidator(uint256 amountXETH, uint256 amountETH);
    event WithdrawCredentialSet(bytes32 withdrawCredential);
    event DebtQueued(address creditor, uint256 amountEther);
    event XETHContractSet(address addr);
    event DepositContractSet(address addr);
    event DebtContractSet(address addr);
}
