#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$LAB_ROOT"
LAB_SOCKET="${LAB_SOCKET:-${TMPDIR:-/tmp}/ghw2026-timescale-lab}"
LAB_PORT="${LAB_PORT:-55473}"
mkdir -p "$LAB_SOCKET" build evidence
chmod 700 "$LAB_SOCKET"
if [[ ! -f db-data/PG_VERSION ]]; then
  runtime/bin/initdb -D db-data -U ghw_lab --auth-local=trust --auth-host=reject --encoding=UTF8 --locale=C
fi
if ! runtime/bin/pg_ctl -D db-data status >/dev/null 2>&1; then
  runtime/bin/pg_ctl -D db-data -l build/server-private.log \
    -o "-c listen_addresses='' -c unix_socket_directories='$LAB_SOCKET' -p $LAB_PORT -c shared_preload_libraries=timescaledb -c timescaledb.telemetry_level=off -c timezone=UTC" start
fi
PSQL=(runtime/bin/psql -X -h "$LAB_SOCKET" -p "$LAB_PORT" -U ghw_lab -v ON_ERROR_STOP=1)
if [[ "$("${PSQL[@]}" -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='ghw_lab'")" == 0 ]]; then
  runtime/bin/createdb -h "$LAB_SOCKET" -p "$LAB_PORT" -U ghw_lab ghw_lab
fi
"${PSQL[@]}" -d ghw_lab -c 'CREATE EXTENSION IF NOT EXISTS timescaledb; CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;'
"${PSQL[@]}" -d ghw_lab -f semantic.sql > evidence/reproduced-semantic-output.txt 2>&1
"${PSQL[@]}" -d ghw_lab -f diskann.sql > evidence/reproduced-diskann-output.txt 2>&1
printf 'Actual SQL complete. Start the dashboard with python3 serve-semantic.py\n'
printf 'After viewing it, stop PostgreSQL with runtime/bin/pg_ctl -D db-data stop\n'

