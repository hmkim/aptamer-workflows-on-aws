#!/usr/bin/env bash
# RaptGen CPU vs GPU training benchmark (modern-gpu image). Not a science test.
#
# Trains scripts/real.py on the upstream HT-SELEX file data/real/A_4R.fastq
# (RaptGen paper dataset A, 80,864 reads) for a FIXED number of epochs
# (early stopping disabled) and prints one JSON line per run plus a summary.
# Upstream real.py is not changed; only --epochs/--threshold/--reg-epochs/
# --min-count and --use-cuda/--no-cuda differ between runs.
#
# Env:
#   BENCH_DEVICES   space list of cpu|cuda      (default "cpu cuda")
#   BENCH_MINCOUNTS space list of --min-count   (default "2 1")
#   BENCH_EPOCHS    fixed epochs per run        (default 5)
#   BENCH_OUT       output dir                  (default /tmp/bench)
set -euo pipefail
set +x

RG="${RAPTGEN_HOME:-/opt/raptgen}"
DATA="${RG}/data/real/A_4R.fastq"
DEVICES="${BENCH_DEVICES:-cpu cuda}"
MINCOUNTS="${BENCH_MINCOUNTS:-2 1}"
EPOCHS="${BENCH_EPOCHS:-5}"
OUT="${BENCH_OUT:-/tmp/bench}"
[[ "${EPOCHS}" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "BENCH_EPOCHS must be 1..999" >&2; exit 2; }
mkdir -p "${OUT}" "${HOME:-/tmp/home}" "${MPLCONFIGDIR:-/tmp/mpl}"

python - <<'PY'
import json, os, platform, torch
info = {
    "event": "env",
    "torch": torch.__version__,
    "torch_cuda_build": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "cpu_threads": torch.get_num_threads(),
    "cpu_count": os.cpu_count(),
    "cpu_model": next((l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")), None),
    "python": platform.python_version(),
}
print(json.dumps(info), flush=True)
PY
printf '{"event":"input","sha256":"%s","file":"data/real/A_4R.fastq"}\n' "$(sha256sum "${DATA}" | cut -d" " -f1)"

for mc in ${MINCOUNTS}; do
  for dev in ${DEVICES}; do
    case "${dev}" in
      cpu) flag=--no-cuda ;;
      cuda) flag=--use-cuda
            python -c 'import sys, torch; sys.exit(0 if torch.cuda.is_available() else 3)' \
              || { echo "{\"event\":\"skip\",\"device\":\"cuda\",\"reason\":\"no CUDA device\"}"; continue; } ;;
      *) echo "unknown device ${dev}" >&2; exit 2 ;;
    esac
    run="${OUT}/${dev}-mc${mc}"
    mkdir -p "${run}/work"
    start=$(date +%s.%N)
    ( cd "${run}/work" && python "${RG}/scripts/real.py" "${DATA}" \
        --epochs "${EPOCHS}" --threshold "${EPOCHS}" --reg-epochs 1 \
        --min-count "${mc}" "${flag}" --save-dir "${run}/out" ) > "${run}/train.log" 2>&1 \
      || { echo "{\"event\":\"fail\",\"device\":\"${dev}\",\"min_count\":${mc}}"; tail -20 "${run}/train.log"; exit 1; }
    end=$(date +%s.%N)
    RUN="${run}" DEV="${dev}" MC="${mc}" EPOCHS="${EPOCHS}" START="${start}" END="${end}" python - <<'PY'
import csv, glob, json, os, re
run = os.environ["RUN"]
log = open(os.path.join(run, "train.log"), errors="replace").read()
m = re.search(r"# of sequences -> (\d+)", log)
csvs = sorted(glob.glob(os.path.join(run, "out", "*.csv")))
rows = list(csv.DictReader(open(csvs[0]))) if csvs else []
wall = float(os.environ["END"]) - float(os.environ["START"])
ep = int(os.environ["EPOCHS"])
print(json.dumps({
    "event": "run",
    "device": os.environ["DEV"],
    "min_count": int(os.environ["MC"]),
    "unique_sequences": int(m.group(1)) if m else None,
    "epochs_requested": ep,
    "epochs_logged": len(rows),
    "wall_seconds": round(wall, 1),
    "seconds_per_epoch": round(wall / ep, 2),
    "last_test_loss": float(rows[-1]["test_loss"]) if rows and "test_loss" in rows[-1] else None,
}), flush=True)
PY
  done
done
echo '{"event":"done"}'
