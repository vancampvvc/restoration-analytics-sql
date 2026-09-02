#!/usr/bin/env bash
# ============================================================================
# Build the database from scratch and run every analysis query.
#
#   ./run_all.sh                  -> builds db 'restoration_demo', prints results
#   ./run_all.sh mydb             -> builds into 'mydb' instead
#   SAVE=1 ./run_all.sh           -> also writes results/*.txt
#
# Requires a running PostgreSQL 13+ and a role that can create databases.
# ============================================================================
set -euo pipefail

DB="${1:-restoration_demo}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Rebuilding database: $DB"
dropdb --if-exists "$DB"
createdb "$DB"

for f in "$HERE"/sql/0*.sql; do
    echo "==> $(basename "$f")"
    psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$f"
done

if [[ "${SAVE:-0}" == "1" ]]; then
    mkdir -p "$HERE/results"
fi

for f in "$HERE"/sql/analysis/*.sql; do
    name="$(basename "$f" .sql)"
    echo
    echo "############################################################"
    echo "# $name"
    echo "############################################################"
    if [[ "${SAVE:-0}" == "1" ]]; then
        psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$f" | tee "$HERE/results/$name.txt"
    else
        psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "$f"
    fi
done

echo
echo "==> Done. All queries executed without error against '$DB'."
