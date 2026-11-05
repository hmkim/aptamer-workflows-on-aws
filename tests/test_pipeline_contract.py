import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
PIPELINE = ROOT / "pipeline" / "run_pipeline.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content))
    path.chmod(0o755)


class PipelineContractTest(unittest.TestCase):
    def test_end_to_end_file_contract_with_stubbed_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            inputs = root / "inputs"
            outputs = root / "outputs"
            bin_dir.mkdir()
            inputs.mkdir()

            write_executable(
                bin_dir / "seqkit",
                r'''#!/usr/bin/env bash
set -Eeuo pipefail
command=$1
shift
case "$command" in
  stats)
    printf 'file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n'
    for arg in "$@"; do
      [[ "$arg" == --* ]] && continue
      count=$(awk 'END {print NR / 4}' "$arg")
      printf '%s\tFASTQ\tDNA\t%s\t%s\t4\t4\t4\n' "$(basename "$arg")" "$count" "$((count * 4))"
    done
    ;;
  seq)
    input=${!#}
    awk 'NR % 4 == 2 {print}' "$input"
    ;;
  *) exit 2 ;;
esac
''',
            )
            write_executable(
                bin_dir / "cutadapt",
                r'''#!/usr/bin/env bash
set -Eeuo pipefail
output=''
input=${!#}
while (($#)); do
  if [[ "$1" == --output ]]; then output=$2; shift 2; else shift; fi
done
cp "$input" "$output"
''',
            )
            write_executable(
                bin_dir / "RNAfold",
                r'''#!/usr/bin/env bash
set -Eeuo pipefail
while IFS= read -r line; do
  printf '%s\n' "$line"
  [[ "$line" == '>'* ]] || printf '.... (-1.00)\n'
done
''',
            )

            (inputs / "R0_example.fastq.gz").write_text(
                "@r1\nAAAA\n+\nIIII\n@r2\nCCCC\n+\nIIII\n"
            )
            (inputs / "R1_example.fastq.gz").write_text(
                "@r1\nCCCC\n+\nIIII\n@r2\nCCCC\n+\nIIII\n"
            )

            environment = os.environ.copy()
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"
            subprocess.run(
                [
                    "bash",
                    str(PIPELINE),
                    str(inputs),
                    str(outputs),
                    "AAAA",
                    "TTTT",
                    "1",
                    "R*_*.fastq.gz",
                    r"^R([0-9]+)_",
                ],
                check=True,
                env=environment,
                text=True,
                capture_output=True,
            )

            ranked = outputs / "enrich" / "top_candidates.tsv"
            folded = outputs / "fold" / "top_candidates.fold"
            self.assertTrue(ranked.is_file())
            self.assertTrue(folded.is_file())
            self.assertIn("CCCC", ranked.read_text())
            subprocess.run(
                ["sha256sum", "--check", "checksums.sha256"],
                cwd=outputs,
                check=True,
                text=True,
                capture_output=True,
            )


if __name__ == "__main__":
    unittest.main()
