\set ON_ERROR_STOP on
\pset pager off
\echo 'pgvectorscale StreamingDiskANN verification on actual 384D semantic embeddings'

BEGIN;
SET LOCAL TIME ZONE 'UTC';
-- Installation belongs to the lab runner. Stop before any fixture change if
-- vectorscale is not already installed; availability alone is not execution.
DO $guard$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='vectorscale') THEN
        RAISE EXCEPTION 'PENDING: install the official vectorscale extension before running diskann.sql';
    END IF;
    IF to_regclass('ghw_semantic_lab.events') IS NULL
       OR to_regclass('ghw_semantic_lab.queries') IS NULL THEN
        RAISE EXCEPTION 'Run semantic.sql with actual MiniLM embeddings before diskann.sql';
    END IF;
END
$guard$;
SELECT extname,extversion FROM pg_extension
WHERE extname IN ('timescaledb','vector','vectorscale') ORDER BY extname;

-- A separate, logged hypertable ensures the HNSW index on the original events
-- cannot serve this test. Copy vectors and provenance, not invented features.
CREATE TABLE IF NOT EXISTS ghw_semantic_lab.events_diskann (
    recorded_at timestamptz NOT NULL,
    id integer NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    embedding vector(384) NOT NULL,
    metadata jsonb NOT NULL,
    PRIMARY KEY(recorded_at,id),
    CHECK(jsonb_typeof(metadata)='object')
);
SELECT create_hypertable('ghw_semantic_lab.events_diskann',
                        by_range('recorded_at',INTERVAL '1 day'),
                        if_not_exists=>true);
INSERT INTO ghw_semantic_lab.events_diskann
    (recorded_at,id,title,description,embedding,metadata)
SELECT recorded_at,id,title,description,embedding,metadata
FROM ghw_semantic_lab.events
ON CONFLICT(recorded_at,id) DO UPDATE
SET title=EXCLUDED.title,description=EXCLUDED.description,
    embedding=EXCLUDED.embedding,metadata=EXCLUDED.metadata;
ANALYZE ghw_semantic_lab.events_diskann;
\ir generated/reference.sql

SET LOCAL enable_indexscan=off;
SET LOCAL enable_bitmapscan=off;
CREATE TEMP TABLE diskann_exact AS
SELECT id,recorded_at,title,description,metadata,
       embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance,
       embedding <-> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS l2_distance
FROM ghw_semantic_lab.events_diskann
WHERE recorded_at>=TIMESTAMPTZ '2026-10-13 00:00:00+00'
  AND recorded_at<TIMESTAMPTZ '2026-10-14 00:00:00+00'
  AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb;
\echo 'Exact database baseline for the separate DiskANN hypertable'
SELECT id,recorded_at,title,cosine_distance,l2_distance
FROM diskann_exact ORDER BY cosine_distance,id;
\echo 'Exact baseline inside cosine-distance radius 0.6'
SELECT id,recorded_at,title,cosine_distance,l2_distance
FROM diskann_exact WHERE cosine_distance<=0.6 ORDER BY cosine_distance,id;

DO $checks$
DECLARE
    eligible_ids integer[];
BEGIN
    IF (SELECT count(*) FROM ghw_semantic_lab.events_diskann)<>137 THEN
        RAISE EXCEPTION 'Expected 137 actual model embeddings in the DiskANN copy';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables
                   WHERE hypertable_schema='ghw_semantic_lab' AND hypertable_name='events_diskann') THEN
        RAISE EXCEPTION 'DiskANN storage is not a TimescaleDB hypertable';
    END IF;
    IF EXISTS (
        SELECT 1 FROM ghw_semantic_lab.events_diskann AS d
        FULL JOIN ghw_semantic_lab.events AS s USING(recorded_at,id)
        WHERE d.id IS NULL OR s.id IS NULL
           OR d.embedding IS DISTINCT FROM s.embedding
           OR d.description IS DISTINCT FROM s.description
           OR d.metadata IS DISTINCT FROM s.metadata
    ) THEN
        RAISE EXCEPTION 'DiskANN copy differs from actual MiniLM source data';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_index AS i
        JOIN pg_class AS c ON c.oid=i.indexrelid
        JOIN pg_am AS a ON a.oid=c.relam
        WHERE i.indrelid='ghw_semantic_lab.events_diskann'::regclass AND a.amname='hnsw'
    ) THEN
        RAISE EXCEPTION 'The DiskANN-only fixture unexpectedly has an HNSW index';
    END IF;
    SELECT array_agg(id ORDER BY id) INTO eligible_ids FROM diskann_exact;
    IF eligible_ids IS DISTINCT FROM ARRAY[101,102,103,104,105] THEN
        RAISE EXCEPTION 'DiskANN-copy time/metadata filtering failed: %',eligible_ids;
    END IF;
    SELECT array_agg(id ORDER BY id) INTO eligible_ids
    FROM diskann_exact WHERE cosine_distance<=0.6;
    IF eligible_ids IS DISTINCT FROM ARRAY[101,102,103] THEN
        RAISE EXCEPTION 'Measured cosine radius 0.6 did not keep only semantic positives: %',eligible_ids;
    END IF;
    IF EXISTS (
        SELECT 1 FROM diskann_exact AS a FULL JOIN semantic_numpy_reference AS e USING(id)
        WHERE a.id IS NULL OR e.id IS NULL
           OR abs(a.cosine_distance-e.cosine_distance)>0.00001
           OR abs(a.l2_distance-e.l2_distance)>0.00001
    ) THEN
        RAISE EXCEPTION 'DiskANN-copy exact distances differ from real-model NumPy reference';
    END IF;
    RAISE NOTICE 'PASS: copied actual 384D embeddings, separate hypertable, no HNSW, time/metadata filtering, exact NumPy distance reference';
END
$checks$;

-- Official pgvectorscale v0.9.1 syntax. Arbitrary timestamp and JSONB WHERE
-- clauses use streaming post-filtering; label-based filtering is not claimed.
CREATE INDEX IF NOT EXISTS semantic_cosine_diskann
ON ghw_semantic_lab.events_diskann USING diskann(embedding vector_cosine_ops);
ANALYZE ghw_semantic_lab.events_diskann;
SET LOCAL enable_indexscan=on;
SET LOCAL enable_bitmapscan=on;
SET LOCAL enable_seqscan=off;
SET LOCAL enable_sort=off;
SET LOCAL diskann.query_search_list_size=100;
SET LOCAL diskann.query_rescore=400;

-- DiskANN uses relaxed ordering. Materialize up to 20 filtered candidates,
-- then explicitly rerank by exact cosine distance. This fixture has five
-- eligible rows; execution here is not a benchmark or universal recall claim.
\echo 'Actually executed StreamingDiskANN query plan with time, JSONB and cosine-radius filters'
EXPLAIN(ANALYZE,BUFFERS,COSTS OFF,TIMING OFF)
WITH candidates AS MATERIALIZED (
    SELECT id,recorded_at,title,description,metadata,
           embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
    FROM ghw_semantic_lab.events_diskann
    WHERE recorded_at>=TIMESTAMPTZ '2026-10-13 00:00:00+00'
      AND recorded_at<TIMESTAMPTZ '2026-10-14 00:00:00+00'
      AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
    ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
    LIMIT 20
)
SELECT id,recorded_at,title,cosine_distance FROM candidates WHERE cosine_distance<=0.6
ORDER BY cosine_distance+0,id LIMIT 3;

CREATE TEMP TABLE diskann_results AS
WITH candidates AS MATERIALIZED (
    SELECT id,recorded_at,title,description,metadata,
           embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
    FROM ghw_semantic_lab.events_diskann
    WHERE recorded_at>=TIMESTAMPTZ '2026-10-13 00:00:00+00'
      AND recorded_at<TIMESTAMPTZ '2026-10-14 00:00:00+00'
      AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
    ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
    LIMIT 20
)
SELECT * FROM candidates WHERE cosine_distance<=0.6 ORDER BY cosine_distance+0,id LIMIT 3;
\echo 'Actual StreamingDiskANN semantic neighbors after exact reranking'
SELECT id,recorded_at,title,cosine_distance
FROM diskann_results ORDER BY cosine_distance,id;

DO $checks$
DECLARE
    query_plan json;
    actual_ids integer[];
    expected_ids integer[];
BEGIN
    EXECUTE $plan$
        EXPLAIN(FORMAT JSON)
        WITH candidates AS MATERIALIZED (
            SELECT id,embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1) AS cosine_distance
            FROM ghw_semantic_lab.events_diskann
            WHERE recorded_at>=TIMESTAMPTZ '2026-10-13 00:00:00+00'
              AND recorded_at<TIMESTAMPTZ '2026-10-14 00:00:00+00'
              AND metadata @> '{"category":"database","project":"ghw_demo"}'::jsonb
            ORDER BY embedding <=> (SELECT embedding FROM ghw_semantic_lab.queries WHERE id=1)
            LIMIT 20
        ) SELECT id FROM candidates WHERE cosine_distance<=0.6 ORDER BY cosine_distance+0,id LIMIT 3
    $plan$ INTO query_plan;
    IF position('semantic_cosine_diskann' IN query_plan::text)=0 THEN
        RAISE EXCEPTION 'StreamingDiskANN index was not used: %',query_plan;
    END IF;
    SELECT array_agg(id ORDER BY cosine_distance,id) INTO actual_ids FROM diskann_results;
    SELECT array_agg(id ORDER BY cosine_distance,id) INTO expected_ids
    FROM (SELECT * FROM diskann_exact WHERE cosine_distance<=0.6 ORDER BY cosine_distance,id LIMIT 3) AS top3;
    IF actual_ids IS DISTINCT FROM expected_ids THEN
        RAISE EXCEPTION 'DiskANN result order differs from exact SQL baseline: % vs %',actual_ids,expected_ids;
    END IF;
    IF EXISTS (
        SELECT 1 FROM diskann_results AS a
        FULL JOIN (SELECT * FROM diskann_exact WHERE cosine_distance<=0.6 ORDER BY cosine_distance,id LIMIT 3) AS e USING(id)
        WHERE a.id IS NULL OR e.id IS NULL OR abs(a.cosine_distance-e.cosine_distance)>0.00001
    ) THEN
        RAISE EXCEPTION 'DiskANN neighbors/distances differ from exact SQL baseline';
    END IF;
    RAISE NOTICE 'PASS: actual StreamingDiskANN plan, time/metadata/cosine-radius-filtered IDs and distances match exact semantic baseline';
END
$checks$;

INSERT INTO ghw_semantic_lab.retrieval_runs(id,executed_at,context)
SELECT 2,current_timestamp,jsonb_build_object(
    'question',(SELECT query_text FROM ghw_semantic_lab.queries WHERE id=1),
    'model',(SELECT provenance->>'model' FROM ghw_semantic_lab.queries WHERE id=1),
    'revision',(SELECT provenance->>'revision' FROM ghw_semantic_lab.queries WHERE id=1),
    'dimensions',384,
    'index','pgvectorscale StreamingDiskANN',
    'fixture_source','authored synthetic events; dates are teaching fixtures',
    'time_window',jsonb_build_object('start_inclusive','2026-10-13T00:00:00Z','end_exclusive','2026-10-14T00:00:00Z'),
    'metadata_filter',jsonb_build_object('category','database','project','ghw_demo'),
    'distance_filter',jsonb_build_object('metric','cosine distance','maximum_inclusive',0.6),
    'ordering','materialized filtered DiskANN candidates, then exact cosine reranking',
    'purpose','RAG-ready retrieved context; no language-model answer generation is claimed',
    'passages',jsonb_agg(jsonb_build_object('id',id,'recorded_at',recorded_at,'title',title,
                'description',description,'metadata',metadata,'cosine_distance',cosine_distance)
                ORDER BY cosine_distance,id)
)
FROM diskann_results
ON CONFLICT(id) DO UPDATE SET executed_at=EXCLUDED.executed_at,context=EXCLUDED.context;
SELECT jsonb_pretty(context) FROM ghw_semantic_lab.retrieval_runs WHERE id=2;
COMMIT;
\echo 'DISKANN LAB COMPLETE: actual pgvector + pgvectorscale semantic search verified'
