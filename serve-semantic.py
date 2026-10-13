#!/usr/bin/env python3
"""Loopback-only semantic dashboard with fixed read-only PostgreSQL queries.

After the repository's run-local.sh and the semantic SQL, from the repository root:
  python3 serve-semantic.py
--psql accepts an explicit local binary; the default uses the repository runtime.
No commands, SQL, filenames, filters, or database settings are accepted over HTTP.
"""
import argparse
import json
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

LAB_DIR = Path(__file__).resolve().parent
BASE_SQL = """
WITH q AS (SELECT * FROM ghw_semantic_lab.queries WHERE id=1),
eligible AS (
  SELECT e.id,e.recorded_at,e.title,e.description,e.metadata,
         e.embedding <=> q.embedding AS cosine_distance,
         e.embedding <-> q.embedding AS l2_distance
  FROM ghw_semantic_lab.events AS e CROSS JOIN q
  WHERE e.recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
    AND e.recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
    AND e.metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
), nearest AS (
  SELECT * FROM eligible WHERE cosine_distance<=0.6
  ORDER BY cosine_distance,id LIMIT 3
)
SELECT jsonb_build_object(
  'queried_at_utc',to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'transaction_read_only',current_setting('transaction_read_only'),
  'postgresql_version',current_setting('server_version'),
  'extensions',(SELECT jsonb_object_agg(extname,extversion) FROM pg_extension
                WHERE extname IN ('timescaledb','vector','vectorscale')),
  'query_text',q.query_text,
  'dimensions',vector_dims(q.embedding),
  'model_provenance',q.provenance,
  'corpus_rows',(SELECT count(*) FROM ghw_semantic_lab.events),
  'time_chunks',(SELECT num_chunks FROM timescaledb_information.hypertables
                 WHERE hypertable_schema='ghw_semantic_lab' AND hypertable_name='events'),
  'filters',jsonb_build_object('start_inclusive','2026-10-13T00:00:00Z',
               'end_exclusive','2026-10-14T00:00:00Z','category','database',
               'project','ghw_demo','metric','cosine distance','maximum_inclusive',0.6),
  'eligible_before_radius',(SELECT count(*) FROM eligible),
  'eligible_after_radius',(SELECT count(*) FROM eligible WHERE cosine_distance<=0.6),
  'nearest',(SELECT jsonb_agg(to_jsonb(n) ORDER BY cosine_distance,id) FROM nearest AS n),
  'recorded_semantic_run',(SELECT jsonb_build_object('executed_at',executed_at,'context',context)
                            FROM ghw_semantic_lab.retrieval_runs WHERE id=1),
  'recorded_diskann_run',(SELECT jsonb_build_object('executed_at',executed_at,'context',context)
                          FROM ghw_semantic_lab.retrieval_runs WHERE id=2),
  'diskann_table_exists',to_regclass('ghw_semantic_lab.events_diskann') IS NOT NULL
) FROM q;
"""

DISKANN_SQL = """
WITH q AS (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1),
candidates AS MATERIALIZED (
  SELECT e.id,e.recorded_at,e.title,e.description,e.metadata,
         e.embedding <=> (SELECT embedding FROM q) AS cosine_distance,
         e.embedding <-> (SELECT embedding FROM q) AS l2_distance
  FROM ghw_semantic_lab.events_diskann AS e
  WHERE e.recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
    AND e.recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
    AND e.metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
  ORDER BY e.embedding <=> (SELECT embedding FROM q) LIMIT 20
), nearest AS (
  SELECT * FROM candidates WHERE cosine_distance<=0.6
  ORDER BY cosine_distance+0,id LIMIT 3
)
SELECT jsonb_build_object(
  'queried_at_utc',to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'transaction_read_only',current_setting('transaction_read_only'),
  'copy_rows',(SELECT count(*) FROM ghw_semantic_lab.events_diskann),
  'copy_mismatches',(SELECT count(*) FROM ghw_semantic_lab.events_diskann AS d
       FULL JOIN ghw_semantic_lab.events AS s USING(recorded_at,id)
       WHERE d.id IS NULL OR s.id IS NULL OR d.embedding IS DISTINCT FROM s.embedding
          OR d.description IS DISTINCT FROM s.description OR d.metadata IS DISTINCT FROM s.metadata),
  'diskann_index_present',EXISTS(SELECT 1 FROM pg_index AS i
       JOIN pg_class AS c ON c.oid=i.indexrelid JOIN pg_am AS a ON a.oid=c.relam
       WHERE i.indrelid='ghw_semantic_lab.events_diskann'::regclass AND a.amname='diskann'),
  'nearest',(SELECT jsonb_agg(to_jsonb(n) ORDER BY cosine_distance,id) FROM nearest AS n)
);
"""


def query_json(args, sql):
    # Do not inherit credentials, HOME, psql startup files, or arbitrary options.
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'PGPASSFILE': '/dev/null',
           'PGOPTIONS': '-c default_transaction_read_only=on -c statement_timeout=7000'}
    result = subprocess.run(
        [str(args.psql), '-X', '-A', '-t', '-w', '--set=ON_ERROR_STOP=1',
         '--host', args.socket, '--port', str(args.db_port),
         '--username', args.user, '--dbname', args.database, '--command', sql],
        check=True, capture_output=True, text=True, timeout=10, env=env, cwd=LAB_DIR,
    )
    data = json.loads(result.stdout.strip())
    if not isinstance(data, dict):
        raise ValueError('Unexpected database response')
    return data


def same_neighbors(left, right):
    if not isinstance(left, list) or not isinstance(right, list) or len(left) != len(right):
        return False
    return all(a['id'] == b['id'] and
               abs(float(a['cosine_distance']) - float(b['cosine_distance'])) <= 0.00001 and
               abs(float(a['l2_distance']) - float(b['l2_distance'])) <= 0.00001
               for a, b in zip(left, right))


def read_status(args):
    status = query_json(args, BASE_SQL)
    installed = bool((status.get('extensions') or {}).get('vectorscale'))
    recorded = status.get('recorded_diskann_run')
    # Never reference a missing copy table. A recorded run is only written by
    # diskann.sql after its actual index/neighbor assertions have passed.
    if installed and recorded and status.get('diskann_table_exists'):
        try:
            diskann = query_json(args, DISKANN_SQL)
            diskann['state'] = 'recorded_run_available'
            diskann['matches_current_pgvector'] = same_neighbors(
                status.get('nearest'), diskann.get('nearest'))
            status['diskann'] = diskann
        except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError):
            status['diskann'] = {'state': 'unavailable',
                                'message': 'The recorded DiskANN copy is unavailable for a live read.'}
    else:
        status['diskann'] = {
            'state': 'pending',
            'message': 'Extension installed; actual DiskANN verification is pending.' if installed
                       else 'The vectorscale extension and actual DiskANN verification are pending.',
        }
    return status


def make_handler(args):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'GHWSemanticLab/1.0'
        sys_version = ''

        def respond(self, code, body, content_type):
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy',
                "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                "style-src 'self' 'unsafe-inline'; connect-src 'self'; "
                "base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            try:
                parsed = urlsplit(self.path)
                host = urlsplit('//' + self.headers.get('Host', '')).hostname
            except ValueError:
                self.respond(400, b'Invalid local request.', 'text/plain; charset=utf-8')
                return
            if host not in ('127.0.0.1', 'localhost'):
                self.respond(403, b'Loopback host required.', 'text/plain; charset=utf-8')
                return
            if parsed.query or parsed.fragment or parsed.scheme or parsed.netloc:
                self.respond(400, b'Only fixed local routes are supported.', 'text/plain; charset=utf-8')
                return
            if parsed.path == '/api/status':
                try:
                    payload = json.dumps(read_status(args), ensure_ascii=False).encode('utf-8')
                except (subprocess.SubprocessError, OSError, ValueError):
                    # Connection paths and subprocess stderr never reach the UI.
                    self.respond(503, b'{"error":"Live semantic SQL is unavailable. Check the local database."}',
                                 'application/json; charset=utf-8')
                    return
                self.respond(200, payload, 'application/json; charset=utf-8')
                return
            if parsed.path != '/':
                self.respond(404, b'Not found.', 'text/plain; charset=utf-8')
                return
            try:
                body = (LAB_DIR / 'semantic-dashboard.html').read_bytes()
            except OSError:
                self.respond(404, b'Dashboard unavailable.', 'text/plain; charset=utf-8')
                return
            self.respond(200, body, 'text/html; charset=utf-8')

        def do_POST(self):
            self.respond(405, b'Read-only dashboard.', 'text/plain; charset=utf-8')

        do_PUT = do_POST
        do_PATCH = do_POST
        do_DELETE = do_POST

        def log_message(self, format_string, *arguments):
            # Do not log attacker-controlled routes or Host values.
            return

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    adjacent = LAB_DIR / 'runtime' / 'bin' / 'psql'
    parser.add_argument('--psql', type=Path,
                        default=adjacent if adjacent.is_file() else LAB_DIR.parent / 'runtime' / 'bin' / 'psql')
    parser.add_argument('--socket', default=str(Path(tempfile.gettempdir()) / 'ghw2026-timescale-lab'))
    parser.add_argument('--port', type=int, default=8790)
    parser.add_argument('--db-port', type=int, default=55473)
    parser.add_argument('--user', default='ghw_lab')
    parser.add_argument('--database', default='ghw_lab')
    args = parser.parse_args()
    args.psql = args.psql.expanduser().resolve()
    if not args.psql.is_file():
        parser.error('psql is unavailable; provide an existing local binary with --psql.')
    if not 1 <= args.port <= 65535 or not 1 <= args.db_port <= 65535:
        parser.error('Ports must be between 1 and 65535.')
    if not Path(args.socket).is_absolute():
        parser.error('--socket must be an absolute Unix socket directory.')
    server = ThreadingHTTPServer(('127.0.0.1', args.port), make_handler(args))
    print('Live read-only semantic dashboard: http://127.0.0.1:' + str(args.port) + '/', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
