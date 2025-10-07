// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title MarketingSplitter
/// @notice Drop-in native-coin splitter to use as a token's marketing wallet.
///         Send native to this contract and it forwards per configured shares.
///         If a recipient cannot receive, the owed amount is accrued for later
///         withdrawal by that recipient.
contract MarketingSplitter {
    uint16 public constant BPS_DENOMINATOR = 10_000; // 100.00%

    address public owner;

    address public wallet1;
    address public wallet2;
    address public wallet3;

    uint16 public shareBps1; // e.g., 4500 = 45.00%
    uint16 public shareBps2; // e.g., 4500 = 45.00%
    uint16 public shareBps3; // e.g., 1000 = 10.00%

    mapping(address => uint256) public owed; // credits if a send fails

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RecipientsUpdated(address w1, address w2, address w3, uint16 b1, uint16 b2, uint16 b3);
    event Received(address indexed from, uint256 amount);
    event Payout(address indexed to, uint256 amount);
    event Owed(address indexed to, uint256 amount);

    error NotOwner();
    error ZeroAddress();
    error InvalidShares();

    modifier onlyOwner(){ if(msg.sender != owner) revert NotOwner(); _; }

    constructor(
        address _w1,
        address _w2,
        address _w3,
        uint16 _b1,
        uint16 _b2,
        uint16 _b3
    ){
        if(_w1==address(0) || _w2==address(0) || _w3==address(0)) revert ZeroAddress();
        if(uint256(_b1)+_b2+_b3 != BPS_DENOMINATOR) revert InvalidShares();
        owner   = msg.sender;
        wallet1 = _w1; wallet2=_w2; wallet3=_w3;
        shareBps1=_b1; shareBps2=_b2; shareBps3=_b3;
        emit OwnershipTransferred(address(0), owner);
        emit RecipientsUpdated(_w1,_w2,_w3,_b1,_b2,_b3);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if(newOwner==address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Owner can update recipient wallets and/or shares. Shares must sum to 100% (10_000 bps).
    function updateRecipients(
        address _w1,
        address _w2,
        address _w3,
        uint16 _b1,
        uint16 _b2,
        uint16 _b3
    ) external onlyOwner {
        if(_w1==address(0) || _w2==address(0) || _w3==address(0)) revert ZeroAddress();
        if(uint256(_b1)+_b2+_b3 != BPS_DENOMINATOR) revert InvalidShares();
        wallet1=_w1; wallet2=_w2; wallet3=_w3;
        shareBps1=_b1; shareBps2=_b2; shareBps3=_b3;
        emit RecipientsUpdated(_w1,_w2,_w3,_b1,_b2,_b3);
    }

    /// @notice Main entrypoint: any native sent here gets split immediately by msg.value
    receive() external payable { _split(msg.value); }
    fallback() external payable { if(msg.value>0) _split(msg.value); }

    /// @notice Manually distribute the current contract balance according to shares.
    function flush() external {
        uint256 bal = address(this).balance;
        if(bal>0) _split(bal);
    }

    /// @notice Claim any owed amount if prior payout attempts to you failed.
    function claimOwed() external {
        uint256 amount = owed[msg.sender];
        require(amount>0, "nothing owed");
        owed[msg.sender]=0;
        _safeSend(msg.sender, amount);
        emit Payout(msg.sender, amount);
    }

    function _split(uint256 amount) internal {
        emit Received(msg.sender, amount);
        if(amount==0) return;

        uint256 a1 = (amount * shareBps1) / BPS_DENOMINATOR;
        uint256 a2 = (amount * shareBps2) / BPS_DENOMINATOR;
        uint256 a3 = amount - a1 - a2; // remainder to last to avoid dust

        _payout(wallet1, a1);
        _payout(wallet2, a2);
        _payout(wallet3, a3);
    }

    function _payout(address to, uint256 amt) private {
        if(amt==0) return;
        (bool ok, ) = payable(to).call{value:amt}("");
        if(ok){ emit Payout(to, amt); }
        else{
            owed[to] += amt;
            emit Owed(to, amt);
        }
    }

    function _safeSend(address to, uint256 amt) private {
        (bool ok, ) = payable(to).call{value:amt}("");
        require(ok, "send fail");
    }
}


