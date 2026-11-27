#!/usr/bin/env bash
# RaptGen smoke test (both image variants; the smoke itself always runs on CPU). Runs inside aptamer-raptgen as a
# non-root user with --network none and a read-only root filesystem. Uses only
# the upstream bundled example (data/sample).
#
#   R. runtime policy   : non-root, read-only image paths, no network route,
#                         Bayesian optimization excluded, CPU-only torch
#   A. reference encode : scripts/encode.py sample.fasta + upstream sample model
#                         (legacy torch 1.5 checkpoint, weights_only load),
#                         run twice -> must be identical (deterministic)
#   B. reference decode : scripts/decode.py on N latent points, target_len 20
#   C. short training   : scripts/real.py sample.fasta, bounded epochs;
#                         trained state_dict keys/shapes == sample model
#   D. generation       : encode + decode with the model trained in C,
#                         written as generated.fasta (labelled as generated)
#
# Env: SMOKE_OUT (default /smoke-out), SMOKE_DEVICE cpu (cuda is refused: the
#      image has no CUDA build), SMOKE_EPOCHS (default 3), SMOKE_N_POINTS (8).
# Result: $SMOKE_OUT/smoke-test-results.json, status PASS_WITH_LIMIT on success
# (bounded training, no scientific quality claim) or FAIL_TECHNICAL.
set -euo pipefail
set +x

OUT="${SMOKE_OUT:-/smoke-out}"
DEVICE="${SMOKE_DEVICE:-cpu}"
EPOCHS="${SMOKE_EPOCHS:-3}"
NPOINTS="${SMOKE_N_POINTS:-8}"
RG="${RAPTGEN_HOME:-/opt/raptgen}"
CONTRACT=/usr/local/lib/aptamer/raptgen_contract.py
SAMPLE="${RG}/data/sample/sample.fasta"
REF_MODEL="${RG}/data/sample/cnn_phmm_vae.mdl"
TARGET_LEN=20
SAMPLE_READS=100

[[ "${EPOCHS}" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "SMOKE_EPOCHS must be 1..999" >&2; exit 2; }
[[ "${NPOINTS}" =~ ^[1-9][0-9]{0,2}$ && "${NPOINTS}" -le "${SAMPLE_READS}" ]] \
  || { echo "SMOKE_N_POINTS must be 1..${SAMPLE_READS}" >&2; exit 2; }
case "${DEVICE}" in
  cpu) CUDA_FLAG=--no-cuda ;;
  cuda) echo "SMOKE_DEVICE=cuda refused: this image has no CUDA support in the smoke test (torch +cpu)" >&2; exit 2 ;;
  *) echo "SMOKE_DEVICE must be cpu" >&2; exit 2 ;;
esac

mkdir -p "${OUT}" "${HOME:-/tmp/home}" "${MPLCONFIGDIR:-/tmp/mpl}"
WORK="${OUT}/work"
mkdir -p "${WORK}"
cd "${WORK}"   # upstream scripts write ./.log/logger.log relative to cwd
STEP="init"
CHECKS="${OUT}/checks.json"
echo '{}' > "${CHECKS}"

write_result() {
  local status="$1" reason="$2"
  STATUS="${status}" REASON="${reason}" STEP="${STEP}" OUT="${OUT}" DEVICE="${DEVICE}" \
  EPOCHS="${EPOCHS}" python - <<'PY'
import json, os, subprocess
out = os.environ["OUT"]
try:
    versions = json.loads(subprocess.check_output(["/usr/local/bin/tool-version"]).decode())
except Exception as exc:  # version probe must never mask the real result
    versions = {"error": str(exc)}
res = {
    "test_id": "raptgen-smoke",
    "tool": "raptgen",
    "image_variant": os.environ.get("RAPTGEN_VARIANT", "modern-cpu"),
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "last_step": os.environ["STEP"],
    "device": os.environ["DEVICE"],
    "epochs": int(os.environ["EPOCHS"]),
    "official_example": "hmdlab/raptgen data/sample/sample.fasta (+ data/sample/cnn_phmm_vae.mdl)",
    "scope": ["train", "encode", "decode", "generate"],
    "excluded": ["bayesian-optimization (scripts/bo.py, GPyOpt)"],
    "limits": [
        "bounded training epochs; generated sequences carry no scientific quality claim",
        "upstream training does not seed torch; trained-model outputs are not bit-reproducible",
    ],
    "versions": versions,
}
with open(os.path.join(out, "checks.json")) as fh:
    res["checks"] = json.load(fh)
with open(os.path.join(out, "smoke-test-results.json"), "w") as fh:
    json.dump(res, fh, indent=2, sort_keys=True)
print(json.dumps({"status": res["status"], "last_step": res["last_step"]}))
PY
}
trap 'rc=$?; [[ $rc -ne 0 ]] && write_result FAIL_TECHNICAL "step ${STEP} exited ${rc}"; exit $rc' EXIT

# check <python-code>: run a contract snippet; it gets C (contract module),
# OUT, record(key, value). A ContractError fails the current step.
check() {
  OUT="${OUT}" NPOINTS="${NPOINTS}" EPOCHS="${EPOCHS}" TARGET_LEN="${TARGET_LEN}" \
  SAMPLE_READS="${SAMPLE_READS}" REF_MODEL="${REF_MODEL}" RG="${RG}" \
  python - "$1" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("raptgen_contract", "/usr/local/lib/aptamer/raptgen_contract.py")
C = importlib.util.module_from_spec(spec); spec.loader.exec_module(C)
OUT = os.environ["OUT"]
path = os.path.join(OUT, "checks.json")
with open(path) as fh:
    checks = json.load(fh)
def record(key, value):
    checks[key] = value
try:
    exec(sys.argv[1], {"C": C, "OUT": OUT, "record": record, "os": os, "env": os.environ})
finally:
    with open(path, "w") as fh:
        json.dump(checks, fh, indent=2, sort_keys=True)
PY
}

STEP="versions"
/usr/local/bin/tool-version > "${OUT}/tool-version.txt"

STEP="R-runtime-policy"
check '
import importlib.util, torch
uid = os.getuid()
C.need(uid != 0 and os.getgid() != 0, "running as root")
record("runtime_uid", uid)
for p in (env["RG"], "/usr/local/lib/aptamer", "/usr/local/bin", "/"):
    C.need(not os.access(p, os.W_OK), f"{p} is writable")
record("image_paths_writable", False)
with open("/proc/net/route") as fh:
    routes = [l.split() for l in fh.read().splitlines()[1:] if l.strip()]
C.need(not routes, f"IPv4 routes present (network not isolated): {routes}")
record("ipv4_routes", 0)
for m in ("GPyOpt", "GPy", "torchvision"):
    C.need(importlib.util.find_spec(m) is None, f"{m} must not be installed")
C.need(not os.path.exists(os.path.join(env["RG"], "scripts", "bo.py")), "scripts/bo.py shipped")
record("bayesian_optimization", "excluded")
expect_cuda = env.get("RAPTGEN_EXPECT_TORCH_CUDA", "")
if expect_cuda:
    # modern-gpu variant: CUDA-built torch is expected; the smoke itself still runs on CPU.
    C.need(torch.version.cuda == expect_cuda, f"torch CUDA build {torch.version.cuda} != {expect_cuda}")
    record("torch_cuda_build", torch.version.cuda)
else:
    C.need(torch.version.cuda is None, f"torch has a CUDA build: {torch.version.cuda}")
    record("torch_cpu_only", True)
'

STEP="input-checksums"
( cd "${RG}" && sha256sum data/sample/sample.fasta data/sample/cnn_phmm_vae.mdl ) \
  | awk '{print $2"\t"$1}' > "${OUT}/input-checksums.tsv"

run() {  # run <log-name> <cmd...>; command line recorded without secrets
  local name="$1" log; shift
  log="${OUT}/${name}.log"
  printf '%s\n' "$*" >> "${OUT}/command.txt"
  if ! "$@" > "${log}" 2>&1; then
    tail -n 100 "${log}" >&2
    return 1
  fi
}

STEP="A-checkpoint-load"
# torch >= 2.6 defaults torch.load to weights_only=True; the upstream sample
# model is a torch 1.5 legacy (non-zip) pickle. Prove it loads that way.
check '
import torch
sd = torch.load(env["REF_MODEL"], map_location="cpu", weights_only=True)
record("reference_model_tensors", len(sd))
record("reference_model_weights_only_load", True)
'

STEP="A-reference-encode"
run A-encode python "${RG}/scripts/encode.py" "${SAMPLE}" "${REF_MODEL}" \
  "${CUDA_FLAG}" --save-dir "${OUT}/ref/encode"
run A-encode-repeat python "${RG}/scripts/encode.py" "${SAMPLE}" "${REF_MODEL}" \
  "${CUDA_FLAG}" --save-dir "${OUT}/ref/encode-repeat"
check '
record("reference_encode", C.check_encode(f"{OUT}/ref/encode/embed_seq.csv",
       expected_rows=int(env["SAMPLE_READS"]), embed_dim=2, seq_len=int(env["TARGET_LEN"])))
record("reference_encode_repeat", C.compare_embeddings(
       f"{OUT}/ref/encode/embed_seq.csv", f"{OUT}/ref/encode-repeat/embed_seq.csv", atol=1e-6))
'

STEP="B-reference-decode"
python "${CONTRACT}" points "${OUT}/ref/encode/embed_seq.csv" "${OUT}/ref/points.csv" "${NPOINTS}"
run B-decode python "${RG}/scripts/decode.py" "${OUT}/ref/points.csv" "${REF_MODEL}" "${TARGET_LEN}" \
  "${CUDA_FLAG}" --save-dir "${OUT}/ref/decode"
check '
record("reference_decode", C.check_decode(f"{OUT}/ref/decode/decode_output.csv",
       int(env["NPOINTS"]), int(env["TARGET_LEN"])))
'

STEP="C-train"
run C-train python "${RG}/scripts/real.py" "${SAMPLE}" \
  --epochs "${EPOCHS}" --threshold "${EPOCHS}" --reg-epochs 1 \
  "${CUDA_FLAG}" --save-dir "${OUT}/train"
if [[ -f "${WORK}/.log/logger.log" ]]; then cp "${WORK}/.log/logger.log" "${OUT}/C-train.logger.log"; fi
check '
import torch
record("train_log", C.check_train_log(f"{OUT}/train/cnn_phmm_vae.csv", int(env["EPOCHS"])))
shapes = lambda p: {k: list(v.shape) for k, v in torch.load(p, map_location="cpu", weights_only=True).items()}
record("trained_vs_reference_state_dict", C.compare_state_dict_shapes(
       shapes(env["REF_MODEL"]), shapes(f"{OUT}/train/cnn_phmm_vae.mdl")))
'

STEP="D-generate"
run D-encode python "${RG}/scripts/encode.py" "${SAMPLE}" "${OUT}/train/cnn_phmm_vae.mdl" \
  "${CUDA_FLAG}" --save-dir "${OUT}/gen/encode"
python "${CONTRACT}" points "${OUT}/gen/encode/embed_seq.csv" "${OUT}/gen/points.csv" "${NPOINTS}"
run D-decode python "${RG}/scripts/decode.py" "${OUT}/gen/points.csv" "${OUT}/train/cnn_phmm_vae.mdl" \
  "${TARGET_LEN}" "${CUDA_FLAG}" --save-dir "${OUT}/gen/decode"

STEP="validate"
check '
import csv, hashlib
record("generated_encode", C.check_encode(f"{OUT}/gen/encode/embed_seq.csv",
       expected_rows=int(env["SAMPLE_READS"]), embed_dim=2, seq_len=int(env["TARGET_LEN"])))
n = int(env["NPOINTS"])
record("generated_decode", C.check_decode(f"{OUT}/gen/decode/decode_output.csv", n, int(env["TARGET_LEN"])))
with open(f"{OUT}/train/cnn_phmm_vae.mdl", "rb") as fh:
    model_sha = hashlib.sha256(fh.read()).hexdigest()
with open(f"{OUT}/gen/decode/decode_output.csv", newline="") as fh:
    rows = list(csv.DictReader(fh))
with open(f"{OUT}/generated.fasta", "w") as fh:
    for i, row in enumerate(rows):
        d1, d2, lp = (float(row[k]) for k in ("dim1", "dim2", "log_proba"))
        seq = row["maximum_probable_sequence"]
        fh.write(f">raptgen_generated_{i} source=generated model_sha256={model_sha} "
                 f"dim1={d1:.4f} dim2={d2:.4f} log_proba={lp:.4f}\n{seq}\n")
record("generated_fasta", C.check_generated_fasta(f"{OUT}/generated.fasta", n, model_sha))
record("trained_model_sha256", model_sha)
rows = []
for root, _, files in os.walk(OUT):
    for name in sorted(files):
        p = os.path.join(root, name)
        rel = os.path.relpath(p, OUT)
        if rel.startswith("work/") or rel in ("output-checksums.tsv", "smoke-test-results.json", "checks.json"):
            continue
        with open(p, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        rows.append(rel + "\t" + digest)
with open(f"{OUT}/output-checksums.tsv", "w") as fh:
    fh.write("\n".join(sorted(rows)) + "\n")
'

trap - EXIT
write_result PASS_WITH_LIMIT "official sample encode/decode and bounded train/generate completed (CPU or GPU image)"
