"""Real local MiniLM inference, followed by SQL fixture serialization."""
import hashlib
import importlib.metadata
import json
import os
import platform
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
os.environ["HF_HOME"] = str(ROOT / "cache" / "huggingface")
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModel, AutoTokenizer

QUERY = "What caused database requests to become slow and which changes made them fast again?"
DESCRIPTIONS = [
    (101, "2026-10-13 09:00:00+00", "Missing database index", "Slow PostgreSQL queries were caused by a missing index on the customer_id column. Adding a B-tree index reduced query latency from 900 milliseconds to 40 milliseconds."),
    (102, "2026-10-13 00:00:00+00", "Report scan optimization", "The SQL dashboard returned late because a report scanned every row. Adding an index and rewriting the filter improved database query performance."),
    (103, "2026-10-13 23:59:59+00", "Lock contention resolved", "Contention for table locks stalled requests to PostgreSQL. Breaking up one long transaction restored fast responses."),
    (104, "2026-10-13 10:00:00+00", "Backup recovery drill", "The nightly PostgreSQL backup completed successfully. The recovery drill restored a database copy in a staging instance."),
    (105, "2026-10-13 11:00:00+00", "Documentation color update", "The documentation website theme changed from blue to green. The designers made chart labels larger and updated the illustrations."),
]


def make_inputs():
    rows = []
    for row_id, timestamp, title, text in DESCRIPTIONS:
        rows.append({"id": row_id, "recorded_at": timestamp, "title": title, "text": text,
                     "metadata": {"category": "database", "project": "ghw_demo", "source": "authored_synthetic_fixture"}})
    # Exact query text is intentionally a stronger semantic match. Each copy
    # violates one filter and must be excluded by the real database query.
    excluded = [
        (201, "2026-10-12 23:59:59+00", "Before lower time bound", "database", "ghw_demo"),
        (202, "2026-10-14 00:00:00+00", "At excluded upper time bound", "database", "ghw_demo"),
        (203, "2026-10-13 12:00:00+00", "Wrong category", "frontend", "ghw_demo"),
        (204, "2026-10-13 12:30:00+00", "Wrong project", "database", "another_demo"),
    ]
    for row_id, timestamp, title, category, project in excluded:
        rows.append({"id": row_id, "recorded_at": timestamp, "title": title, "text": QUERY,
                     "metadata": {"category": category, "project": project, "source": "authored_synthetic_fixture"}})
    for n in range(1, 129):
        rows.append({"id": 10000 + n, "recorded_at": "2026-10-11 12:00:00+00",
                     "title": "Community fixture " + str(n),
                     "text": "Community announcement number " + str(n) + ": the cafeteria shared a new lunch menu and the gardening club planted flowers.",
                     "metadata": {"category": "community", "project": "ghw_demo", "source": "authored_synthetic_fixture"}})
    return {"query": QUERY, "window": {"start_inclusive": "2026-10-13 00:00:00+00", "end_exclusive": "2026-10-14 00:00:00+00"},
            "metadata_filter": {"category": "database", "project": "ghw_demo"}, "rows": rows}


def sql_literal(text):
    return "'" + text.replace("'", "''") + "'"


def vector_literal(vector):
    return "'[" + ",".join(format(float(component), ".9g") for component in vector) + "]'::vector(384)"


def main():
    evidence = ROOT / "evidence"
    generated = ROOT / "generated"
    evidence.mkdir(exist_ok=True)
    generated.mkdir(exist_ok=True)
    model_manifest = json.loads((evidence / "model-manifest.json").read_text())
    for item in model_manifest["files"]:
        actual = hashlib.sha256((ROOT / "model" / item["name"]).read_bytes()).hexdigest()
        if actual != item["sha256"]:
            raise ValueError("Model file hash changed: " + item["name"])

    inputs = make_inputs()
    input_bytes = (json.dumps(inputs, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    (evidence / "inputs.json").write_bytes(input_bytes)
    input_sha256 = hashlib.sha256(input_bytes).hexdigest()
    texts = [row["text"] for row in inputs["rows"]] + [QUERY]
    torch.set_num_threads(2)
    torch.manual_seed(0)
    torch.use_deterministic_algorithms(True)
    tokenizer = AutoTokenizer.from_pretrained(ROOT / "model", local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(ROOT / "model", local_files_only=True, trust_remote_code=False, use_safetensors=True)
    model = model.to("cpu").eval()
    start = time.monotonic()
    output_batches = []
    with torch.inference_mode():
        for offset in range(0, len(texts), 16):
            encoded = tokenizer(texts[offset:offset + 16], padding=True, truncation=True, max_length=256, return_tensors="pt")
            hidden = model(**encoded).last_hidden_state
            mask = encoded["attention_mask"].unsqueeze(-1).expand(hidden.size()).float()
            pooled = torch.sum(hidden * mask, 1) / torch.clamp(mask.sum(1), min=1e-9)
            output_batches.append(F.normalize(pooled, p=2, dim=1).cpu().numpy())
    embeddings = np.concatenate(output_batches).astype(np.float32)
    assert embeddings.shape == (138, 384), embeddings.shape
    assert np.isfinite(embeddings).all()
    assert np.allclose(np.linalg.norm(embeddings, axis=1), 1, atol=1e-5)
    query_embedding = embeddings[-1]
    corpus_embeddings = embeddings[:-1]
    cosine = 1 - ((corpus_embeddings @ query_embedding) /
                  (np.linalg.norm(corpus_embeddings, axis=1) * np.linalg.norm(query_embedding)))
    l2 = np.linalg.norm(corpus_embeddings - query_embedding, axis=1)
    eligible = list(range(5))
    ordering = sorted(eligible, key=lambda i: (float(cosine[i]), inputs["rows"][i]["id"]))
    top_ids = [inputs["rows"][i]["id"] for i in ordering[:3]]
    if set(top_ids) != {101, 102, 103}:
        raise ValueError("Paraphrase positives failed to outrank unrelated fixtures: " + str(top_ids))

    metadata = {"model": model_manifest["model_id"], "revision": model_manifest["revision"],
                "dimensions": 384, "pooling": "attention-mask-aware mean pooling", "normalization": "L2", "device": "cpu",
                "python": platform.python_version(), "package_versions": {name: importlib.metadata.version(name) for name in ["torch", "transformers", "numpy", "safetensors", "tokenizers", "huggingface-hub"]},
                "input_sha256": input_sha256, "corpus_count": len(inputs["rows"]), "embedding_count_including_query": len(embeddings),
                "inference_seconds": time.monotonic() - start,
                "embedding_array_float32_sha256": hashlib.sha256(embeddings.tobytes()).hexdigest(),
                "mean_embedding_norm": float(np.mean(np.linalg.norm(embeddings, axis=1))),
                "filtered_top3_ids_numpy_reference": top_ids}
    (evidence / "inference-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    references = [{"id": inputs["rows"][i]["id"], "cosine_distance": float(cosine[i]), "l2_distance": float(l2[i])} for i in ordering]
    (evidence / "numpy-reference.json").write_text(json.dumps(references, indent=2) + "\n")
    np.save(evidence / "embeddings.npy", embeddings, allow_pickle=False)

    statements = ["-- Generated from actual local MiniLM CPU inference; do not hand-edit vectors."]
    statements.append("INSERT INTO ghw_semantic_lab.queries (id, query_text, embedding, provenance) VALUES (1, " +
                      sql_literal(QUERY) + ", " + vector_literal(query_embedding) + ", " + sql_literal(json.dumps(metadata)) + "::jsonb) ON CONFLICT (id) DO UPDATE SET query_text=EXCLUDED.query_text,embedding=EXCLUDED.embedding,provenance=EXCLUDED.provenance;")
    for i, row in enumerate(inputs["rows"]):
        row_metadata = dict(row["metadata"], embedding_model=model_manifest["model_id"], dimensions=384)
        values = [sql_literal(row["recorded_at"]), str(row["id"]), sql_literal(row["title"]), sql_literal(row["text"]),
                  vector_literal(corpus_embeddings[i]), sql_literal(json.dumps(row_metadata)) + "::jsonb"]
        statements.append("INSERT INTO ghw_semantic_lab.events (recorded_at,id,title,description,embedding,metadata) VALUES (" + ",".join(values) + ") ON CONFLICT (recorded_at,id) DO UPDATE SET title=EXCLUDED.title,description=EXCLUDED.description,embedding=EXCLUDED.embedding,metadata=EXCLUDED.metadata;")
    fixture_sql = "\n".join(statements) + "\n"
    (generated / "embeddings.sql").write_text(fixture_sql)
    reference_sql = ["CREATE TEMP TABLE semantic_numpy_reference (id integer PRIMARY KEY, cosine_distance double precision, l2_distance double precision);"]
    for row in references:
        reference_sql.append("INSERT INTO semantic_numpy_reference VALUES ({id},{cosine_distance:.17g},{l2_distance:.17g});".format(**row))
    (generated / "reference.sql").write_text("\n".join(reference_sql) + "\n")
    (evidence / "generated-sha256.json").write_text(json.dumps({"generated/embeddings.sql": hashlib.sha256(fixture_sql.encode()).hexdigest(),
        "generated/reference.sql": hashlib.sha256((generated / "reference.sql").read_bytes()).hexdigest(),
        "inputs.json": input_sha256}, indent=2) + "\n")
    print(json.dumps(metadata, indent=2), flush=True)
    print("Eligible cosine/L2 NumPy reference:", json.dumps(references), flush=True)
    print("Generated SQL from actual 384-dimensional model output.", flush=True)


if __name__ == "__main__":
    main()
