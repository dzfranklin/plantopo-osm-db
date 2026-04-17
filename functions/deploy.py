#!/usr/bin/env python3
"""
Deploy PostgreSQL functions.

All *.sql files in the same directory as this script are applied (sorted).
Functions present in the DB but not declared in any source file are dropped.
"""

import re
import sys
from pathlib import Path

import psycopg2


SCHEMA = "osm_functions"
DSN = "postgresql:///osm?user=postgres"  # Unix socket, trust auth inside container

_FUNC_NAME_RE = re.compile(
    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+osm_functions\s*\.\s*(\w+)\s*\(",
    re.IGNORECASE,
)


def main() -> None:
    sql_files: list[Path] = sorted(Path(__file__).parent.glob("*.sql"))
    if not sql_files:
        print("No SQL files found — nothing to do.")
        sys.exit(0)

    source_funcs: set[str] = set()
    for path in sql_files:
        source_funcs.update(m.group(1).lower() for m in _FUNC_NAME_RE.finditer(path.read_text()))

    conn = psycopg2.connect(DSN)
    try:
        with conn.cursor() as cur:
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
        conn.commit()

        # Drop functions removed from source
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT p.proname, pg_get_function_identity_arguments(p.oid)
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = %s
                """,
                (SCHEMA,),
            )
            live_funcs = cur.fetchall()
        removed = [(name, args) for name, args in live_funcs if name not in source_funcs]
        if removed:
            print(f"Dropping removed functions: {', '.join(sorted(n for n, _ in removed))}")
            with conn.cursor() as cur:
                for name, args in removed:
                    cur.execute(f"DROP FUNCTION IF EXISTS {SCHEMA}.{name}({args})")
            conn.commit()

        for path in sql_files:
            with conn.cursor() as cur:
                cur.execute(path.read_text())
            conn.commit()
            print(f"  applied {path.name}")
    finally:
        conn.close()

    print("Done.")


if __name__ == "__main__":
    main()
