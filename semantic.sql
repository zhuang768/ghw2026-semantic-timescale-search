\set ON_ERROR_STOP on
\pset pager off
\echo 'Real 384-dimensional MiniLM semantic retrieval in TimescaleDB'

BEGIN;
SET LOCAL TIME ZONE 'UTC';
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS ghw_semantic_lab;
SELECT version() AS database_version;
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('timescaledb','vector','vectorscale') ORDER BY extname;

CREATE TABLE IF NOT EXISTS ghw_semantic_lab.events (
    recorded_at timestamptz NOT NULL,
    id integer NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    embedding vector(384) NOT NULL,
    metadata jsonb NOT NULL,
    PRIMARY KEY (recorded_at,id),
    CHECK (jsonb_typeof(metadata) = 'object')
);
SELECT create_hypertable('ghw_semantic_lab.events',
                        by_range('recorded_at', INTERVAL '1 day'),
                        if_not_exists => true);
CREATE TABLE IF NOT EXISTS ghw_semantic_lab.queries (
    id integer PRIMARY KEY,
    query_text text NOT NULL,
    embedding vector(384) NOT NULL,
    provenance jsonb NOT NULL
);

-- These SQL literals are outputs of actual local, offline model inference.
\ir generated/embeddings.sql
\ir generated/reference.sql
ANALYZE ghw_semantic_lab.events;

\echo 'Model and query provenance from the actual inference run'
SELECT id, query_text, vector_dims(embedding) AS dimensions, provenance
FROM ghw_semantic_lab.queries;
SELECT hypertable_schema,hypertable_name,num_chunks
FROM timescaledb_information.hypertables
WHERE hypertable_schema='ghw_semantic_lab' AND hypertable_name='events';

-- Disable all index scans for the exact reference, including reruns after
-- an approximate index has already been created. No global settings change.
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;

\echo 'Executed exact semantic search plan'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT id, embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
FROM ghw_semantic_lab.events
WHERE recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
  AND recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
  AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
LIMIT 3;

CREATE TEMP TABLE semantic_exact AS
SELECT id,recorded_at,title,description,metadata,
       embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance,
       embedding <-> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS l2_distance
FROM ghw_semantic_lab.events
WHERE recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
  AND recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
  AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb;

\echo 'Semantic positives and unrelated negatives: exact cosine ranking'
SELECT id,recorded_at,title,cosine_distance,l2_distance
FROM semantic_exact ORDER BY cosine_distance,id;
\echo 'Exact L2 top three'
SELECT id,recorded_at,title,l2_distance
FROM semantic_exact ORDER BY l2_distance,id LIMIT 3;
\echo 'Stronger exact-query matches intentionally excluded by time or metadata'
SELECT id,recorded_at,title,metadata,
       embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
FROM ghw_semantic_lab.events WHERE id BETWEEN 201 AND 204 ORDER BY id;

DO $checks$
DECLARE
    eligible_ids integer[];
    actual_ids integer[];
    expected_ids integer[];
BEGIN
    IF (SELECT count(*) FROM ghw_semantic_lab.events) <> 137 THEN
        RAISE EXCEPTION 'Expected 137 real-model corpus embeddings';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables
                   WHERE hypertable_schema='ghw_semantic_lab' AND hypertable_name='events') THEN
        RAISE EXCEPTION 'Storage is not a TimescaleDB hypertable';
    END IF;
    IF EXISTS (SELECT 1 FROM ghw_semantic_lab.events
               WHERE vector_dims(embedding) <> 384 OR abs(vector_norm(embedding)-1) > 0.00001)
       OR EXISTS (SELECT 1 FROM ghw_semantic_lab.queries
                  WHERE vector_dims(embedding) <> 384 OR abs(vector_norm(embedding)-1) > 0.00001) THEN
        RAISE EXCEPTION 'Embedding dimension or normalization validation failed';
    END IF;
    SELECT array_agg(id ORDER BY id) INTO eligible_ids FROM semantic_exact;
    IF eligible_ids IS DISTINCT FROM ARRAY[101,102,103,104,105] THEN
        RAISE EXCEPTION 'UTC half-open window or metadata filtering failed: %',eligible_ids;
    END IF;
    SELECT array_agg(id ORDER BY cosine_distance,id) INTO actual_ids
    FROM (SELECT * FROM semantic_exact ORDER BY cosine_distance,id LIMIT 3) AS top3;
    SELECT array_agg(id ORDER BY cosine_distance,id) INTO expected_ids
    FROM (SELECT * FROM semantic_numpy_reference ORDER BY cosine_distance,id LIMIT 3) AS top3;
    IF actual_ids IS DISTINCT FROM expected_ids THEN
        RAISE EXCEPTION 'SQL cosine ranking disagrees with real-model NumPy reference: % vs %',actual_ids,expected_ids;
    END IF;
    SELECT array_agg(id ORDER BY id) INTO actual_ids
    FROM (SELECT * FROM semantic_exact ORDER BY cosine_distance,id LIMIT 3) AS top3;
    IF actual_ids IS DISTINCT FROM ARRAY[101,102,103] THEN
        RAISE EXCEPTION 'Semantic paraphrase positives failed to outrank unrelated descriptions: %',actual_ids;
    END IF;
    SELECT array_agg(id ORDER BY l2_distance,id) INTO actual_ids
    FROM (SELECT * FROM semantic_exact ORDER BY l2_distance,id LIMIT 3) AS top3;
    SELECT array_agg(id ORDER BY l2_distance,id) INTO expected_ids
    FROM (SELECT * FROM semantic_numpy_reference ORDER BY l2_distance,id LIMIT 3) AS top3;
    IF actual_ids IS DISTINCT FROM expected_ids THEN
        RAISE EXCEPTION 'SQL L2 ranking disagrees with NumPy reference';
    END IF;
    IF EXISTS (
        SELECT 1 FROM semantic_exact AS a FULL JOIN semantic_numpy_reference AS e USING(id)
        WHERE a.id IS NULL OR e.id IS NULL
           OR abs(a.cosine_distance-e.cosine_distance)>0.00001
           OR abs(a.l2_distance-e.l2_distance)>0.00001
           OR abs(a.l2_distance*a.l2_distance - 2*a.cosine_distance)>0.00001
    ) THEN
        RAISE EXCEPTION 'SQL distances, independent NumPy reference, or unit-vector relation failed';
    END IF;
    IF EXISTS (
        SELECT 1 FROM ghw_semantic_lab.events WHERE id BETWEEN 201 AND 204
        AND abs(embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1))>0.00001
    ) THEN
        RAISE EXCEPTION 'Excluded exact-query fixtures are not exact semantic matches';
    END IF;
    RAISE NOTICE 'PASS: real 384D normalized embeddings, hypertable, UTC/metadata filters, semantic ranking, NumPy cosine/L2 agreement';
END
$checks$;

CREATE INDEX IF NOT EXISTS semantic_cosine_hnsw
ON ghw_semantic_lab.events USING hnsw (embedding vector_cosine_ops)
WITH (m=16,ef_construction=64);
ANALYZE ghw_semantic_lab.events;
SET LOCAL enable_indexscan = on;
SET LOCAL enable_bitmapscan = on;
SET LOCAL enable_seqscan = off;
SET LOCAL enable_sort = off;
SET LOCAL hnsw.ef_search = 100;
SET LOCAL hnsw.iterative_scan = strict_order;

-- The local planner options exercise the HNSW path for this small fixture.
-- This is an execution demonstration and not a performance benchmark.
\echo 'Executed HNSW semantic query plan'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT id,embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
FROM ghw_semantic_lab.events
WHERE recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
  AND recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
  AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
LIMIT 3;

CREATE TEMP TABLE semantic_hnsw AS
SELECT id,recorded_at,title,description,metadata,
       embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
FROM ghw_semantic_lab.events
WHERE recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
  AND recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
  AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
LIMIT 3;
SELECT id,recorded_at,title,cosine_distance FROM semantic_hnsw ORDER BY cosine_distance,id;

DO $checks$
DECLARE
    query_plan json;
BEGIN
    EXECUTE $plan$
        EXPLAIN (FORMAT JSON)
        SELECT id FROM ghw_semantic_lab.events
        WHERE recorded_at >= TIMESTAMPTZ '2026-10-13 00:00:00+00'
          AND recorded_at < TIMESTAMPTZ '2026-10-14 00:00:00+00'
          AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
        ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
        LIMIT 3
    $plan$ INTO query_plan;
    IF position('semantic_cosine_hnsw' IN query_plan::text)=0 THEN
        RAISE EXCEPTION 'HNSW path was not exercised: %',query_plan;
    END IF;
    IF EXISTS (
        SELECT 1 FROM semantic_hnsw AS a
        FULL JOIN (SELECT * FROM semantic_exact ORDER BY cosine_distance,id LIMIT 3) AS e USING(id)
        WHERE a.id IS NULL OR e.id IS NULL OR abs(a.cosine_distance-e.cosine_distance)>0.00001
    ) THEN
        RAISE EXCEPTION 'HNSW differs from the exact filtered semantic neighbors';
    END IF;
    RAISE NOTICE 'PASS: executed HNSW plan and fixture-specific exact top-three neighbor/distance equality';
END
$checks$;

CREATE TABLE IF NOT EXISTS ghw_semantic_lab.retrieval_runs (
    id integer PRIMARY KEY,
    executed_at timestamptz NOT NULL,
    context jsonb NOT NULL
);
INSERT INTO ghw_semantic_lab.retrieval_runs(id,executed_at,context)
SELECT 1,current_timestamp,jsonb_build_object(
    'question',(SELECT query_text FROM ghw_semantic_lab.queries WHERE id=1),
    'model',(SELECT provenance->>'model' FROM ghw_semantic_lab.queries WHERE id=1),
    'revision',(SELECT provenance->>'revision' FROM ghw_semantic_lab.queries WHERE id=1),
    'dimensions',384,
    'fixture_source','authored synthetic events; dates are teaching fixtures',
    'time_window',jsonb_build_object('start_inclusive','2026-10-13T00:00:00Z','end_exclusive','2026-10-14T00:00:00Z'),
    'metadata_filter',jsonb_build_object('category','database','project','ghw_demo'),
    'purpose','RAG-ready retrieved context; no language-model answer generation is claimed',
    'passages',jsonb_agg(jsonb_build_object('id',id,'recorded_at',recorded_at,'title',title,
                 'description',description,'metadata',metadata,'cosine_distance',cosine_distance)
                 ORDER BY cosine_distance,id)
)
FROM semantic_hnsw
ON CONFLICT(id) DO UPDATE SET executed_at=EXCLUDED.executed_at,context=EXCLUDED.context;
\echo 'RAG-ready context assembled from real database retrieval'
SELECT jsonb_pretty(context) FROM ghw_semantic_lab.retrieval_runs WHERE id=1;

COMMIT;
\echo 'SEMANTIC LAB COMPLETE: actual model inference and all database assertions passed'
