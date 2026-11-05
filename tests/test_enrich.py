import csv
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "pipeline" / "enrich.py"


def write_counts(path: Path, rows):
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["sequence", "count", "rpm"])
        writer.writerows(rows)


class EnrichTest(unittest.TestCase):
    def test_enrichment_is_deterministic_and_ranked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            counts = root / "counts"
            output = root / "output"
            counts.mkdir()
            write_counts(
                counts / "R0.tsv",
                [("AAAA", 90, 900000), ("CCCC", 10, 100000)],
            )
            write_counts(
                counts / "R1.tsv",
                [("AAAA", 10, 100000), ("CCCC", 90, 900000)],
            )
            subprocess.run(
                [
                    sys.executable,
                    SCRIPT,
                    "--counts-dir",
                    counts,
                    "--output-dir",
                    output,
                ],
                check=True,
            )
            with (output / "top_candidates.tsv").open() as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))
            self.assertEqual(rows[0]["sequence"], "CCCC")
            self.assertAlmostEqual(float(rows[0]["fold_vs_first"]), 9.0, places=5)
            with (output / "unique_ratio.tsv").open() as handle:
                ratios = list(csv.DictReader(handle, delimiter="\t"))
            self.assertEqual(ratios[0]["unique_ratio"], "0.020000000")

    def test_file_names_and_candidate_count_are_configurable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            counts = root / "counts"
            output = root / "output"
            counts.mkdir()
            write_counts(counts / "cycle_2.tsv", [("AAAA", 5, 500000), ("CCCC", 5, 500000)])
            write_counts(counts / "cycle_10.tsv", [("AAAA", 1, 100000), ("CCCC", 9, 900000)])
            subprocess.run(
                [
                    sys.executable,
                    SCRIPT,
                    "--counts-dir",
                    counts,
                    "--output-dir",
                    output,
                    "--counts-pattern",
                    "cycle_*.tsv",
                    "--round-regex",
                    r"^cycle_(\d+)$",
                    "--top-candidates",
                    "1",
                    "--ranked-output-name",
                    "ranked.tsv",
                ],
                check=True,
            )
            with (output / "ranked.tsv").open() as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["sequence"], "CCCC")
            self.assertEqual(rows[0]["final_round"], "10")


if __name__ == "__main__":
    unittest.main()
