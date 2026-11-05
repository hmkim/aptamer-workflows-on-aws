import hashlib
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
BATCH = ROOT / "batch"
PIPELINE = ROOT / "pipeline"


def write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content))
    path.chmod(0o755)


def write_fastq(path: Path, sequences: list[str]) -> None:
    lines = []
    for index, sequence in enumerate(sequences, start=1):
        lines.extend([f"@r{index}", sequence, "+", "I" * len(sequence)])
    path.write_text("\n".join(lines) + "\n")


class BatchContractTest(unittest.TestCase):
    def make_environment(self, root: Path) -> dict[str, str]:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        fake_s3 = root / "s3"
        fake_s3.mkdir()

        write_executable(
            bin_dir / "aws",
            r'''#!/usr/bin/env python3
import os
import shutil
import sys
from pathlib import Path

args = sys.argv[1:]
root = Path(os.environ["FAKE_S3_ROOT"])
if len(args) >= 2 and args[:2] == ["s3api", "head-object"]:
    bucket = args[args.index("--bucket") + 1]
    key = args[args.index("--key") + 1]
    raise SystemExit(0 if (root / bucket / key).is_file() else 1)
if len(args) < 2 or args[0] != "s3" or args[1] not in {"cp", "sync"}:
    raise SystemExit(f"unsupported fake aws call: {args}")
operation = args[1]
values = [value for value in args[2:] if not value.startswith("-")]
# Ignore filter values paired with --include/--exclude; test fixtures contain only intended files.
filtered = []
skip = False
for index, value in enumerate(args[2:]):
    if skip:
        skip = False
        continue
    if value in {"--include", "--exclude"}:
        skip = True
        continue
    if value.startswith("-"):
        continue
    filtered.append(value)
if len(filtered) != 2:
    raise SystemExit(f"cannot identify fake aws source/destination: {args}")
source, destination = filtered
root = Path(os.environ["FAKE_S3_ROOT"])

def resolve(value: str) -> Path:
    return root / value[5:] if value.startswith("s3://") else Path(value)

source_path = resolve(source.rstrip("/"))
destination_path = resolve(destination.rstrip("/"))
if operation == "cp":
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    if destination.endswith("/") or destination_path.is_dir():
        destination_path.mkdir(parents=True, exist_ok=True)
        destination_path = destination_path / source_path.name
    shutil.copy2(source_path, destination_path)
else:
    destination_path.mkdir(parents=True, exist_ok=True)
    if source_path.exists():
        for item in source_path.rglob("*"):
            if item.is_file():
                target = destination_path / item.relative_to(source_path)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target)
''',
        )
        write_executable(
            bin_dir / "findmnt",
            r'''#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ro,relatime\n'
''',
        )
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
  seq) input=${!#}; awk 'NR % 4 == 2 {print}' "$input" ;;
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
cat
''',
        )

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{bin_dir}:{PIPELINE}:{BATCH}:{environment['PATH']}",
                "FAKE_S3_ROOT": str(fake_s3),
                "DATA_BUCKET": "data",
                "DATA_PREFIX": "input",
                "WORK_BUCKET": "work",
                "LOCAL_SCRATCH": str(root / "scratch"),
                "FRONT_PRIMER": "AAAA",
                "BACK_PRIMER": "TTTT",
                "TOP_CANDIDATES": "1",
                "RUN_ID": "contract",
            }
        )
        (root / "scratch").mkdir()
        data = fake_s3 / "data" / "input"
        data.mkdir(parents=True)
        write_fastq(data / "R0_example.fastq.gz", ["AAAA", "CCCC"])
        write_fastq(data / "R1_example.fastq.gz", ["CCCC", "CCCC"])
        return environment

    def run_job(self, script: str, environment: dict[str, str], *args: str) -> None:
        subprocess.run(
            ["bash", str(BATCH / script), *args],
            check=True,
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_loader_verifies_existing_object_and_normalizes_md5_case(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.make_environment(root)
            environment["AWS_BATCH_JOB_ID"] = "loader-existing"
            environment["SCENARIO"] = "loader"
            object_path = root / "s3" / "data" / "input" / "R0_example.fastq.gz"
            expected_md5 = hashlib.md5(object_path.read_bytes()).hexdigest().upper()
            manifest = root / "manifest.tsv"
            manifest.write_text(
                "round\trun_accession\tlibrary_name\tfile_name\turl\tmd5\n"
                f"0\texample\texample\texample.fastq.gz\thttps://example.invalid/example.fastq.gz\t{expected_md5}\n"
            )
            environment["MANIFEST"] = str(manifest)
            self.run_job("load_data.sh", environment)

    def test_loader_rejects_non_https_manifest_url(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.make_environment(root)
            environment["AWS_BATCH_JOB_ID"] = "loader-http"
            environment["SCENARIO"] = "loader"
            manifest = root / "manifest.tsv"
            manifest.write_text(
                "round\trun_accession\tlibrary_name\tfile_name\turl\tmd5\n"
                "0\texample\texample\texample.fastq.gz\thttp://example.invalid/example.fastq.gz\t00000000000000000000000000000000\n"
            )
            environment["MANIFEST"] = str(manifest)
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_job("load_data.sh", environment)

    def test_copyin_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.make_environment(root)
            environment["AWS_BATCH_JOB_ID"] = "copyin-job"
            self.run_job("run_copyin.sh", environment)
            result = root / "s3" / "work" / "runs" / "copyin" / "contract" / "result"
            self.assertTrue((result / "enrich" / "top_candidates.tsv").is_file())
            self.assertTrue((result / "fold" / "top_candidates.fold").is_file())

    def test_mountpoint_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.make_environment(root)
            environment["AWS_BATCH_JOB_ID"] = "mountpoint-job"
            mount_path = root / "s3" / "data" / "input"
            environment["MOUNT_PATH"] = str(mount_path)
            environment["MOUNT_INPUT_DIR"] = str(mount_path)
            mount_path.chmod(0o555)
            try:
                self.run_job("run_mountpoint.sh", environment)
            finally:
                mount_path.chmod(0o755)
            result = root / "s3" / "work" / "runs" / "mountpoint" / "contract" / "result"
            self.assertTrue((result / "enrich" / "top_candidates.tsv").is_file())
            self.assertTrue((result / "fold" / "top_candidates.fold").is_file())

    def test_stage_dependency_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.make_environment(root)
            environment["SCENARIO"] = "dependencies"
            for stage in ("S1", "S2", "S3"):
                for index in ("0", "1"):
                    stage_environment = environment.copy()
                    stage_environment["AWS_BATCH_JOB_ID"] = f"{stage.lower()}:{index}"
                    stage_environment["AWS_BATCH_JOB_ARRAY_INDEX"] = index
                    self.run_job("run_stage.sh", stage_environment, stage)
            for stage in ("S4", "S5"):
                stage_environment = environment.copy()
                stage_environment["AWS_BATCH_JOB_ID"] = stage.lower()
                stage_environment.pop("AWS_BATCH_JOB_ARRAY_INDEX", None)
                self.run_job("run_stage.sh", stage_environment, stage)

            result = root / "s3" / "work" / "runs" / "dependencies" / "contract" / "result"
            self.assertTrue((result / "qc" / "stats.tsv").is_file())
            self.assertTrue((result / "enrich" / "top_candidates.tsv").is_file())
            self.assertTrue((result / "fold" / "top_candidates.fold").is_file())
            self.assertTrue((result / "checksums.sha256").is_file())


if __name__ == "__main__":
    unittest.main()
