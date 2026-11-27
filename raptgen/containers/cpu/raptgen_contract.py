#!/usr/bin/env python3
"""RaptGen output contract and parity checks (stdlib only).

Used inside the aptamer-raptgen images by /usr/local/bin/smoke-test.
No third-party imports, so the same rules are unit-testable without the image.

Contract (official example hmdlab/raptgen data/sample, 100 reads, AAAAA-20N-GGGGG):
  encode  embed_seq.csv     columns index,seq,dim1..dimD; one row per
                            filter-passed read (100); index 0..N-1; seq over
                            ACGT with the target length; finite coordinates
  decode  decode_output.csv columns index,dim1..dimD,pattern,
                            maximum_probable_sequence,log_proba; one row per
                            point; sequence over ACGT, same length as pattern,
                            equal to pattern wherever pattern is not '*';
                            finite log_proba
  train   <model>.csv       header epoch,train_loss,test_loss,test_recon,test_kld;
                            1..epochs rows, epochs 1..k in order, finite floats
  model   state_dict        same keys and tensor shapes as the upstream
                            sample model (architecture parity)
  fasta   generated.fasta   one record per decoded point, source=generated,
                            sequence over ACGT

    raptgen_contract.py points <embed_seq.csv> <points.csv> <n>
    raptgen_contract.py parity <dir_a> <dir_b> [--atol 1e-4]
"""
import argparse
import csv
import json
import math
import re
import sys

ENCODE_PREFIX = ["index", "seq"]
DECODE_SUFFIX = ["pattern", "maximum_probable_sequence", "log_proba"]
TRAIN_HEADER = ["epoch", "train_loss", "test_loss", "test_recon", "test_kld"]
ACGT = re.compile(r"[ACGT]+")
PATTERN = re.compile(r"[ACGT*]+")


class ContractError(Exception):
    """An output violates the output contract."""


def need(cond, msg):
    if not cond:
        raise ContractError(msg)


def read_csv(path):
    with open(path, newline="") as fh:
        rows = list(csv.reader(fh))
    need(rows, f"{path}: empty file")
    return rows[0], rows[1:]


def finite(value, what):
    try:
        x = float(value)
    except ValueError:
        raise ContractError(f"{what}: not a float: {value!r}") from None
    need(math.isfinite(x), f"{what}: not finite: {value!r}")
    return x


def dim_columns(header, start):
    dims = []
    for name in header[start:]:
        if not re.fullmatch(r"dim[1-9][0-9]*", name):
            break
        dims.append(name)
    need(dims == [f"dim{i + 1}" for i in range(len(dims))] and dims,
         f"dimension columns must be dim1..dimD, got {header[start:]}")
    return dims


def check_encode(path, expected_rows=100, embed_dim=2, seq_len=None):
    header, rows = read_csv(path)
    need(header[:2] == ENCODE_PREFIX, f"encode header {header}")
    dims = dim_columns(header, 2)
    need(len(header) == 2 + len(dims), f"encode extra columns {header}")
    need(len(dims) == embed_dim, f"encode embedding dim {len(dims)} != {embed_dim}")
    need(len(rows) == expected_rows, f"encode rows {len(rows)} != {expected_rows}")
    for i, row in enumerate(rows):
        need(len(row) == len(header), f"encode row {i} has {len(row)} fields")
        need(row[0] == str(i), f"encode row {i} index {row[0]!r}")
        need(ACGT.fullmatch(row[1]) is not None, f"encode row {i} seq not ACGT: {row[1]!r}")
        if seq_len is not None:
            need(len(row[1]) == seq_len, f"encode row {i} seq length {len(row[1])} != {seq_len}")
        for j, v in enumerate(row[2:]):
            finite(v, f"encode row {i} dim{j + 1}")
    return {"rows": len(rows), "embed_dim": len(dims)}


def embeddings(path):
    header, rows = read_csv(path)
    dims = dim_columns(header, 2)
    return [(r[1], [float(v) for v in r[2:2 + len(dims)]]) for r in rows]


def compare_embeddings(path_a, path_b, atol):
    a, b = embeddings(path_a), embeddings(path_b)
    need(len(a) == len(b), f"embedding rows {len(a)} != {len(b)}")
    worst = 0.0
    for i, ((sa, va), (sb, vb)) in enumerate(zip(a, b)):
        need(sa == sb, f"embedding row {i} sequence differs: {sa} vs {sb}")
        need(len(va) == len(vb), f"embedding row {i} dim differs")
        for x, y in zip(va, vb):
            worst = max(worst, abs(x - y))
    need(worst <= atol, f"embedding max abs diff {worst:.3g} > atol {atol:g}")
    return {"rows": len(a), "max_abs_diff": worst, "atol": atol}


def check_decode(path, n_points, target_len):
    header, rows = read_csv(path)
    need(header[:1] == ["index"], f"decode header {header}")
    dims = dim_columns(header, 1)
    need(header[1 + len(dims):] == DECODE_SUFFIX, f"decode header {header}")
    need(len(rows) == n_points, f"decode rows {len(rows)} != {n_points}")
    pos = {name: k for k, name in enumerate(header)}
    lengths = []
    for i, row in enumerate(rows):
        need(len(row) == len(header), f"decode row {i} has {len(row)} fields")
        for d in dims:
            finite(row[pos[d]], f"decode row {i} {d}")
        pat, seq = row[pos["pattern"]], row[pos["maximum_probable_sequence"]]
        need(PATTERN.fullmatch(pat) is not None, f"decode row {i} pattern {pat!r}")
        need(ACGT.fullmatch(seq) is not None, f"decode row {i} non-ACGT sequence {seq!r}")
        need(len(seq) == len(pat), f"decode row {i} length {len(seq)} != pattern {len(pat)}")
        need(all(p in ("*", s) for p, s in zip(pat, seq)),
             f"decode row {i} sequence {seq} does not match pattern {pat}")
        finite(row[pos["log_proba"]], f"decode row {i} log_proba")
        lengths.append(len(seq))
    return {
        "rows": len(rows),
        "target_len": target_len,
        "lengths": lengths,
        "rows_at_target_len": sum(1 for n in lengths if n == target_len),
    }


def decoded(path):
    header, rows = read_csv(path)
    pos = {name: k for k, name in enumerate(header)}
    return [(r[pos["pattern"]], r[pos["maximum_probable_sequence"]]) for r in rows]


def check_train_log(path, max_epochs):
    header, rows = read_csv(path)
    need(header == TRAIN_HEADER, f"training log header {header}")
    need(1 <= len(rows) <= max_epochs, f"training log rows {len(rows)} not in 1..{max_epochs}")
    for i, row in enumerate(rows):
        need(len(row) == len(TRAIN_HEADER), f"training log row {i} has {len(row)} fields")
        need(row[0] == str(i + 1), f"training log row {i} epoch {row[0]!r}")
        for name, v in zip(TRAIN_HEADER[1:], row[1:]):
            finite(v, f"training log epoch {i + 1} {name}")
    return {"epochs_logged": len(rows)}


def compare_state_dict_shapes(reference, candidate):
    """Both are {key: [dim, ...]}; architecture parity with the sample model."""
    missing = sorted(set(reference) - set(candidate))
    extra = sorted(set(candidate) - set(reference))
    need(not missing and not extra, f"state_dict keys differ: missing={missing[:5]} extra={extra[:5]}")
    bad = [k for k in reference if list(reference[k]) != list(candidate[k])]
    need(not bad, f"state_dict shapes differ for {bad[:5]}")
    return {"tensors": len(reference)}


def check_generated_fasta(path, n_records, model_sha256):
    with open(path) as fh:
        lines = fh.read().splitlines()
    need(len(lines) == 2 * n_records, f"generated.fasta has {len(lines)} lines, want {2 * n_records}")
    for i in range(n_records):
        head, seq = lines[2 * i], lines[2 * i + 1]
        need(head.startswith(f">raptgen_generated_{i} "), f"generated record {i} header {head!r}")
        need(" source=generated " in head, f"generated record {i} not labelled source=generated")
        need(f" model_sha256={model_sha256} " in head, f"generated record {i} model sha mismatch")
        need(ACGT.fullmatch(seq) is not None, f"generated record {i} non-ACGT sequence")
    return {"records": n_records}


def write_points(embed_csv, points_csv, n):
    """decode.py reads df.values[:, 1:] as coordinates: keep index + dims only."""
    header, rows = read_csv(embed_csv)
    dims = dim_columns(header, 2)
    need(n <= len(rows), f"asked for {n} points, only {len(rows)} embeddings")
    with open(points_csv, "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["index"] + dims)
        for row in rows[:n]:
            w.writerow([row[0]] + row[2:2 + len(dims)])


def parity(dir_a, dir_b, atol):
    """Compare two smoke output dirs (e.g. two runs of the smoke test).

    Deterministic parts only: reference-model encode coordinates (eval mode,
    posterior mean) within atol, and reference-model decode patterns /
    sequences. Trained-model outputs are not compared (upstream does not seed
    torch)."""
    report = {"atol": atol}
    report["reference_encode"] = compare_embeddings(
        f"{dir_a}/ref/encode/embed_seq.csv", f"{dir_b}/ref/encode/embed_seq.csv", atol)
    da = decoded(f"{dir_a}/ref/decode/decode_output.csv")
    db = decoded(f"{dir_b}/ref/decode/decode_output.csv")
    need(len(da) == len(db), f"reference decode rows {len(da)} != {len(db)}")
    report["reference_decode_rows"] = len(da)
    report["reference_decode_pattern_mismatches"] = [i for i, (x, y) in enumerate(zip(da, db)) if x[0] != y[0]]
    report["reference_decode_sequence_mismatches"] = [i for i, (x, y) in enumerate(zip(da, db)) if x[1] != y[1]]
    need(not report["reference_decode_pattern_mismatches"],
         f"reference decode patterns differ at rows {report['reference_decode_pattern_mismatches']}")
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("points")
    p.add_argument("embed_csv")
    p.add_argument("points_csv")
    p.add_argument("n", type=int)
    q = sub.add_parser("parity")
    q.add_argument("dir_a")
    q.add_argument("dir_b")
    q.add_argument("--atol", type=float, default=1e-4)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "points":
            write_points(args.embed_csv, args.points_csv, args.n)
        else:
            print(json.dumps(parity(args.dir_a, args.dir_b, args.atol), indent=2, sort_keys=True))
    except (ContractError, OSError, KeyError) as exc:
        print(f"contract: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
