#!/usr/bin/env python3
"""Combine per-round counts and rank sequences from the final SELEX round."""
from __future__ import annotations

import argparse
import csv
import math
import re
from pathlib import Path

DEFAULT_ROUND_RE = re.compile(r"(\d+)")


def read_counts(path: Path) -> dict[str, tuple[int, float]]:
    with path.open(newline="") as handle:
        return {
            row["sequence"]: (int(row["count"]), float(row["rpm"]))
            for row in csv.DictReader(handle, delimiter="\t")
        }


def round_number(path: Path, pattern: re.Pattern[str] = DEFAULT_ROUND_RE) -> int:
    match = pattern.search(path.stem)
    if not match:
        raise ValueError(f"cannot determine round from {path.name}")
    return int(match.group(1))


def output_path(output_dir: Path, name: str) -> Path:
    if not name or Path(name).name != name or name in {".", ".."}:
        raise ValueError(f"output name must be a file name: {name!r}")
    return output_dir / name


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--counts-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--counts-pattern", default="R*.tsv")
    parser.add_argument("--round-regex", default=DEFAULT_ROUND_RE.pattern)
    parser.add_argument("--top-candidates", type=int, default=100)
    parser.add_argument("--pseudocount-rpm", type=float, default=0.01)
    parser.add_argument("--ranked-output-name", default="top_candidates.tsv")
    parser.add_argument("--ratio-output-name", default="unique_ratio.tsv")
    args = parser.parse_args()

    if args.top_candidates <= 0:
        parser.error("--top-candidates must be positive")
    if args.pseudocount_rpm <= 0:
        parser.error("--pseudocount-rpm must be positive")
    if Path(args.counts_pattern).name != args.counts_pattern:
        parser.error("--counts-pattern must be a file-name pattern")

    try:
        round_pattern = re.compile(args.round_regex)
    except re.error as error:
        parser.error(f"invalid --round-regex: {error}")
    if round_pattern.groups < 1:
        parser.error("--round-regex must contain a capture group for the round number")

    files = sorted(
        args.counts_dir.glob(args.counts_pattern),
        key=lambda path: round_number(path, round_pattern),
    )
    if len(files) < 2:
        raise SystemExit("at least two round count files are required")
    rounds = [round_number(path, round_pattern) for path in files]
    if len(rounds) != len(set(rounds)):
        raise SystemExit("duplicate round count files")
    data = {round_number(path, round_pattern): read_counts(path) for path in files}
    args.output_dir.mkdir(parents=True, exist_ok=True)

    ratio_path = output_path(args.output_dir, args.ratio_output_name)
    with ratio_path.open("w", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["round", "total_reads", "unique_sequences", "unique_ratio"])
        for round_value in rounds:
            total = sum(count for count, _ in data[round_value].values())
            if total <= 0:
                raise SystemExit(f"round {round_value} contains no reads")
            unique = len(data[round_value])
            writer.writerow([round_value, total, unique, f"{unique / total:.9f}"])

    final_round = rounds[-1]
    previous_round = rounds[-2]
    rows = []
    for sequence, (count, rpm) in data[final_round].items():
        previous_rpm = data[previous_round].get(sequence, (0, 0.0))[1]
        first_rpm = data[rounds[0]].get(sequence, (0, 0.0))[1]
        fold_previous = (rpm + args.pseudocount_rpm) / (
            previous_rpm + args.pseudocount_rpm
        )
        fold_first = (rpm + args.pseudocount_rpm) / (
            first_rpm + args.pseudocount_rpm
        )
        rows.append(
            (sequence, count, rpm, previous_rpm, fold_previous, first_rpm, fold_first)
        )
    rows.sort(key=lambda row: (-row[2], -row[4], row[0]))

    ranked_path = output_path(args.output_dir, args.ranked_output_name)
    with ranked_path.open("w", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(
            [
                "rank",
                "sequence",
                "final_round",
                "final_count",
                "final_rpm",
                "previous_round",
                "previous_rpm",
                "fold_vs_previous",
                "first_round",
                "first_rpm",
                "fold_vs_first",
                "log2_fold_vs_first",
            ]
        )
        for rank, row in enumerate(rows[: args.top_candidates], start=1):
            sequence, count, rpm, prev_rpm, fold_prev, first_rpm, fold_first = row
            writer.writerow(
                [
                    rank,
                    sequence,
                    final_round,
                    count,
                    f"{rpm:.6f}",
                    previous_round,
                    f"{prev_rpm:.6f}",
                    f"{fold_prev:.6f}",
                    rounds[0],
                    f"{first_rpm:.6f}",
                    f"{fold_first:.6f}",
                    f"{math.log2(fold_first):.6f}",
                ]
            )


if __name__ == "__main__":
    main()
