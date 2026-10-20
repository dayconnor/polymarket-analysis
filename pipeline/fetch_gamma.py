"""Fetch resolution fields from the Polymarket Gamma API for staged markets.

Usage:
    python pipeline/fetch_gamma.py                  # all parts, resumes where it stopped
    python pipeline/fetch_gamma.py --max-parts 1    # smoke test

Reads market ids from data/processed/gamma_request_ids.csv (written by
sql/01_staging/01_stg_markets.sql Q5) and writes data/raw/gamma/part_NNNNN.parquet,
one part per 10,000 ids. Existing parts are skipped, so an interrupted run resumes.

Gamma accepts at most 100 ids per request and hides closed markets unless
closed=true, so each batch is queried with closed=true and any ids not returned
are re-queried with closed=false. Ids found by neither are kept with found=false.
Only resolution, timing, and series fields are kept (a full response is ~5 KB
per market, mostly event metadata and description). All values are stored as
raw strings; typing happens in sql/01_staging/02_stg_market_resolution.sql.
Gamma is live data, not pinned, so every row records fetched_at.
"""

import argparse
import csv
import json
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import pyarrow as pa
import pyarrow.parquet as pq

URL = "https://gamma-api.polymarket.com/markets"
IDS_PATH = "data/processed/gamma_request_ids.csv"
OUT_DIR = "data/raw/gamma"
BATCH = 100            # Gamma's max ids per request (422 above this)
PART = 10_000          # ids per output file
WORKERS = 4
MIN_INTERVAL = 0.1     # seconds between request starts, all workers (≤ 10 req/s)
RETRIES = 6
HEADERS = {"User-Agent": "polymarket-calibration-research/0.1"}  # default urllib UA gets 403

MARKET_FIELDS = [
    "id", "conditionId", "questionID", "closed", "closedTime",
    "umaResolutionStatus", "umaResolutionStatuses", "resolvedBy",
    "automaticallyResolved", "outcomes", "outcomePrices", "umaEndDate",
    "endDate", "gameStartTime", "sportsMarketType", "negRisk", "updatedAt",
]
EVENT_FIELDS = {"id": "event_id", "slug": "event_slug", "seriesSlug": "series_slug"}
COLUMNS = MARKET_FIELDS + list(EVENT_FIELDS.values()) + [
    "n_events", "query_closed", "found", "fetched_at",
]
SCHEMA = pa.schema(
    [(c, pa.bool_() if c == "found" else pa.int32() if c == "n_events" else pa.string())
     for c in COLUMNS]
)

_lock = threading.Lock()
_next_start = 0.0


def throttle():
    global _next_start
    with _lock:
        now = time.monotonic()
        wait = _next_start - now
        _next_start = max(now, _next_start) + MIN_INTERVAL
    if wait > 0:
        time.sleep(wait)


def get(ids, closed):
    query = urllib.parse.urlencode(
        [("closed", closed), ("limit", BATCH)] + [("id", i) for i in ids]
    )
    for attempt in range(RETRIES):
        throttle()
        try:
            req = urllib.request.Request(f"{URL}?{query}", headers=HEADERS)
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504):
                raise
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(2 ** attempt + random.random())
    raise RuntimeError(f"Gave up after {RETRIES} tries on ids {ids[0]}..{ids[-1]}")


def to_str(v):
    if v is None or isinstance(v, str):
        return v
    return json.dumps(v)


def row(market, closed, fetched_at):
    events = market.get("events") or []
    first = events[0] if events else {}
    r = {f: to_str(market.get(f)) for f in MARKET_FIELDS}
    r.update({out: to_str(first.get(src)) for src, out in EVENT_FIELDS.items()})
    r.update(n_events=len(events), query_closed=closed, found=True, fetched_at=fetched_at)
    return r


def fetch_batch(ids):
    fetched_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    rows = {}
    for closed in ("true", "false"):
        missing = [i for i in ids if i not in rows]
        if not missing:
            break
        for m in get(missing, closed):
            if m["id"] in missing:
                rows[m["id"]] = row(m, closed, fetched_at)
    for i in ids:
        if i not in rows:
            rows[i] = {c: None for c in COLUMNS} | {"id": i, "found": False, "fetched_at": fetched_at}
    return [rows[i] for i in ids]


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-parts", type=int, default=None)
    args = parser.parse_args(argv)

    with open(IDS_PATH) as f:
        ids = [r["market_id"] for r in csv.DictReader(f)]
    os.makedirs(OUT_DIR, exist_ok=True)
    parts = [ids[i:i + PART] for i in range(0, len(ids), PART)]
    if args.max_parts is not None:
        parts = parts[:args.max_parts]
    print(f"{len(ids):,} ids, {len(parts)} parts of {PART:,}")

    with ThreadPoolExecutor(WORKERS) as pool:
        for k, part_ids in enumerate(parts):
            path = os.path.join(OUT_DIR, f"part_{k:05d}.parquet")
            if os.path.exists(path):
                continue
            start = time.time()
            batches = [part_ids[i:i + BATCH] for i in range(0, len(part_ids), BATCH)]
            rows = [r for batch in pool.map(fetch_batch, batches) for r in batch]
            tmp = path + ".tmp"
            pq.write_table(pa.Table.from_pylist(rows, schema=SCHEMA), tmp, compression="zstd")
            os.replace(tmp, path)
            n_missing = sum(not r["found"] for r in rows)
            n_open = sum(r["query_closed"] == "false" for r in rows)
            print(f"part {k:05d}: {len(rows):,} rows, {n_open} via closed=false, "
                  f"{n_missing} not found [{time.time() - start:.1f}s]", flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
