# GHW 2026 — semantic search in TimescaleDB

This project actually ran a local MiniLM transformer on CPU, stored its 384-dimensional embeddings in a TimescaleDB hypertable, and searched them inside PostgreSQL using pgvector and pgvectorscale StreamingDiskANN. All event descriptions and timestamps are teaching fixtures. Code and tests were prepared with Codex; no Copilot authorship, Tiger Cloud service, generated LLM answer, or event acceptance is claimed.

Actual runtime: PostgreSQL 17.7, TimescaleDB 2.22.1, pgvector 0.8.1 and pgvectorscale 0.9.1, built in an isolated directory on macOS ARM. The database has TCP listening and TimescaleDB telemetry disabled; it uses a private local Unix socket and no persistent password.

The official public model is `sentence-transformers/all-MiniLM-L6-v2`, pinned to revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`. Safetensors weights are hashed and loaded locally with remote code disabled. CPU inference produced 137 corpus embeddings and one query embedding. The repository publishes generated SQL vectors and provenance; it excludes model weights, caches, runtime files and raw private-path logs.

Time bounds, JSONB category/project metadata, and `cosine_distance <= 0.6` jointly filter the search. Actual exact SQL, HNSW and StreamingDiskANN return IDs `101, 102, 103` with cosine distances `0.49745634, 0.50217834, 0.51409824`. PostgreSQL distances match independent NumPy measurements. Four exact-query matches are excluded because they violate time or metadata scope. The actual DiskANN plan retrieves five eligible candidates and the radius excludes two unrelated passages.

- [SEMANTIC.md](SEMANTIC.md): model inference, exact SQL/HNSW and RAG context.
- [DISKANN.md](DISKANN.md): genuine pgvectorscale index, radius filtering and exact comparison.
- [evidence/semantic-output.txt](evidence/semantic-output.txt) and [evidence/diskann-output.txt](evidence/diskann-output.txt): complete actual SQL execution evidence.
- [evidence/model-manifest.json](evidence/model-manifest.json): official model revision and hashes.
- [evidence/final-state.json](evidence/final-state.json): post-DiskANN actual database state.
- [evidence/dashboard-http-check.json](evidence/dashboard-http-check.json): live read-only HTTP checks.

These are small controlled tests. Forced planner paths demonstrate actual indexes; no general speed, semantic quality or approximate-recall guarantee is claimed. Recorded query plans and current live reads are labeled separately.

## Reproduce on macOS ARM

With a compiler, make, Python 3, tar and existing OpenSSL/zlib development headers:

```bash
bash build-local.sh
bash build-pgvectorscale.sh
python3 -m venv .venv
.venv/bin/python -m pip --isolated install --cache-dir cache/pip --only-binary=:all: -r requirements-lock.txt
.venv/bin/python download_model.py
.venv/bin/python generate_embeddings.py
bash run-local.sh
python3 serve-semantic.py
```

The live dashboard binds only `127.0.0.1:8790` and executes fixed, read-only SQL with query timestamps. It accepts no HTTP SQL, filters, filenames or commands. After viewing it, press Ctrl-C to stop the dashboard, then run `runtime/bin/pg_ctl -D db-data stop`.

If `run-local.sh` fails after starting PostgreSQL, inspect `evidence/reproduced-semantic-output.txt` and `evidence/reproduced-diskann-output.txt`, then stop the dedicated database with `runtime/bin/pg_ctl -D db-data stop`. Failed runs preserve database files for inspection; they do not delete prior data.

All installed tools, downloaded source/model files, database storage and build caches stay in this directory. Rustup 1.29.1, Rust 1.91.0 and cargo-pgrx 0.16.1 are pinned; no global package install or shell-profile change is used. The build loads the official pgvectorscale project's committed macOS linker configuration. See [build provenance](evidence/build-provenance.json) and the included Cargo lockfile. PostgreSQL's archive matched its official published checksum; the other source hashes record the exact downloaded archives.

Use a dedicated disposable database. SQL changes only this fixture's schema; it does not drop other database data. `evidence/database-state.json` is the historical pre-DiskANN readback; `final-state.json` and `diskann-state.json` record the completed extension phase. Event screenshots and submission receipts are captured separately in Safari by the submitter.
