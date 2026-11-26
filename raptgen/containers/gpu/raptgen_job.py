#!/usr/bin/env python3
"""raptgen-job: stage input from S3, train RaptGen, encode, upload results.

Runs inside the aptamer-raptgen images (CPU and GPU) as an AWS Batch job.

  raptgen-job train --output s3://<bucket>/raptgen/<run-id>/ \
      [--input s3://bucket/key.fastq | builtin:A_4R | builtin:sample] \
      [--epochs N] [--threshold N] [--min-count N] [--device cpu|cuda]

Every option can also come from an environment variable (Batch jobs pass
parameters that way): RAPTGEN_OUTPUT, RAPTGEN_INPUT, RAPTGEN_EPOCHS,
RAPTGEN_THRESHOLD, RAPTGEN_MIN_COUNT, RAPTGEN_DEVICE, RAPTGEN_RUN_ID.

Uploaded to <output>/: model (cnn_phmm_vae.mdl), loss CSV (cnn_phmm_vae.csv),
encoded sequences (embed_seq.csv), train.log, run.json. `--dry-run` skips S3
(local directory via --local-out) so the wrapper can be tested without AWS.

Upstream scripts/real.py and scripts/encode.py run unchanged.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

RG = Path(os.environ.get("RAPTGEN_HOME", "/opt/raptgen"))
BUILTIN = {
    "A_4R": RG / "data" / "real" / "A_4R.fastq",
    "sample": RG / "data" / "sample" / "sample.fasta",
}
S3_URI = re.compile(r"^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.+)$")
S3_PREFIX = re.compile(r"^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.*)$")
RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def log(msg):
    print(f"[raptgen-job] {msg}", flush=True)


def env_default(name, default=None):
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def s3_client():
    import boto3  # imported late: smoke/dry-run never needs it

    return boto3.client("s3")


def stage_input(spec, dest_dir):
    """Return (local_path, source_description)."""
    if spec in BUILTIN:
        spec = f"builtin:{spec}"
    if spec.startswith("builtin:"):
        name = spec.split(":", 1)[1]
        if name not in BUILTIN or not BUILTIN[name].is_file():
            sys.exit(f"unknown or missing built-in dataset: {name} (have: {sorted(k for k, v in BUILTIN.items() if v.is_file())})")
        return BUILTIN[name], spec
    m = S3_URI.match(spec)
    if not m:
        sys.exit("--input must be s3://bucket/key, builtin:A_4R or builtin:sample")
    bucket, key = m.groups()
    suffix = Path(key).suffix.lower()
    if suffix not in (".fastq", ".fq", ".fasta", ".fa", ".gz"):
        sys.exit("input key must end in .fastq/.fq/.fasta/.fa")
    if suffix == ".gz":
        sys.exit("gzip input is not supported by upstream real.py; decompress first")
    dest = Path(dest_dir) / ("input" + suffix)
    log(f"downloading s3://{bucket}/{key}")
    s3_client().download_file(bucket, key, str(dest))
    return dest, f"s3://{bucket}/{key}"


def run_logged(cmd, log_path, cwd):
    log("run: " + " ".join(cmd))
    with open(log_path, "ab") as out:
        proc = subprocess.run(cmd, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        tail = Path(log_path).read_bytes().decode(errors="replace").splitlines()[-30:]
        print("\n".join(tail), file=sys.stderr)
        sys.exit(f"command failed ({proc.returncode}): {cmd[1] if len(cmd) > 1 else cmd[0]}")


def versions():
    import torch

    info = {
        "python": platform.python_version(),
        "torch": torch.__version__,
        "torch_cuda_build": torch.version.cuda,
        "cuda_available": torch.cuda.is_available(),
        "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        "cpu_count": os.cpu_count(),
    }
    try:
        info["source_commit"] = (RG / ".source-commit").read_text().strip()
    except OSError:
        pass
    try:
        info["cpu_model"] = next(
            l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")
        )
    except (OSError, StopIteration):
        pass
    return info


def upload(files, output, run_id):
    m = S3_PREFIX.match(output)
    bucket, prefix = m.groups()
    prefix = prefix.rstrip("/")
    client = s3_client()
    for path in files:
        key = f"{prefix}/{path.name}"
        log(f"upload {path.name} -> s3://{bucket}/{key}")
        client.upload_file(str(path), bucket, key, ExtraArgs={"ServerSideEncryption": "AES256"})


def cmd_train(args):
    run_id = args.run_id or env_default("RAPTGEN_RUN_ID") or env_default("AWS_BATCH_JOB_ID") or time.strftime("run-%Y%m%d-%H%M%S")
    if not RUN_ID.match(run_id):
        sys.exit("run id must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    output = args.output or env_default("RAPTGEN_OUTPUT")
    if not args.local_out:
        if not output or not S3_PREFIX.match(output):
            sys.exit("--output (or RAPTGEN_OUTPUT) must be s3://bucket/prefix/")
    spec = args.input or env_default("RAPTGEN_INPUT", "builtin:A_4R")
    epochs = int(args.epochs or env_default("RAPTGEN_EPOCHS", "50"))
    threshold = int(args.threshold or env_default("RAPTGEN_THRESHOLD", "50"))
    min_count = int(args.min_count or env_default("RAPTGEN_MIN_COUNT", "2"))
    device = args.device or env_default("RAPTGEN_DEVICE", "cpu")
    if device not in ("cpu", "cuda"):
        sys.exit("--device must be cpu or cuda")
    if not (1 <= epochs <= 5000 and 1 <= threshold <= 5000 and 1 <= min_count <= 1000):
        sys.exit("epochs/threshold/min-count out of range")

    work = Path(env_default("RAPTGEN_WORKDIR", "/tmp/raptgen-job")) / run_id
    shutil.rmtree(work, ignore_errors=True)
    (work / "in").mkdir(parents=True)
    (work / "train").mkdir()
    (work / "encode").mkdir()
    (work / "cwd").mkdir()
    (work / "out").mkdir()
    train_log = work / "out" / "train.log"

    import torch

    if device == "cuda" and not torch.cuda.is_available():
        sys.exit("device=cuda requested but no CUDA device is visible (GPU queue/image?)")
    flag = "--use-cuda" if device == "cuda" else "--no-cuda"

    started = time.time()
    seq_path, source = stage_input(spec, work / "in")
    input_sha = sha256(seq_path)
    py = sys.executable
    t0 = time.time()
    run_logged([py, str(RG / "scripts" / "real.py"), str(seq_path), "--epochs", str(epochs),
                "--threshold", str(threshold), "--min-count", str(min_count), flag,
                "--save-dir", str(work / "train")], train_log, work / "cwd")
    train_seconds = time.time() - t0
    model = work / "train" / "cnn_phmm_vae.mdl"
    loss = work / "train" / "cnn_phmm_vae.csv"
    if not model.is_file() or not loss.is_file():
        sys.exit("training did not produce cnn_phmm_vae.mdl/.csv")
    t0 = time.time()
    run_logged([py, str(RG / "scripts" / "encode.py"), str(seq_path), str(model), flag,
                "--save-dir", str(work / "encode")], train_log, work / "cwd")
    encode_seconds = time.time() - t0
    embed = work / "encode" / "embed_seq.csv"

    out = work / "out"
    for src in (model, loss, embed):
        shutil.copy2(src, out / src.name)
    rows = max(0, sum(1 for _ in open(loss)) - 1)
    record = {
        "run_id": run_id,
        "status": "SUCCEEDED",
        "input": {"source": source, "sha256": input_sha},
        "params": {"epochs": epochs, "threshold": threshold, "min_count": min_count, "device": device},
        "epochs_logged": rows,
        "train_seconds": round(train_seconds, 1),
        "encode_seconds": round(encode_seconds, 1),
        "total_seconds": round(time.time() - started, 1),
        "files": {p.name: sha256(p) for p in (out / "cnn_phmm_vae.mdl", out / "cnn_phmm_vae.csv", out / "embed_seq.csv")},
        "versions": versions(),
        "science_note": "Model trained with the given epochs; quality is not evaluated by this job.",
    }
    (out / "run.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    files = sorted(out.iterdir())
    if args.local_out:
        dest = Path(args.local_out)
        dest.mkdir(parents=True, exist_ok=True)
        for p in files:
            shutil.copy2(p, dest / p.name)
        log(f"results copied to {dest}")
    else:
        upload(files, output, run_id)
        log(f"results: {output.rstrip('/')}/")
    print(json.dumps({"event": "done", "run_id": run_id, "status": "SUCCEEDED"}), flush=True)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="raptgen-job", description=__doc__.split("\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("train", help="train + encode, upload to S3")
    t.add_argument("--input")
    t.add_argument("--output")
    t.add_argument("--run-id")
    t.add_argument("--epochs")
    t.add_argument("--threshold")
    t.add_argument("--min-count")
    t.add_argument("--device", choices=["cpu", "cuda"])
    t.add_argument("--local-out", help="copy results here instead of S3 (testing)")
    t.set_defaults(func=cmd_train)
    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
