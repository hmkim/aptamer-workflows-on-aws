import pathlib
import pathlib
"""Behavior tests for scripts/ and healthomics/ shell entry points with a fake AWS CLI."""
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
SCRIPTS = ROOT / "scripts"
OWNED_SHELL = sorted(
    [*SCRIPTS.glob("*.sh"), *SCRIPTS.glob("lib/*.sh"), *(ROOT / "healthomics").rglob("*.sh")]
)

FAKE_AWS = r'''#!/usr/bin/env python3
"""Minimal stand-in for the AWS CLI. Stores stack state as JSON files."""
import json, os, re, sys
from pathlib import Path

state = Path(os.environ["FAKE_AWS_STATE"])
args = sys.argv[1:]
with open(os.environ["FAKE_AWS_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")

def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default

# Strip global options.
clean = []
skip = False
for i, a in enumerate(args):
    if skip:
        skip = False
        continue
    if a in ("--region",):
        skip = True
        continue
    if a == "--no-cli-pager":
        continue
    clean.append(a)
service, op = clean[0], clean[1]

OUTPUTS = {
    "network.yaml": {"VpcId": "vpc-0example", "PrivateSubnetIds": "subnet-0a,subnet-0b",
                     "PrivateRouteTableIds": "rtb-0a,rtb-0b", "VpcCidr": "10.64.0.0/16"},
    "infrastructure.yaml@batch": {"DataBucketName": "data-bkt", "WorkBucketName": "work-bkt",
                     "RepositoryUri": "123456789012.dkr.ecr.us-west-2.amazonaws.com/x-pipeline",
                     "RaptgenCpuRepositoryUri": "123456789012.dkr.ecr.us-west-2.amazonaws.com/x-raptgen-cpu",
                     "RaptgenGpuRepositoryUri": "123456789012.dkr.ecr.us-west-2.amazonaws.com/x-raptgen-gpu",
                     "KmsKeyArn": "arn:aws:kms:us-west-2:123456789012:key/example",
                     "LogGroupName": "/aws/batch/x", "JobQueueName": "x-queue"},
    "infrastructure.yaml@healthomics": {"BucketName": "ho-bkt",
                     "RepositoryUri": "123456789012.dkr.ecr.us-west-2.amazonaws.com/ho",
                     "KmsKeyArn": "arn:aws:kms:us-west-2:123456789012:key/ho"},
    "vpc.yaml": {"RunSecurityGroupId": "sg-0abc", "SubnetIds": "subnet-0a,subnet-0b"},
}

def stack_file(name):
    return state / f"{name}.json"

if service == "cloudformation":
    name = opt("--stack-name")
    if op == "describe-stacks":
        f = stack_file(name)
        if not f.exists():
            sys.stderr.write(f"An error occurred (ValidationError): Stack with id {name} does not exist\n")
            sys.exit(254)
        data = json.loads(f.read_text())
        query = opt("--query", "")
        m = re.search(r"OutputKey=='(\w+)'", query)
        p = re.search(r"ParameterKey=='(\w+)'", query)
        if query.endswith("StackStatus"):
            print(data["status"])
        elif m:
            print(data["outputs"].get(m.group(1), "None"))
        elif p:
            print(data["params"].get(p.group(1), "None"))
        else:
            print(json.dumps(data["outputs"]))
    elif op == "deploy":
        template = Path(opt("--template-file"))
        key = template.name
        if key == "infrastructure.yaml":
            key += "@" + template.parent.name if template.parent.name == "healthomics" else "@batch"
        f = stack_file(name)
        data = json.loads(f.read_text()) if f.exists() else {"params": {}}
        if "--parameter-overrides" in args:
            for kv in args[args.index("--parameter-overrides") + 1:]:
                if kv.startswith("--"):
                    break
                k, v = kv.split("=", 1)
                data["params"][k] = v
        data.update(status="CREATE_COMPLETE", outputs=OUTPUTS.get(key, {}))
        f.write_text(json.dumps(data))
    elif op == "delete-stack":
        stack_file(name).unlink(missing_ok=True)
    elif op == "wait":
        pass
    sys.exit(0)
if service == "service-quotas":
    print("64.0"); sys.exit(0)
if service == "omics":
    if op in ("get-configuration", "get-workflow"):
        print("ACTIVE")
    elif op == "start-run":
        print(json.dumps({"id": "1234567", "arn": "arn:example", "status": "PENDING", "name": "n"}))
    sys.exit(0)
if service == "s3api" and op == "head-bucket":
    sys.exit(1)
sys.exit(0)
'''



def _local_terms():
    """Project-specific forbidden strings live in an untracked file (.sensitive-terms, one per line)
    so this public test never contains them. Missing file -> only the generic regex checks run."""
    p = pathlib.Path(__file__).resolve().parents[1] / ".sensitive-terms"
    if not p.exists():
        return []
    return [t.strip() for t in p.read_text(encoding="utf-8").splitlines() if t.strip() and not t.startswith("#")]

class ScriptSyntaxTest(unittest.TestCase):
    def test_bash_n(self):
        self.assertTrue(OWNED_SHELL)
        for path in OWNED_SHELL:
            with self.subTest(script=str(path.relative_to(ROOT))):
                subprocess.run(["bash", "-n", str(path)], check=True)

    def test_strict_mode_and_executable(self):
        for path in OWNED_SHELL:
            with self.subTest(script=str(path.relative_to(ROOT))):
                self.assertRegex(path.read_text(), r"set -E?euo pipefail")
                if path.parent.name != "lib":
                    self.assertTrue(os.access(path, os.X_OK))


class FakeAwsTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "bin").mkdir()
        (root / "state").mkdir()
        aws = root / "bin" / "aws"
        aws.write_text(FAKE_AWS)
        aws.chmod(0o755)
        self.log = root / "aws.log"
        self.log.touch()
        self.state = root / "state"
        self.env = {
            "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
            "HOME": str(root),
            "FAKE_AWS_STATE": str(self.state),
            "FAKE_AWS_LOG": str(self.log),
            "AWS_REGION": "us-west-2",
        }

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *argv, check=True, stdin=subprocess.DEVNULL):
        return subprocess.run(
            ["bash", *map(str, argv)], env=self.env, text=True, capture_output=True,
            check=False, stdin=stdin,
        ) if not check else self._checked(argv, stdin)

    def _checked(self, argv, stdin):
        result = subprocess.run(
            ["bash", *map(str, argv)], env=self.env, text=True, capture_output=True, stdin=stdin
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def deploys(self):
        out = []
        for call in self.calls():
            if "deploy" in call:
                stack = call[call.index("--stack-name") + 1]
                params = {}
                if "--parameter-overrides" in call:
                    for kv in call[call.index("--parameter-overrides") + 1:]:
                        if kv.startswith("--"):
                            break
                        k, v = kv.split("=", 1)
                        params[k] = v
                out.append((stack, params, call))
        return out


SHA = "a" * 64


class SetupScriptsTest(FakeAwsTestCase):
    def test_batch_gpu_only_creates_network_first(self):
        self.run_script(SCRIPTS / "setup-batch.sh", "--gpu", "--prefix", "t1")
        deploys = self.deploys()
        self.assertEqual([d[0] for d in deploys], ["t1-network", "t1-batch"])
        params = deploys[1][1]
        self.assertEqual(params["EnableCpu"], "false")
        self.assertEqual(params["EnableGpu"], "true")
        self.assertNotIn("ImageTag", params)
        self.assertNotIn("MountpointVersion", params)
        self.assertEqual(params["VpcId"], "vpc-0example")
        self.assertIn("--no-fail-on-empty-changeset", deploys[1][2])
        self.assertIn("CAPABILITY_NAMED_IAM", deploys[1][2])

    def test_batch_default_is_cpu_only(self):
        self.run_script(SCRIPTS / "setup-batch.sh", "--prefix", "t2", "--mountpoint-sha256", SHA)
        params = self.deploys()[-1][1]
        self.assertEqual((params["EnableCpu"], params["EnableGpu"]), ("true", "false"))
        self.assertRegex(params["ImageTag"], r"^(git|build)-")
        self.assertEqual(params["MountpointVersion"], "1.25.0")
        self.assertEqual(params["MountpointPackageSha256"], SHA)

    def test_batch_cpu_and_gpu(self):
        self.run_script(SCRIPTS / "setup-batch.sh", "--cpu", "--gpu", "--prefix", "t3",
                        "--mountpoint-sha256", SHA, "--gpu-max-vcpus", "16")
        params = self.deploys()[-1][1]
        self.assertEqual((params["EnableCpu"], params["EnableGpu"]), ("true", "true"))
        self.assertEqual(params["GpuMaxvCpus"], "16")

    def test_batch_rerun_keeps_previous_image_tag(self):
        self.run_script(SCRIPTS / "setup-batch.sh", "--prefix", "t4", "--image-tag", "v1",
                        "--mountpoint-sha256", SHA)
        self.run_script(SCRIPTS / "setup-batch.sh", "--prefix", "t4")
        last = self.deploys()[-1][1]
        self.assertEqual(last["ImageTag"], "v1")
        self.assertEqual(last["MountpointPackageSha256"], SHA)
        self.assertEqual([d[0] for d in self.deploys()].count("t4-network"), 1)

    def test_healthomics_only_creates_no_network(self):
        self.run_script(SCRIPTS / "setup-healthomics.sh", "--prefix", "t5")
        self.assertEqual([d[0] for d in self.deploys()], ["t5-healthomics"])
        self.assertIn("CAPABILITY_IAM", self.deploys()[0][2])

    def test_healthomics_vpc(self):
        result = self.run_script(SCRIPTS / "setup-healthomics.sh", "--prefix", "t6", "--vpc")
        stacks = [d[0] for d in self.deploys()]
        self.assertEqual(stacks, ["t6-healthomics", "t6-network", "t6-healthomics-vpc"])
        params = self.deploys()[-1][1]
        self.assertEqual(params["CreateConfiguration"], "true")
        self.assertEqual(params["ConfigurationName"], "t6-vpc")
        self.assertEqual(params["CreateInterfaceEndpoints"], "false")
        self.assertEqual(params["VpcCidr"], "10.64.0.0/16")
        self.assertIn("NOT YET VALIDATED", result.stderr)

    def test_setup_all(self):
        self.run_script(SCRIPTS / "setup-all.sh", "--prefix", "t7", "--gpu")
        self.assertEqual([d[0] for d in self.deploys()], ["t7-network", "t7-batch", "t7-healthomics"])

    def test_invalid_prefix_rejected(self):
        result = self.run_script(SCRIPTS / "setup-network.sh", "--prefix", "Bad_Prefix", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


class CleanupTest(FakeAwsTestCase):
    def deploy_all(self, prefix):
        self.run_script(SCRIPTS / "setup-batch.sh", "--gpu", "--prefix", prefix)
        self.run_script(SCRIPTS / "setup-healthomics.sh", "--prefix", prefix, "--vpc")
        self.log.write_text("")

    def deletes(self):
        return [c[c.index("--stack-name") + 1] for c in self.calls() if "delete-stack" in c]

    def test_requires_confirmation_without_tty(self):
        self.deploy_all("c1")
        result = self.run_script(SCRIPTS / "cleanup.sh", "--prefix", "c1", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.deletes(), [])

    def test_reverse_order_and_keeps_data(self):
        self.deploy_all("c2")
        self.run_script(SCRIPTS / "cleanup.sh", "--prefix", "c2", "--yes")
        self.assertEqual(self.deletes(), ["c2-healthomics-vpc", "c2-healthomics", "c2-batch", "c2-network"])
        flat = " ".join(" ".join(c) for c in self.calls())
        for forbidden in ("delete-bucket", "delete-repository", "schedule-key-deletion", "delete-log-group"):
            self.assertNotIn(forbidden, flat)

    def test_delete_data(self):
        self.deploy_all("c3")
        self.run_script(SCRIPTS / "cleanup.sh", "--prefix", "c3", "--yes", "--delete-data")
        flat = [" ".join(c) for c in self.calls()]
        self.assertTrue(any("ecr delete-repository --repository-name x-raptgen-gpu" in c for c in flat))
        self.assertTrue(any("schedule-key-deletion" in c for c in flat))

    def test_network_protected_while_batch_exists(self):
        self.deploy_all("c4")
        result = self.run_script(SCRIPTS / "cleanup.sh", "--prefix", "c4", "--stacks", "network", "--yes",
                                 check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.deletes(), [])


class OrchestrateNetworkingTest(FakeAwsTestCase):
    def run_env(self, **extra):
        env = dict(self.env)
        env.update(
            WORKFLOW_ID="1234",
            BUCKET_NAME="bkt",
            SAMPLESHEET_URI="s3://bkt/inputs/samplesheet.tsv",
            PIPELINE_IMAGE="123456789012.dkr.ecr.us-west-2.amazonaws.com/repo:tag",
            RUN_ROLE_ARN="arn:aws:iam::123456789012:role/run",
            FRONT_PRIMER="ACGT",
            BACK_PRIMER="TTTT",
            RUN_NAME="unit",
        )
        env.update(extra)
        return env

    def start_run_call(self):
        return next(c for c in self.calls() if "start-run" in c)

    def orchestrate(self, *argv, **extra):
        with tempfile.TemporaryDirectory() as work:
            # Copy the script so its .state directory stays out of the repository.
            script_dir = Path(work) / "healthomics"
            script_dir.mkdir()
            (script_dir / "orchestrate.sh").write_text((ROOT / "healthomics" / "orchestrate.sh").read_text())
            return subprocess.run(
                ["bash", str(script_dir / "orchestrate.sh"), "run", *argv],
                env=self.run_env(**extra), text=True, capture_output=True,
            )

    def test_default_restricted(self):
        result = self.orchestrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.start_run_call()
        self.assertEqual(call[call.index("--networking-mode") + 1], "RESTRICTED")
        self.assertNotIn("--configuration-name", call)
        self.assertIn("PRIVATE", call)

    def test_vpc_mode(self):
        result = self.orchestrate("--networking-mode", "VPC", "--configuration-name", "cfg-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.start_run_call()
        self.assertEqual(call[call.index("--networking-mode") + 1], "VPC")
        self.assertEqual(call[call.index("--configuration-name") + 1], "cfg-1")
        self.assertIn("not yet validated", result.stderr)

    def test_vpc_mode_requires_configuration(self):
        result = self.orchestrate("--networking-mode", "VPC")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("start-run" in c for c in self.calls()))


class SensitiveStringTest(unittest.TestCase):
    """Files owned by the infrastructure work must not carry environment-specific data."""

    OWNED = [
        ROOT / "batch" / "network.yaml",
        ROOT / "batch" / "infrastructure.yaml",
        ROOT / "batch" / "README.md",
        ROOT / "healthomics" / "README.md",
        ROOT / "healthomics" / "infrastructure.yaml",
        ROOT / "healthomics" / "vpc" / "vpc.yaml",
        ROOT / "healthomics" / "vpc" / "README.md",
        *OWNED_SHELL,
        *(ROOT / "batch" / "lib").glob("*.sh"),
    ]
    LITERALS = _local_terms()
    REAL_ID = re.compile(r"\b(i|sg|vpc|subnet|vpce|nat)-0[0-9a-f]{8,17}\b|\bvo_[A-Za-z0-9]+")

    def test_no_sensitive_strings(self):
        problems = []
        for path in self.OWNED:
            text = path.read_text(encoding="utf-8")
            for literal in self.LITERALS:
                if literal.lower() in text.lower():
                    problems.append(f"{path.relative_to(ROOT)}: {literal!r}")
            for match in self.REAL_ID.finditer(text):
                problems.append(f"{path.relative_to(ROOT)}: {match.group(0)!r}")
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
