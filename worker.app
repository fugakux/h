import os
import sys
import time
import math
import json
from typing import Any, Dict, Optional, Tuple

from web3 import Web3
from web3.exceptions import ContractLogicError


def env(name: str, default: Optional[str] = None) -> str:
    v = os.getenv(name, default)
    if v is None:
        print(f"[FATAL] Missing env {name}")
        sys.exit(1)
    return v


# -----------------------------
# Config (all via env)
# -----------------------------

RPC_URL            = env("RPC_URL", "https://rpc.hyperliquid.xyz/evm")
MARKETPLACE_ADDR   = env("MARKETPLACE_ADDR")
NFT_ADDR           = env("NFT_ADDR")
FINDER_ADDR        = env("FINDER_ADDR")
OPERATOR_OVERRIDE  = os.getenv("OPERATOR_OVERRIDE", "") or MARKETPLACE_ADDR
PRIVATE_KEY        = env("PRIVATE_KEY")
NATIVE_WRAPPER     = env("NATIVE_WRAPPER", "0x5555555555555555555555555555555555555555")
MAX_SUPPLY_FALLBACK= int(env("MAX_SUPPLY_FALLBACK", "6000"))
POLL_SEC           = float(env("POLL_SEC", "5"))
COOLDOWN_SEC       = float(env("COOLDOWN_SEC", "60"))


# -----------------------------
# ABIs (minimal)
# -----------------------------

ERC20_ABI = [
    {"type":"function","stateMutability":"view","name":"allowance","inputs":[{"name":"owner","type":"address"},{"name":"spender","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},
    {"type":"function","stateMutability":"nonpayable","name":"approve","inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]},
    {"type":"function","stateMutability":"view","name":"balanceOf","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"","type":"uint256"}]}
]

ERC721_SUP_ABI = [
    {"type":"function","stateMutability":"view","name":"tokenURI","inputs":[{"name":"","type":"uint256"}],"outputs":[{"name":"","type":"string"}]}
]

FINDER_ABI = [
    {
        "type":"function","stateMutability":"view","name":"findCheapestRange",
        "inputs":[
            {"name":"marketplace","type":"address"},
            {"name":"hypios","type":"address"},
            {"name":"operatorOverride","type":"address"},
            {"name":"startId","type":"uint256"},
            {"name":"endExclusive","type":"uint256"}
        ],
        "outputs":[{"name":"result","type":"tuple","components":[
            {"name":"found","type":"bool"},
            {"name":"tokenId","type":"uint256"},
            {"name":"seller","type":"address"},
            {"name":"pricePerItem","type":"uint128"},
            {"name":"paymentToken","type":"address"}
        ]}]
    }
]

def load_market_abi(web3: Web3):
    path = os.path.join(os.path.dirname(__file__), "marketplace_abi.json")
    abi = None
    try:
        with open(path, "r", encoding="utf-8") as f:
            j = json.load(f)
            abi = j.get("abi", j) if isinstance(j, dict) else j
    except Exception:
        pass
    if not abi:
        # Fallback with both overloads
        abi = [
            {
                "type": "function","stateMutability": "payable","name": "buyItems",
                "inputs": [{"name":"","type":"tuple[]","components":[
                    {"name":"nftAddress","type":"address"},
                    {"name":"tokenId","type":"uint256"},
                    {"name":"owner","type":"address"},
                    {"name":"quantity","type":"uint64"},
                    {"name":"maxPricePerItem","type":"uint128"},
                    {"name":"paymentToken","type":"address"},
                    {"name":"usingNative","type":"bool"}
                ]}],"outputs":[]
            },
            {
                "type": "function","stateMutability": "payable","name": "buyItems",
                "inputs": [{"name":"","type":"tuple[]","components":[
                    {"name":"nftAddress","type":"address"},
                    {"name":"tokenId","type":"uint256"},
                    {"name":"owner","type":"address"},
                    {"name":"quantity","type":"uint64"},
                    {"name":"maxPricePerItem","type":"uint128"},
                    {"name":"paymentToken","type":"address"}
                ]}],"outputs":[]
            }
        ]
    return web3.eth.contract(address=Web3.to_checksum_address(MARKETPLACE_ADDR), abi=abi)


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def find_cheapest(web3: Web3) -> Tuple[Optional[Dict[str, Any]], int]:
    finder = web3.eth.contract(address=Web3.to_checksum_address(FINDER_ADDR), abi=FINDER_ABI)
    supply = MAX_SUPPLY_FALLBACK
    chunk = ceil_div(supply, 3)
    ranges = [(0, min(chunk, supply)), (min(chunk, supply), min(2*chunk, supply)), (min(2*chunk, supply), supply)]
    best = None
    for a, b in ranges:
        print(f"[SCAN] range {a}..{b}")
        res = finder.functions.findCheapestRange(MARKETPLACE_ADDR, NFT_ADDR, OPERATOR_OVERRIDE, a, b).call()
        if res and res[0]:
            cand = {
                "found": True,
                "tokenId": int(res[1]),
                "seller": Web3.to_checksum_address(res[2]),
                "priceWei": int(res[3]),
                "paymentToken": Web3.to_checksum_address(res[4])
            }
            print(f"[SCAN] candidate: {cand}")
            if not best or cand["priceWei"] < best["priceWei"]:
                best = cand
    return best, supply


def ensure_erc20_allowance(web3: Web3, acct, market, token_addr: str, needed: int):
    erc20 = web3.eth.contract(address=Web3.to_checksum_address(token_addr), abi=ERC20_ABI)
    cur = int(erc20.functions.allowance(acct.address, market.address).call())
    print(f"[ALLOW] current allowance {cur}")
    if cur >= needed:
        return
    tx = erc20.functions.approve(market.address, needed).build_transaction({
        "from": acct.address,
        "nonce": web3.eth.get_transaction_count(acct.address),
        "chainId": web3.eth.chain_id,
    })
    try:
        gas_est = web3.eth.estimate_gas(tx)
        tx["gas"] = math.floor(gas_est * 1.2)
    except Exception:
        tx["gas"] = 120000
    try:
        base = web3.eth.get_block("latest").get("baseFeePerGas")
        if base is not None:
            pr = web3.to_wei(1, "gwei")
            tx["maxPriorityFeePerGas"] = pr
            tx["maxFeePerGas"] = int(base) + pr * 2
        else:
            tx["gasPrice"] = web3.to_wei(1, "gwei")
    except Exception:
        tx["gasPrice"] = web3.to_wei(1, "gwei")
    signed = web3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    h = web3.eth.send_raw_transaction(signed.rawTransaction)
    print(f"[ALLOW] approve tx {h.hex()}")


def try_buy(web3: Web3, best: Dict[str, Any]) -> Optional[str]:
    market = load_market_abi(web3)
    acct = web3.eth.account.from_key(PRIVATE_KEY)
    zero = Web3.to_checksum_address("0x0000000000000000000000000000000000000000")
    using_native = best["paymentToken"].lower() in (zero.lower(), NATIVE_WRAPPER.lower())

    if not using_native:
        ensure_erc20_allowance(web3, acct, market, best["paymentToken"], best["priceWei"])

    buy_item7 = (
        Web3.to_checksum_address(NFT_ADDR),
        int(best["tokenId"]),
        Web3.to_checksum_address(best["seller"]),
        1,
        int(best["priceWei"]),
        Web3.to_checksum_address(best["paymentToken"]),
        using_native,
    )
    value_native = int(best["priceWei"]) if using_native else 0

    last_err = None
    for sig, args in [
        ("buyItems((address,uint256,address,uint64,uint128,address,bool)[])", [buy_item7]),
        ("buyItems((address,uint256,address,uint64,uint128,address)[])", [buy_item7[:-1]])
    ]:
        try:
            fn = market.get_function_by_signature(sig)(args)
            fn.call({"from": acct.address, "value": value_native}, block_identifier="latest")
            tx = fn.build_transaction({
                "from": acct.address,
                "value": value_native,
                "nonce": web3.eth.get_transaction_count(acct.address),
                "chainId": web3.eth.chain_id,
            })
            try:
                gas_est = web3.eth.estimate_gas(tx)
                tx["gas"] = math.floor(gas_est * 1.2)
            except Exception:
                tx["gas"] = 600000
            try:
                base = web3.eth.get_block("latest").get("baseFeePerGas")
                if base is not None:
                    pr = web3.to_wei(1, "gwei")
                    tx["maxPriorityFeePerGas"] = pr
                    tx["maxFeePerGas"] = int(base) + pr * 2
                else:
                    tx["gasPrice"] = web3.to_wei(1, "gwei")
            except Exception:
                tx["gasPrice"] = web3.to_wei(1, "gwei")
            signed = web3.eth.account.sign_transaction(tx, PRIVATE_KEY)
            h = web3.eth.send_raw_transaction(signed.rawTransaction)
            print(f"[BUY] success via {sig}  tx={h.hex()}")
            return h.hex()
        except Exception as e:
            last_err = e
            print(f"[BUY] preflight/tx fail with {sig}: {getattr(e,'args',[str(e)])[0]}")
    if last_err:
        print(f"[BUY] failed: {str(last_err)}")
    return None


def main():
    print("[BOOT] cheapest_worker starting…")
    web3 = Web3(Web3.HTTPProvider(RPC_URL, request_kwargs={"timeout": 30}))
    acct = web3.eth.account.from_key(PRIVATE_KEY)
    print(f"[CONF] rpc={RPC_URL}")
    print(f"[CONF] market={MARKETPLACE_ADDR} nft={NFT_ADDR} finder={FINDER_ADDR} operator={OPERATOR_OVERRIDE}")
    print(f"[CONF] nativeWrapper={NATIVE_WRAPPER} account={acct.address}")

    last_buy_ts = 0.0
    while True:
        try:
            best, supply = find_cheapest(web3)
            if not best:
                print("[LOOP] no cheapest found; sleep")
                time.sleep(POLL_SEC)
                continue
            price_eth = web3.from_wei(best["priceWei"], "ether")
            print(f"[CHEAPEST] tokenId={best['tokenId']} priceWei={best['priceWei']} ({price_eth} ETH) seller={best['seller']} payToken={best['paymentToken']}")

            # Cooldown guard
            if time.time() - last_buy_ts < COOLDOWN_SEC:
                print("[COOLDOWN] waiting…")
                time.sleep(POLL_SEC)
                continue

            # Balance checks
            native_bal = web3.eth.get_balance(acct.address)
            print(f"[BAL] native={native_bal}")
            if best["paymentToken"].lower() not in ("0x0000000000000000000000000000000000000000", NATIVE_WRAPPER.lower()):
                erc20 = web3.eth.contract(address=best["paymentToken"], abi=ERC20_ABI)
                tok_bal = int(erc20.functions.balanceOf(acct.address).call())
                print(f"[BAL] token={tok_bal}")
                if tok_bal < best["priceWei"]:
                    print("[SKIP] insufficient token balance")
                    time.sleep(POLL_SEC)
                    continue
                if native_bal < web3.to_wei(0.0005, "ether"):
                    print("[SKIP] insufficient native for gas")
                    time.sleep(POLL_SEC)
                    continue
            else:
                need = best["priceWei"] + int(web3.to_wei(0.0005, "ether"))
                if native_bal < need:
                    print("[SKIP] insufficient native for price+gas")
                    time.sleep(POLL_SEC)
                    continue

            txh = try_buy(web3, best)
            if txh:
                last_buy_ts = time.time()
        except Exception as e:
            print(f"[ERROR] loop: {str(e)}")
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()


