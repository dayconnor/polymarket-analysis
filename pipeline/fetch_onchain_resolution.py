"""Fetch on-chain resolutions from the Conditional Tokens contract for the Section 7 check.

Usage:
    python pipeline/fetch_onchain_resolution.py --selftest     # keccak vectors, no network
    python pipeline/fetch_onchain_resolution.py --limit 3      # smoke test
    python pipeline/fetch_onchain_resolution.py                # all, resumes where it stopped
    python pipeline/fetch_onchain_resolution.py --tokens       # slot-to-token check

--tokens reads data/processed/res_check_tokens.csv (06_res_check_tokens.sql) and, for each
market, asks CTF for the position id of index sets 1 and 2 under each candidate collateral
(USDC.e; the NegRiskAdapter's wrapped collateral). It writes which of token1/token2 each
slot equals to data/raw/onchain_tokens.jsonl. A 256-bit match cannot occur by chance, so
a match settles the slot-to-token mapping for that market.

Reads data/processed/res_check_sample.csv (sql/02_intermediate/05_res_check_sample.sql) and
the archive RPC endpoint from POLYGON_RPC_URL (never printed). Writes one JSON line per
market to data/raw/onchain_resolution.jsonl; markets already fetched without error are
skipped, so a rerun retries only the failures (readers keep the error-free row).

Per market:
  1. Read payoutDenominator, outcome slot count and payoutNumerators at the latest block.
     A zero denominator means the condition is unresolved on chain.
  2. Binary-search the first block with a nonzero denominator. CTF sets the denominator
     once, at reportPayouts, so it is monotone in block number. The search starts at the
     last trade before closed_time (falling back to the first trade, then block 1).
  3. Fetch ConditionResolution logs in that single block, decode oracle and payout
     numerators, and read the block timestamp.
This avoids eth_getLogs over wide ranges, which free RPC tiers cap. It needs archive
state (historical eth_call). Values are stored raw (uint256 as decimal strings) and are
typed and compared with Gamma in a later SQL file.
"""

import argparse
import csv
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

SAMPLE_PATH = "data/processed/res_check_sample.csv"
OUT_PATH = "data/raw/onchain_resolution.jsonl"
CTF = "0x4d97dcd97ec945f40cf65f87097ace5ea0476045"   # Gnosis Conditional Tokens, Polygon
WORKERS = 4
MAX_TRIES = 6


# Keccak-256 (Ethereum's pre-standard SHA-3 padding; hashlib.sha3_256 differs).
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rotl(v, n):
    return ((v << n) | (v >> (64 - n))) & _M if n else v


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rotl(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rotl(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]) for y in range(5)]
             for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += b"\x00" * (-len(msg) % rate)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        a = _keccak_f(a)
    return b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


def selftest():
    assert keccak256(b"").hex() == \
        "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    assert keccak256(b"transfer(address,uint256)")[:4].hex() == "a9059cbb"
    assert keccak256(b"Transfer(address,address,uint256)").hex() == \
        "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"


def selector(sig):
    return "0x" + keccak256(sig.encode()).hex()[:8]


SEL_DENOM = selector("payoutDenominator(bytes32)")
SEL_NUMER = selector("payoutNumerators(bytes32,uint256)")
SEL_SLOTS = selector("getOutcomeSlotCount(bytes32)")
TOPIC_RESOLUTION = "0x" + keccak256(
    b"ConditionResolution(bytes32,address,bytes32,uint256,uint256[])").hex()
SEL_COLLECTION = selector("getCollectionId(bytes32,bytes32,uint256)")
SEL_POSITION = selector("getPositionId(address,bytes32)")
SEL_WCOL = selector("wcol()")
USDC_E = "0x2791bca1f2de4661ed88a30c99a7a9449aa84174"
NEG_RISK_ADAPTER = "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296"
TOKENS_PATH = "data/processed/res_check_tokens.csv"
TOKENS_OUT = "data/raw/onchain_tokens.jsonl"


class Rpc:
    def __init__(self, url):
        self.url = url
        self.lock = threading.Lock()
        self.calls = 0

    def __call__(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                           "params": params}).encode()
        for attempt in range(MAX_TRIES):
            req = urllib.request.Request(self.url, data=body,
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    out = json.load(resp)
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
                if isinstance(e, urllib.error.HTTPError) and e.code not in (429, 500, 502, 503, 504):
                    raise RuntimeError(f"{method}: HTTP {e.code}") from None
                time.sleep(2 ** attempt)
                continue
            with self.lock:
                self.calls += 1
            if "error" in out:
                err = out["error"]
                msg = str(err.get("message", "")).lower()
                # "account ... is not found" is a transient node-side state miss on Alchemy
                # (the same call succeeds on retry), not a property of the block.
                if err.get("code") == 429 or "rate" in msg or "is not found" in msg:
                    time.sleep(2 ** attempt)
                    continue
                raise RuntimeError(f"{method}: {err}")
            return out["result"]
        raise RuntimeError(f"{method}: gave up after {MAX_TRIES} tries")


def call_uint(rpc, data, block):
    # Explicit sender: with the default 0x0 sender some Alchemy nodes fail historical calls
    # with "account 0x0 is not found"; CTF itself exists at every block after deployment.
    res = rpc("eth_call", [{"from": CTF, "to": CTF, "data": data}, block])
    return int(res, 16) if res and res != "0x" else 0


def cid_word(cid):
    return cid[2:].lower().rjust(64, "0")


def denom_at(rpc, cid, block):
    tag = block if isinstance(block, str) else hex(block)
    return call_uint(rpc, SEL_DENOM + cid_word(cid), tag)


def first_resolved_block(rpc, cid, lo, hi):
    """Smallest block in (lo, hi] with a nonzero denominator; denom(lo) == 0, denom(hi) > 0."""
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if denom_at(rpc, cid, mid) > 0:
            hi = mid
        else:
            lo = mid
    return hi


def decode_log(log):
    data = bytes.fromhex(log["data"][2:])
    words = [int.from_bytes(data[i:i + 32], "big") for i in range(0, len(data), 32)]
    slot_count, offset = words[0], words[1] // 32
    length = words[offset]
    return {
        "event_oracle": "0x" + log["topics"][2][-40:],
        "event_question_id": log["topics"][3],
        "event_slot_count": str(slot_count),
        "event_numerators": [str(w) for w in words[offset + 1:offset + 1 + length]],
    }


def fetch_one(rpc, row, latest):
    cid = row["condition_id"]
    out = {"market_id": row["market_id"], "condition_id": cid,
           "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "latest_block": latest, "error": None}
    try:
        denom = denom_at(rpc, cid, hex(latest))
        slots = call_uint(rpc, SEL_SLOTS + cid_word(cid), hex(latest))
        out["state_denominator"] = str(denom)
        out["state_slot_count"] = str(slots)
        out["state_numerators"] = [
            str(call_uint(rpc, SEL_NUMER + cid_word(cid) + hex(i)[2:].rjust(64, "0"), hex(latest)))
            for i in range(slots)]
        if denom == 0:
            out["resolution_block"] = None
            return out

        lo = None
        for cand in (row.get("hint_block"), row.get("first_block")):
            if cand and denom_at(rpc, cid, int(cand)) == 0:
                lo = int(cand)
                break
        if lo is None:
            lo = 1 if denom_at(rpc, cid, 1) == 0 else None
        if lo is None:
            raise RuntimeError("denominator nonzero at every search start")
        block = first_resolved_block(rpc, cid, lo, latest)
        out["resolution_block"] = block
        out["search_lo"] = lo

        logs = rpc("eth_getLogs", [{"address": CTF, "fromBlock": hex(block), "toBlock": hex(block),
                                    "topics": [TOPIC_RESOLUTION, cid.lower()]}])
        out["n_events"] = len(logs)
        if logs:
            out.update(decode_log(logs[0]))
            out["event_tx"] = logs[0]["transactionHash"]
        blk = rpc("eth_getBlockByNumber", [hex(block), False])
        out["resolution_ts_unix"] = int(blk["timestamp"], 16)
    except Exception as e:
        out["error"] = str(e)[:500]
    return out


def call_word(rpc, to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])[2:].rjust(64, "0")


def token_one(rpc, row, collaterals):
    """Which sheet token each outcome slot's position id equals, per candidate collateral.
    Index set 1 is payout slot 1 (payout_numerators[0]); index set 2 is slot 2."""
    cid = row["condition_id"]
    out = {"market_id": row["market_id"], "condition_id": cid,
           "neg_risk": row["neg_risk"], "error": None}
    names = {int(row["token1"]): "token1", int(row["token2"]): "token2"}
    try:
        for index_set in (1, 2):
            coll = call_word(rpc, CTF, SEL_COLLECTION + "0" * 64 + cid_word(cid)
                             + hex(index_set)[2:].rjust(64, "0"))
            hits = []
            for name, addr in collaterals.items():
                pos = int(call_word(rpc, CTF, SEL_POSITION + addr[2:].rjust(64, "0") + coll), 16)
                if pos in names:
                    hits.append((name, names[pos]))
            out[f"slot{index_set}_matches"] = [f"{c}:{t}" for c, t in hits]
    except Exception as e:
        out["error"] = str(e)[:500]
    return out


def run_tokens(rpc, limit, workers):
    wcol = "0x" + call_word(rpc, NEG_RISK_ADAPTER, SEL_WCOL)[-40:]
    collaterals = {"usdc_e": USDC_E, "neg_risk_wcol": wcol}
    with open(TOKENS_PATH) as f:
        rows = list(csv.DictReader(f))[:limit]
    print(f"{len(rows)} markets; wrapped collateral {wcol}")
    with open(TOKENS_OUT, "w") as f, ThreadPoolExecutor(workers) as pool:
        for i, out in enumerate(pool.map(lambda r: token_one(rpc, r, collaterals), rows), 1):
            f.write(json.dumps(out) + "\n")
            if i % 100 == 0 or i == len(rows):
                print(f"  {i}/{len(rows)}  rpc calls {rpc.calls}")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--tokens", action="store_true",
                        help="slot-to-token check from res_check_tokens.csv instead")
    # Alchemy's free tier throttles per-second compute units; 4 workers tripped it.
    parser.add_argument("--workers", type=int, default=WORKERS)
    args = parser.parse_args(argv)
    workers = args.workers

    selftest()
    print(f"keccak self-test passed; ConditionResolution topic {TOPIC_RESOLUTION}")
    if args.selftest:
        return

    url = os.environ.get("POLYGON_RPC_URL")
    if not url:
        sys.exit("POLYGON_RPC_URL is not set (export it in ~/.zshrc, then source it)")
    rpc = Rpc(url)

    if int(rpc("eth_chainId", []), 16) != 137:
        sys.exit("endpoint is not Polygon mainnet (chain id 137)")
    if len(rpc("eth_getCode", [CTF, "latest"])) <= 2:
        sys.exit("no contract code at the CTF address")
    if args.tokens:
        run_tokens(rpc, args.limit, workers)
        return
    latest = int(rpc("eth_blockNumber", []), 16)

    with open(SAMPLE_PATH) as f:
        rows = list(csv.DictReader(f))
    done = set()
    if os.path.exists(OUT_PATH):
        with open(OUT_PATH) as f:
            done = {r["market_id"] for r in map(json.loads, filter(str.strip, f))
                    if r["error"] is None}
    todo = [r for r in rows if r["market_id"] not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f"{len(rows)} sampled, {len(done)} done, {len(todo)} to fetch; latest block {latest}")

    start, n_err = time.time(), 0
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "a") as f, ThreadPoolExecutor(workers) as pool:
        for i, out in enumerate(pool.map(lambda r: fetch_one(rpc, r, latest), todo), 1):
            f.write(json.dumps(out) + "\n")
            f.flush()
            n_err += out["error"] is not None
            if i % 25 == 0 or i == len(todo):
                print(f"  {i}/{len(todo)}  errors {n_err}  rpc calls {rpc.calls}  "
                      f"{time.time() - start:.0f}s")


if __name__ == "__main__":
    main(sys.argv[1:])
