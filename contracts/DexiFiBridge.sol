// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DexiFi Bridge
 * @dev Cross-chain bridge contract for DeFi token transfers
 * @notice Optimized for Cancun EVM version with ERC20 support
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract DexiFiBridge {
    
    // State variables
    address public owner;
    uint256 public bridgeFee; // Fee in basis points (100 = 1%)
    uint256 public totalTransactions;
    bool public paused;
    
    // Supported chains mapping
    mapping(uint256 => bool) public supportedChains;
    
    // Bridge transactions
    mapping(bytes32 => BridgeTransaction) public transactions;
    
    // User balances locked in bridge
    mapping(address => mapping(address => uint256)) public lockedBalances;
    
    // Relayer addresses
    mapping(address => bool) public relayers;
    
    struct BridgeTransaction {
        address sender;
        address recipient;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 destinationChain;
        uint256 timestamp;
        TransactionStatus status;
    }
    
    enum TransactionStatus {
        Pending,
        Completed,
        Cancelled,
        Failed
    }
    
    // Events
    event BridgeInitiated(
        bytes32 indexed txId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 sourceChain,
        uint256 destinationChain
    );
    
    event BridgeCompleted(bytes32 indexed txId, address indexed recipient);
    event BridgeCancelled(bytes32 indexed txId);
    event ChainAdded(uint256 indexed chainId);
    event ChainRemoved(uint256 indexed chainId);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event FeeUpdated(uint256 newFee);
    event Paused();
    event Unpaused();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Custom errors (gas efficient in Cancun)
    error Unauthorized();
    error ContractPaused();
    error InvalidRecipient();
    error InvalidAmount();
    error ChainNotSupported();
    error ChainAlreadySupported();
    error TransactionNotPending();
    error AlreadyRelayer();
    error NotRelayer();
    error FeeTooHigh();
    error TokenTransferFailed();
    error InsufficientBalance();
    
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyRelayer() {
        if (!relayers[msg.sender]) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    
    constructor() {
        owner = msg.sender;
        bridgeFee = 50; // Default 0.5% fee
        paused = false;
        relayers[msg.sender] = true;
    }
    
    /**
     * @dev Function 1: Initialize a bridge transfer
     * @param recipient Address to receive tokens on destination chain
     * @param token Token address being bridged (address(0) for native ETH)
     * @param amount Amount of tokens to bridge
     * @param destinationChain Target chain ID
     */
    function initiateBridge(
        address recipient,
        address token,
        uint256 amount,
        uint256 destinationChain
    ) external payable whenNotPaused returns (bytes32) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (!supportedChains[destinationChain]) revert ChainNotSupported();
        
        // Handle native ETH vs ERC20 tokens
        if (token == address(0)) {
            // Native ETH bridge
            if (msg.value != amount) revert InvalidAmount();
        } else {
            // ERC20 token bridge
            if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
                revert TokenTransferFailed();
            }
        }
        
        uint256 fee = (amount * bridgeFee) / 10000;
        uint256 netAmount;
        unchecked {
            netAmount = amount - fee;
        }
        
        bytes32 txId = keccak256(
            abi.encodePacked(
                msg.sender,
                recipient,
                token,
                amount,
                block.chainid,
                destinationChain,
                block.timestamp,
                totalTransactions
            )
        );
        
        transactions[txId] = BridgeTransaction({
            sender: msg.sender,
            recipient: recipient,
            token: token,
            amount: netAmount,
            sourceChain: block.chainid,
            destinationChain: destinationChain,
            timestamp: block.timestamp,
            status: TransactionStatus.Pending
        });
        
        unchecked {
            lockedBalances[msg.sender][token] += amount;
            totalTransactions++;
        }
        
        emit BridgeInitiated(
            txId,
            msg.sender,
            recipient,
            token,
            netAmount,
            block.chainid,
            destinationChain
        );
        
        return txId;
    }
    
    /**
     * @dev Function 2: Complete a bridge transfer (relayer only)
     * @param txId Transaction ID to complete
     */
    function completeBridge(bytes32 txId) external onlyRelayer {
        BridgeTransaction storage txn = transactions[txId];
        if (txn.status != TransactionStatus.Pending) revert TransactionNotPending();
        
        txn.status = TransactionStatus.Completed;
        
        emit BridgeCompleted(txId, txn.recipient);
    }
    
    /**
     * @dev Function 3: Cancel a pending bridge transaction
     * @param txId Transaction ID to cancel
     */
    function cancelBridge(bytes32 txId) external {
        BridgeTransaction storage txn = transactions[txId];
        if (msg.sender != txn.sender && msg.sender != owner) revert Unauthorized();
        if (txn.status != TransactionStatus.Pending) revert TransactionNotPending();
        
        txn.status = TransactionStatus.Cancelled;
        
        uint256 refundAmount;
        unchecked {
            refundAmount = txn.amount + ((txn.amount * bridgeFee) / (10000 - bridgeFee));
            lockedBalances[txn.sender][txn.token] -= refundAmount;
        }
        
        // Refund tokens to sender
        if (txn.token == address(0)) {
            // Refund native ETH
            payable(txn.sender).transfer(refundAmount);
        } else {
            // Refund ERC20 tokens
            if (!IERC20(txn.token).transfer(txn.sender, refundAmount)) {
                revert TokenTransferFailed();
            }
        }
        
        emit BridgeCancelled(txId);
    }
    
    /**
     * @dev Function 4: Add a supported chain
     * @param chainId Chain ID to add
     */
    function addSupportedChain(uint256 chainId) external onlyOwner {
        if (supportedChains[chainId]) revert ChainAlreadySupported();
        supportedChains[chainId] = true;
        emit ChainAdded(chainId);
    }
    
    /**
     * @dev Function 5: Remove a supported chain
     * @param chainId Chain ID to remove
     */
    function removeSupportedChain(uint256 chainId) external onlyOwner {
        if (!supportedChains[chainId]) revert ChainNotSupported();
        supportedChains[chainId] = false;
        emit ChainRemoved(chainId);
    }
    
    /**
     * @dev Function 6: Add a relayer
     * @param relayer Address to add as relayer
     */
    function addRelayer(address relayer) external onlyOwner {
        if (relayers[relayer]) revert AlreadyRelayer();
        relayers[relayer] = true;
        emit RelayerAdded(relayer);
    }
    
    /**
     * @dev Function 7: Remove a relayer
     * @param relayer Address to remove from relayers
     */
    function removeRelayer(address relayer) external onlyOwner {
        if (!relayers[relayer]) revert NotRelayer();
        relayers[relayer] = false;
        emit RelayerRemoved(relayer);
    }
    
    /**
     * @dev Function 8: Update bridge fee
     * @param newFee New fee in basis points
     */
    function updateBridgeFee(uint256 newFee) external onlyOwner {
        if (newFee > 1000) revert FeeTooHigh(); // Max 10%
        bridgeFee = newFee;
        emit FeeUpdated(newFee);
    }
    
    /**
     * @dev Function 9: Pause the bridge
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }
    
    /**
     * @dev Function 10: Unpause the bridge
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }
    
    /**
     * @dev Transfer ownership to a new address
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidRecipient();
        
        address previousOwner = owner;
        owner = newOwner;
        
        emit OwnershipTransferred(previousOwner, newOwner);
    }
    
    /**
     * @dev Get transaction details
     * @param txId Transaction ID
     */
    function getTransaction(bytes32 txId) external view returns (BridgeTransaction memory) {
        return transactions[txId];
    }
    
    /**
     * @dev Check if chain is supported
     * @param chainId Chain ID to check
     */
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return supportedChains[chainId];
    }
    
    /**
     * @dev Get locked balance for user and token
     * @param user User address
     * @param token Token address
     */
    function getLockedBalance(address user, address token) external view returns (uint256) {
        return lockedBalances[user][token];
    }
    
    /**
     * @dev Get contract balance for a specific token
     * @param token Token address (address(0) for ETH)
     */
    function getContractBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }
    
    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {
        // Allow contract to receive ETH
    }
    
    /**
     * @dev Fallback function
     */
    fallback() external payable {
        // Allow contract to receive ETH
    }
}