# Actual StreamingDiskANN verification

`diskann.sql` completed successfully using PostgreSQL 17.7, TimescaleDB 2.22.1, pgvector 0.8.1, and the official pgvectorscale 0.9.1 extension. Both assertion blocks passed and the transaction committed. The actual executed plan used `_hyper_5_19_chunk_semantic_cosine_diskann`; the run began at `2026-10-13T19:02:01.693476Z`.

The [captured SQL execution](evidence/diskann-output.txt) includes real extension versions, index construction, the executed `EXPLAIN (ANALYZE, BUFFERS)`, results, and assertions. The [database readback](evidence/diskann-state.json) confirms 137 copied model vectors across four Timescale chunks, one DiskANN index on the hypertable, zero HNSW indexes, the execution timestamp, and retrieved context. The script stops before changing the fixture if `vectorscale` is absent.

After `semantic.sql` stored the actual local MiniLM model outputs, this test copied all 137 timestamped vectors and their JSONB metadata into a separate TimescaleDB hypertable, `ghw_semantic_lab.events_diskann`. The copy has no HNSW index. It created a real index using the official syntax:

```sql
CREATE INDEX semantic_cosine_diskann
ON ghw_semantic_lab.events_diskann
USING diskann (embedding vector_cosine_ops);
```

The search uses the same 384-dimensional model-generated query vector, half-open UTC time window, and JSONB category/project filters as the earlier exact and HNSW tests. It also applies a real SQL cosine-distance radius predicate, `cosine_distance <= 0.6`. This threshold comes from the already measured exact distances: the three semantic positives are approximately `0.497, 0.502, 0.514`; unrelated passages are approximately `0.833, 0.933`.

A sequential-scan baseline on the copied data matched the independent NumPy reference and confirmed that the radius includes only IDs `101, 102, 103`. The executed `EXPLAIN (ANALYZE, BUFFERS)` and JSON-plan assertion showed the DiskANN index. It scanned five eligible candidates after the time and metadata filters, then the radius rejected two unrelated passages. Returned IDs `101, 102, 103` and cosine distances `0.4974563418302731, 0.5021783412801222, 0.5140982431857205` matched the exact SQL baseline.

pgvectorscale uses relaxed index ordering. The query therefore materializes up to 20 candidates with the time and metadata filters, then applies the distance radius and reranks by exact cosine distance. This fixture has five eligible records before the radius and three afterward. Local query parameters are `diskann.query_search_list_size=100` and `diskann.query_rescore=400`; all planner and tuning settings reset at transaction completion. This demonstrates an actual index path on a small controlled fixture, not benchmark performance or general exact recall. Candidate limits can affect recall on larger datasets and must be tuned there.

Timestamp and JSONB filters use arbitrary WHERE-clause streaming post-filtering. No label-based index filtering is claimed. No global configuration, external service, account, credential, or paid resource is used.

Reproduce only after the runner has installed the official extension:

```sh
psql -X -v ON_ERROR_STOP=1 -d YOUR_ISOLATED_LAB_DATABASE -f diskann.sql
```

Primary syntax reference: [official pgvectorscale v0.9.1 README](https://github.com/timescale/pgvectorscale/blob/0.9.1/README.md). This reference was also read from the downloaded versioned source in the isolated lab.

The live dashboard's fixed read-only SQL was also checked after this run. Both queries reported `transaction_read_only=on`, the copied vectors had zero mismatches, the DiskANN index was present, and the current copy neighbors matched the current pgvector results. The HTTP server and actual Safari rendering are handled separately by the runner.
