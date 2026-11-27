import pathlib
import pathlib
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

ROOT = Path(__file__).parents[1]
RAPTGEN = ROOT / "raptgen"
IMAGES = ROOT / "docs" / "raptgen" / "images"
UI_COMMIT = "13cad83859dc9eac39383a00882c17c82a4cdb37"



def _local_terms():
    """Project-specific forbidden strings live in an untracked file (.sensitive-terms, one per line)
    so this public test never contains them. Missing file -> only the generic regex checks run."""
    p = pathlib.Path(__file__).resolve().parents[1] / ".sensitive-terms"
    if not p.exists():
        return []
    return [t.strip() for t in p.read_text(encoding="utf-8").splitlines() if t.strip() and not t.startswith("#")]

class _Loader(yaml.SafeLoader if yaml else object):
    """SafeLoader that accepts CloudFormation short-form tags (!Ref, !Sub, ...)."""


if yaml:
    _Loader.add_multi_constructor("!", lambda loader, suffix, node: None)


def load_template(path: Path) -> dict:
    return yaml.load(path.read_text(), Loader=_Loader)


def files(suffixes=None):
    skip = {"node_modules", "cdk.out", "dist", "__pycache__"}
    for p in sorted(RAPTGEN.rglob("*")):
        if p.is_file() and not (skip & set(p.relative_to(RAPTGEN).parts)):
            if suffixes is None or p.suffix in suffixes or p.name in suffixes:
                yield p


class ScriptSyntaxTest(unittest.TestCase):
    def test_shell_scripts_parse(self):
        scripts = [p for p in files() if p.suffix == ".sh"]
        self.assertGreaterEqual(len(scripts), 10)
        for script in scripts:
            with self.subTest(script=str(script.relative_to(ROOT))):
                result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_entry_scripts_are_executable(self):
        for rel in ("containers/build.sh", "batch/submit-train.sh", "batch/submit-bench.sh", "batch/status.sh",
                    "ui/install.sh", "ui/connect.sh", "ui/tests/e2e_api.py",
                    "ui-web/scripts/verify-gate.sh", "ui-web/scripts/add-user.sh"):
            with self.subTest(script=rel):
                self.assertTrue((RAPTGEN / rel).stat().st_mode & 0o111, rel)

    def test_python_files_compile(self):
        for path in files({".py"}):
            with self.subTest(path=str(path.relative_to(ROOT))):
                compile(path.read_text(), str(path), "exec")


@unittest.skipIf(yaml is None, "PyYAML not installed")
class TemplateTest(unittest.TestCase):
    def test_jobs_template(self):
        t = load_template(RAPTGEN / "batch" / "jobs.yaml")
        self.assertEqual(set(t["Resources"]), {"TrainCpu", "TrainGpu", "BenchCpu", "BenchGpu"})
        for name, res in t["Resources"].items():
            with self.subTest(job=name):
                self.assertEqual(res["Type"], "AWS::Batch::JobDefinition")
                self.assertEqual(res["Condition"], "HasGpu" if "Gpu" in name else "HasCpu")
                cp = res["Properties"]["ContainerProperties"]
                self.assertTrue(cp["ReadonlyRootFilesystem"])
                self.assertFalse(cp["Privileged"])
                self.assertEqual(cp["User"], "10001:10001")
                self.assertEqual(cp["LogConfiguration"]["LogDriver"], "awslogs")
                self.assertEqual(cp["LinuxParameters"]["Tmpfs"][0]["ContainerPath"], "/tmp")
                gpu = [r for r in cp["ResourceRequirements"] if r["Type"] == "GPU"]
                self.assertEqual(len(gpu), 1 if "Gpu" in name else 0)
        self.assertEqual(t["Parameters"]["CpuImageUri"]["Default"], "")
        self.assertEqual(t["Parameters"]["GpuImageUri"]["Default"], "")

    def test_ui_host_template(self):
        t = load_template(RAPTGEN / "ui" / "ec2.yaml")
        sg = t["Resources"]["UiSecurityGroup"]["Properties"]
        self.assertNotIn("SecurityGroupIngress", sg)
        lt = t["Resources"]["UiLaunchTemplate"]["Properties"]["LaunchTemplateData"]
        self.assertEqual(lt["MetadataOptions"]["HttpTokens"], "required")
        self.assertFalse(lt["NetworkInterfaces"][0]["AssociatePublicIpAddress"])
        self.assertTrue(lt["BlockDeviceMappings"][0]["Ebs"]["Encrypted"])
        self.assertEqual(t["Parameters"]["InstanceType"]["Default"], "m7i.2xlarge")
        self.assertNotIn("KeyName", lt)

    def test_origin_access_template(self):
        t = load_template(RAPTGEN / "ui-web" / "origin-access.yaml")
        self.assertEqual(list(t["Resources"]), ["FromCloudFrontVpcOrigin"])


class DataFilesTest(unittest.TestCase):
    def test_benchmark_jsonl(self):
        paths = list((RAPTGEN / "results" / "benchmark").glob("*.jsonl"))
        self.assertGreaterEqual(len(paths), 2)
        for path in paths:
            runs = 0
            for line in path.read_text().splitlines():
                event = json.loads(line)
                self.assertIn("event", event)
                if event["event"] == "run":
                    runs += 1
                    self.assertGreater(event["seconds_per_epoch"], 0)
                if event["event"] == "env":
                    self.assertIn("torch", event)
            self.assertGreaterEqual(runs, 2, path.name)

    def test_lock_files_are_hash_pinned(self):
        for variant in ("cpu", "gpu"):
            for name in ("requirements.lock", "requirements-s3.lock"):
                text = (RAPTGEN / "containers" / variant / name).read_text()
                pins = re.findall(r"^[A-Za-z0-9_.-]+==\S+", text, re.M)
                self.assertGreater(len(pins), 3)
                self.assertEqual(len(pins), len(re.findall(r"^\S+==\S+ \\\n\s+--hash=sha256:[0-9a-f]{64}", text, re.M)))

    def test_cpu_and_gpu_share_sources(self):
        for name in ("requirements.lock", "requirements-s3.lock", "raptgen_job.py", "bench.sh", "smoke-test.sh",
                     "raptgen_contract.py", "tool-version.sh", "source-checksums.sha256", "patched-checksums.sha256"):
            self.assertEqual((RAPTGEN / "containers/cpu" / name).read_bytes(),
                             (RAPTGEN / "containers/gpu" / name).read_bytes(), name)

    def test_dockerfiles_are_non_root_without_expose(self):
        for variant in ("cpu", "gpu"):
            text = (RAPTGEN / "containers" / variant / "Dockerfile").read_text()
            self.assertIn("USER 10001:10001", text)
            self.assertNotRegex(text, r"(?m)^EXPOSE")
            self.assertIn("--require-hashes", text)

    def test_images_present_and_clean_names(self):
        pngs = sorted(IMAGES.glob("*.png"))
        self.assertGreaterEqual(len(pngs), 11)
        for p in pngs:
            self.assertRegex(p.name, r"^(ui|web)-\d\d-[a-z-]+\.png$")


class SensitiveStringTest(unittest.TestCase):
    FORBIDDEN = _local_terms()
    REGEXES = [r"\bi-0[0-9a-f]{8,17}\b", r"\bsg-0[0-9a-f]{8,17}\b", r"\bvpc-0[0-9a-f]{8,17}\b",
               r"\bsubnet-0[0-9a-f]{8,17}\b", r"\bvo_[A-Za-z0-9]{10,}\b", r"\bvpce-[0-9a-f]{8,}\b",
               r"\bnat-[0-9a-f]{8,}\b", r"\b[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[^\s'\"]*@sha256:[0-9a-f]{64}",
               r"(?<![0-9])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])"]
    ALLOWED_ACCOUNT = {"123456789012"}

    def test_no_sensitive_strings(self):
        hits = []
        for path in files():
            data = path.read_bytes()
            if b"\0" in data:
                continue
            text = data.decode("utf-8", errors="replace")
            rel = str(path.relative_to(ROOT))
            for needle in self.FORBIDDEN:
                if needle in text:
                    # Report file and line only: never echo any part of a forbidden term.
                    hits.append(f"{rel}:{text.count(chr(10), 0, text.find(needle)) + 1}: forbidden term")
            for rx in self.REGEXES:
                m = re.search(rx, text)
                if m and not rel.endswith("package-lock.json"):
                    hits.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1}: identifier-like value")
            for acct in re.findall(r"(?<![0-9a-f-])[0-9]{12}(?![0-9])(?=[:/\"'\s,)]|$)", text):
                if re.search(r"(arn:|dkr\.ecr|account)", text) and acct not in self.ALLOWED_ACCOUNT and not rel.endswith("package-lock.json"):
                    if re.search(rf"(arn:[^\s]*:{acct}:|{acct}\.dkr)", text):
                        hits.append(f"{rel}: account id")
        for p in IMAGES.glob("*"):
            for needle in self.FORBIDDEN:
                if needle in p.name:
                    hits.append(f"image file name {sorted(IMAGES.glob('*')).index(p) + 1}: forbidden term")
        self.assertEqual(hits, [])


class PatchApplyTest(unittest.TestCase):
    def test_patches_apply_to_pinned_ui_checkout(self):
        if not shutil.which("git"):
            self.skipTest("git not installed")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "ui"
            steps = [["git", "init", "-q", str(repo)],
                     ["git", "-C", str(repo), "remote", "add", "origin", "https://github.com/hmdlab/RaptGen-UI.git"],
                     ["git", "-C", str(repo), "fetch", "-q", "--depth", "1", "origin", UI_COMMIT],
                     ["git", "-C", str(repo), "checkout", "-q", "--detach", "FETCH_HEAD"]]
            for step in steps:
                try:
                    r = subprocess.run(step, capture_output=True, text=True, timeout=180)
                except subprocess.TimeoutExpired:
                    self.skipTest("network timeout")
                if r.returncode != 0:
                    self.skipTest("RaptGen-UI checkout unavailable (no network?): " + r.stderr[-200:])
            patches = sorted((RAPTGEN / "ui" / "patches").glob("0*.patch")) + \
                sorted((RAPTGEN / "ui" / "patches" / "optional").glob("*.patch"))
            self.assertEqual(len(patches), 4)
            for p in patches:
                r = subprocess.run(["git", "-C", str(repo), "apply", str(p)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, f"{p.name}: {r.stderr}")
            compose = (repo / "compose.yml").read_text()
            self.assertIn('"${UI_BIND_ADDR:-127.0.0.1}:18042:18042"', compose)
            self.assertIn('new Zodios("/api"', (repo / "frontend/services/api-client.ts").read_text())


class CpuImageBuildTest(unittest.TestCase):
    def test_cpu_image_builds_and_passes_smoke(self):
        if not shutil.which("docker"):
            self.skipTest("docker not installed")
        if subprocess.run(["docker", "info"], capture_output=True).returncode != 0:
            self.skipTest("docker daemon not reachable")
        if shutil.disk_usage(tempfile.gettempdir()).free < 20 * 2**30:
            self.skipTest("less than 20 GB free")
        tag = "raptgen-contract-test:cpu"
        build = subprocess.run(["docker", "build", "-q", "-t", tag, str(RAPTGEN / "containers" / "cpu")],
                               capture_output=True, text=True)
        if build.returncode != 0 and "dial tcp" in build.stderr + build.stdout:
            self.skipTest("no network for docker build")
        self.assertEqual(build.returncode, 0, build.stderr[-2000:])
        try:
            run = subprocess.run(
                ["docker", "run", "--rm", "--network", "none", "--read-only", "--tmpfs", "/tmp:rw,nosuid,size=2g",
                 "--tmpfs", "/smoke-out:rw,nosuid,size=1g,uid=10001,gid=10001", "--user", "10001:10001",
                 "-e", "SMOKE_OUT=/smoke-out", tag, "/usr/local/bin/smoke-test"], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr[-2000:])
            result = json.loads(run.stdout.strip().splitlines()[-1])
            self.assertEqual(result["status"], "PASS_WITH_LIMIT")
        finally:
            subprocess.run(["docker", "rmi", "-f", tag], capture_output=True)


if __name__ == "__main__":
    unittest.main()
