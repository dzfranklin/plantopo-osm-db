#!/usr/bin/env python3
"""
Deploy PostgreSQL functions and restart martin only if definitions changed.

Usage:
    deploy.py [--dsn DSN] [--martin-service SERVICE] [sql_file ...]

If no sql_files are given, all *.sql files in the same directory as this
script are applied (sorted).

The script compares the normalised source of each CREATE OR REPLACE FUNCTION
statement against the live definition stored in pg_proc (via pg_get_functiondef).
Martin is restarted via systemctl only when at least one function changed.
"""

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

import psycopg2


# ---------------------------------------------------------------------------
# SQL parsing
# ---------------------------------------------------------------------------

def _normalise(text: str) -> str:
    """Collapse whitespace so cosmetic formatting changes don't trigger deploys."""
    return re.sub(r"\s+", " ", text).strip().lower()


_FUNC_RE = re.compile(
    r"""
    CREATE \s+ OR \s+ REPLACE \s+ FUNCTION \s+
    osm_functions \s* \. \s*  # schema prefix (required)
    (?P<name>\w+) \s* \(
    (?P<args>[^)]*)
    \)
    .*?                     # return type, language, options …
    \$\$ \s* (?P<body>.*?) \s* \$\$
    """,
    re.IGNORECASE | re.DOTALL | re.VERBOSE,
)


def parse_functions(sql: str) -> dict[str, str]:
    """
    Return {function_name: normalised_signature_fingerprint} for every
    CREATE OR REPLACE FUNCTION block found in *sql*.

    Only the signature (name + args) is fingerprinted — martin always calls
    the latest body via CREATE OR REPLACE, so body changes don't require a
    restart. Martin only needs restarting when a function is added, removed,
    or its signature changes.
    """
    results = {}
    for m in _FUNC_RE.finditer(sql):
        name = m.group("name").lower()
        # Fingerprint = normalised signature only (name + args), not body
        signature = _normalise(f"{name}({m.group('args')})")
        fingerprint = hashlib.sha256(signature.encode()).hexdigest()
        results[name] = fingerprint
    return results


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

SCHEMA = "osm_functions"


def ensure_schema(conn) -> None:
    with conn.cursor() as cur:
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
    conn.commit()


def all_live_functions(conn) -> list[tuple[str, str]]:
    """Return (name, identity_args) for every function in the osm_functions schema.

    identity_args comes from pg_get_function_identity_arguments, which returns
    the fully-qualified argument types needed for an unambiguous DROP FUNCTION.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT p.proname,
                   pg_get_function_identity_arguments(p.oid) AS identity_args
            FROM   pg_proc p
            JOIN   pg_namespace n ON n.oid = p.pronamespace
            WHERE  n.nspname = %s
            """,
            (SCHEMA,),
        )
        return cur.fetchall()


def live_fingerprints(conn, names: list[str]) -> dict[str, str]:
    """
    Return {function_name: fingerprint} for functions that currently exist
    in the database, using pg_get_function_arguments for the signature only.
    Functions not yet in the DB are absent from the returned dict.
    """
    if not names:
        return {}
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT p.proname,
                   pg_get_function_arguments(p.oid) AS args
            FROM   pg_proc p
            JOIN   pg_namespace n ON n.oid = p.pronamespace
            WHERE  n.nspname = %s
              AND  p.proname = ANY(%s)
            """,
            (SCHEMA, names),
        )
        rows = cur.fetchall()
    return {
        row[0]: hashlib.sha256(_normalise(f"{row[0]}({row[1]})").encode()).hexdigest()
        for row in rows
    }


def apply_file(conn, path: Path) -> None:
    sql = path.read_text()
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    print(f"  applied {path.name}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

DSN = "postgresql:///osm?user=postgres"  # Unix socket, trust auth inside container
MARTIN_SERVICE = "martin"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-restart",
        action="store_true",
        help="apply functions but skip the martin restart (useful for local dev)",
    )
    args = parser.parse_args()

    sql_files: list[Path] = sorted(Path(__file__).parent.glob("*.sql"))
    if not sql_files:
        print("No SQL files found — nothing to do.")
        sys.exit(0)

    # Parse all files and collect function fingerprints from source
    source_fps: dict[str, str] = {}
    file_for_func: dict[str, Path] = {}
    for path in sql_files:
        sql = path.read_text()
        funcs = parse_functions(sql)
        if not funcs:
            print(f"WARNING: no CREATE OR REPLACE FUNCTION osm_functions.<name>(...) found in {path.name}", file=sys.stderr)
        for name, fp in funcs.items():
            source_fps[name] = fp
            file_for_func[name] = path

    if not source_fps:
        print("No function definitions found in any SQL file — nothing to do.")
        sys.exit(1)

    conn = psycopg2.connect(DSN)
    try:
        ensure_schema(conn)
        live_funcs = all_live_functions(conn)
        live_fps = live_fingerprints(conn, list(source_fps))

        removed = [(name, identity_args) for name, identity_args in live_funcs if name not in source_fps]
        changed: list[str] = [
            name for name, src_fp in source_fps.items()
            if live_fps.get(name) != src_fp
        ]

        if not changed and not removed:
            print("All functions are up to date — martin restart skipped.")
            return

        if removed:
            print(f"Dropping removed functions: {', '.join(sorted(n for n, _ in removed))}")
            with conn.cursor() as cur:
                for name, args in removed:
                    cur.execute(f"DROP FUNCTION IF EXISTS {SCHEMA}.{name}({args})")
            conn.commit()

        if changed:
            print(f"Changed functions: {', '.join(sorted(changed))}")
            applied_files: set[Path] = set()
            for name in changed:
                path = file_for_func[name]
                if path not in applied_files:
                    apply_file(conn, path)
                    applied_files.add(path)

    finally:
        conn.close()

    if args.no_restart:
        print("Skipping martin restart (--no-restart).")
        return

    print(f"Restarting {MARTIN_SERVICE}...")
    subprocess.run(
        ["systemctl", "restart", MARTIN_SERVICE],
        check=True,
    )
    print("Done.")


if __name__ == "__main__":
    main()
