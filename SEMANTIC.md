# Time-constrained semantic retrieval with real 384-dimensional embeddings

This lab uses the public [sentence-transformers/all-MiniLM-L6-v2 model](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2), executing its transformer locally on CPU. Attention-mask-aware mean pooling and L2 normalization follow the model card. The generated vectors and query vector have 384 dimensions and are stored in a real TimescaleDB hypertable with pgvector.

All event descriptions and timestamps are authored teaching fixtures, not observed incidents or private data.

## Reproduce in an isolated lab

```sh
python3 -m venv .venv
.venv/bin/python -m pip --isolated install --only-binary=:all: -r requirements.txt
.venv/bin/python download_model.py
.venv/bin/python generate_embeddings.py
psql -X -v ON_ERROR_STOP=1 -d YOUR_ISOLATED_LAB_DATABASE -f semantic.sql
```

The downloader resolves the official public model repository to a complete commit revision and records SHA256 hashes for its safetensors weights, config, tokenizer, pooling config, and model card. It uses no authentication. Inference loads only the downloaded local files with `local_files_only=True`, `trust_remote_code=False`, and `use_safetensors=True`; caches and packages stay in this directory. No global configuration is modified.

The generation step saves input text, input SHA256, package versions, model revision, CPU device, embedding array hash, generated SQL hashes, and an independent NumPy distance reference. Database distances and results must pass assertions against that reference. The NumPy values are a cross-check; PostgreSQL performs the submitted similarity searches. On reruns, the downloader checks existing model files against the recorded hashes, and the SQL updates this dedicated fixture's model provenance, vectors, and retrieved context to reflect the current inference run.

## Retrieval scenario and checks

The question asks what caused slow database requests and which changes restored speed. Three passages describe missing indexes, report scans, and lock contention using different wording. Backup and design-update passages serve as unrelated or weaker examples. The filtered top three must be the three incident passages.

Four stronger matches contain the exact query text but deliberately violate the lower timestamp bound, upper timestamp bound, category, or project. They must be excluded. The SQL uses a half-open UTC window (`>= start AND < end`) and JSONB containment to select five eligible passages.

`semantic.sql` verifies real hypertable storage, 384-dimensional normalized embeddings, cosine and L2 ranking, distances against actual model output using NumPy, the unit-vector relationship `L2² ≈ 2 × cosine_distance`, and exclusion of stronger matches outside the allowed time/metadata scope. It executes and captures both exact-scan and HNSW plans, then compares the three HNSW results to the exact database baseline.

Planner settings used to demonstrate HNSW are transaction-local. This small fixture is not a performance benchmark, and HNSW agreement here is not a guarantee of exact recall for other datasets.

The database also stores a RAG-ready context object with the retrieved text, timestamps, metadata, and distances. No generated answer or external LLM call is claimed.

## Execution status

Actual local CPU inference and database execution completed successfully with Python 3.9.6, PyTorch 2.6.0, Transformers 4.51.3, PostgreSQL 17.7, TimescaleDB 2.22.1, and pgvector 0.8.1. The official model revision is `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`.

Both SQL assertion blocks passed and the transaction committed. The actual query plan used `_hyper_4_15_chunk_semantic_cosine_hnsw`. The exact and HNSW searches both returned IDs `101, 102, 103`; their SQL cosine distances were approximately `0.49745634, 0.50217834, 0.51409824`. The unrelated design and backup passages ranked below all three incident passages. All four stronger exact-query matches had distance `0` and were correctly excluded by the time or metadata filters.

Evidence includes [model hashes](evidence/model-manifest.json), [inference provenance](evidence/inference-manifest.json), [input text](evidence/inputs.json), [independent distance reference](evidence/numpy-reference.json), [actual database execution](evidence/semantic-output.txt), [retrieved context read back from PostgreSQL](evidence/retrieval-context.json), and [historical pre-DiskANN database state](evidence/database-state.json). The successful rerun transaction began at `2026-10-13T18:37:21.961487Z`.

The first run and a rerun both passed. The rerun refreshed database provenance and retrieved context from the current model output. The [public inference transcript](evidence/inference-output-public.txt) preserves the actual log with only the local workspace path replaced by `<semantic-lab>`. `publish-manifest.json` lists the clean source/evidence files and their hashes; the virtual environment, caches, model weights, NumPy binary, and raw local-path transcript are excluded from publication.

The subsequent [StreamingDiskANN phase](DISKANN.md) also completed using the official pgvectorscale 0.9.1 extension. It copied the actual 384-dimensional model vectors into a separate TimescaleDB hypertable, used a real DiskANN index, and applied time, metadata, and `cosine_distance <= 0.6` filters. The actual index plan and three result distances matched the exact database baseline. This remains a self-hosted lab; no Tiger Cloud service or generated LLM answer is claimed.

## Live read-only dashboard

`serve-semantic.py` and `semantic-dashboard.html` provide fixed local routes `/` and `/api/status`, binding only `127.0.0.1:8790`. The SQL readout has been directly checked against the actual database, including `transaction_read_only=on`, 384 dimensions, 137 corpus rows, and three neighbors inside the cosine radius. After the successful DiskANN run, both fixed SQL reads reported read-only transactions, zero copied-vector mismatches, the installed DiskANN index, and identical current neighbor IDs/distances. This readout is captured in [dashboard-readonly-state.json](evidence/dashboard-readonly-state.json). The HTTP server was subsequently started for live verification; the current HTTP checks are recorded separately in evidence/dashboard-http-check.json. Safari screenshot verification belongs to the submitter.

After the lab runner is ready, start it from this folder with:

```sh
python3 serve-semantic.py
```

The default executable uses `runtime/bin/psql` beside the script when present, otherwise `../runtime/bin/psql`. `--psql` accepts an explicit binary path for another installation. Every API refresh runs only fixed read-only SQL; no HTTP parameters select SQL, commands, files, or filters. DiskANN copy reads occur only after its extension, table, and recorded completed run exist. Recorded verification and current live reads are shown separately.
