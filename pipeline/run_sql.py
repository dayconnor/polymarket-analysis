"""Run one or more .sql files against a single DuckDB session and print results.

Usage:
    python pipeline/run_sql.py sql/00_profile/00_sources.sql sql/00_profile/01_schema.sql
    python pipeline/run_sql.py --set dq_day=2026-09-08 sql/00_profile/00_sources.sql ...

Statements are split on a semicolon at the end of a line. Each statement's
leading `-- ` comment block is printed as its header, then its result (if any).
All files share one connection, so views defined in an earlier file (e.g.
00_sources.sql) are visible to later ones, and DuckDB's HTTP cache is reused.
If HF_TOKEN is set, it is registered as a Hugging Face secret to avoid
anonymous rate limits. Each --set NAME=VALUE runs SET VARIABLE NAME = 'VALUE'
(a string) before the first file.
"""

import argparse

import os
import re
import sys
import time

import duckdb
import pandas as pd

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 50)
pd.set_option("display.max_rows", 200)
pd.set_option("display.max_colwidth", 80)


def split_statements(sql_text):
    parts = re.split(r";\s*$", sql_text, flags=re.MULTILINE)
    return [p.strip() for p in parts if re.sub(r"--.*", "", p).strip()]


def header_of(statement):
    lines = []
    for line in statement.splitlines():
        if line.startswith("--"):
            lines.append(line)
        elif line.strip():
            break
    return "\n".join(lines)


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--set", action="append", default=[], metavar="NAME=VALUE")
    args = parser.parse_args(argv)

    con = duckdb.connect()
    token = os.environ.get("HF_TOKEN")
    if token:
        con.execute(f"CREATE SECRET hf_token (TYPE huggingface, TOKEN '{token}')")
    for pair in args.set:
        name, _, value = pair.partition("=")
        if not name.isidentifier():
            parser.error(f"bad --set name: {name!r}")
        con.execute(f"SET VARIABLE {name} = ?", [value])

    for path in args.paths:
        print(f"\n######## {path}")
        with open(path) as f:
            statements = split_statements(f.read())
        for statement in statements:
            print("\n" + (header_of(statement) or statement.splitlines()[0]))
            start = time.time()
            rel = con.sql(statement)
            if rel is not None:
                print(rel.df().to_string(index=False))
            print(f"[{time.time() - start:.1f}s]")


if __name__ == "__main__":
    main(sys.argv[1:])
