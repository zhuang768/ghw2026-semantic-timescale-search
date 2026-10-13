"""Download only public model data; do not request a token or execute remote code."""
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
FILES = [
    "config.json", "tokenizer.json", "tokenizer_config.json",
    "special_tokens_map.json", "vocab.txt", "model.safetensors",
    "1_Pooling/config.json", "modules.json", "config_sentence_transformers.json",
    "sentence_bert_config.json", "README.md",
]


def get(url):
    request = Request(url, headers={"User-Agent": "ghw2026-public-model-lab/1.0"})
    return urlopen(request, timeout=120)


def main():
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    model_dir = ROOT / "model"
    model_dir.mkdir(exist_ok=True)
    manifest_path = evidence / "model-manifest.json"
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        revision = previous["revision"]
    else:
        previous = {}
        with get("https://huggingface.co/api/models/" + MODEL_ID) as response:
            metadata = json.load(response)
        revision = metadata["sha"]
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
        raise ValueError("Model revision must be a full SHA-1 commit ID")

    manifest = {"model_id": MODEL_ID, "revision": revision, "license": "Apache-2.0", "files": []}
    # Pin the revision before the first large transfer, including interrupted runs.
    if not manifest_path.exists():
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    expected_files = {item["name"]: item["sha256"] for item in previous.get("files", [])}
    for name in FILES:
        destination = model_dir / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        url = "https://huggingface.co/" + MODEL_ID + "/resolve/" + revision + "/" + name
        if not destination.exists():
            print("Downloading public model file:", name, flush=True)
            partial = destination.with_name(destination.name + ".download")
            with get(url) as response, partial.open("wb") as output:
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    output.write(block)
            partial.replace(destination)
        file_bytes = destination.read_bytes()
        actual_sha256 = hashlib.sha256(file_bytes).hexdigest()
        if name in expected_files and actual_sha256 != expected_files[name]:
            raise ValueError("Existing model file does not match its recorded SHA256: " + name)
        if name == "model.safetensors" and len(file_bytes) < 1_000_000:
            raise ValueError("Downloaded model weights are unexpectedly small")
        item = {"name": name, "bytes": len(file_bytes), "sha256": actual_sha256, "source_url": url}
        manifest["files"].append(item)
        print(name, item["bytes"], item["sha256"], flush=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print("Public model revision:", revision, flush=True)


if __name__ == "__main__":
    main()
