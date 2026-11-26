"""Static contract tests for the CloudFormation templates (no AWS calls)."""
import shutil
import subprocess
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is optional for the rest of the suite
    yaml = None

ROOT = Path(__file__).parents[1]
NETWORK = ROOT / "batch" / "network.yaml"
BATCH = ROOT / "batch" / "infrastructure.yaml"
HEALTHOMICS = ROOT / "healthomics" / "infrastructure.yaml"
HEALTHOMICS_VPC = ROOT / "healthomics" / "vpc" / "vpc.yaml"
TEMPLATES = [NETWORK, BATCH, HEALTHOMICS, HEALTHOMICS_VPC]


if yaml is None:
    raise unittest.SkipTest("PyYAML is not installed")


class CfnLoader(yaml.SafeLoader):
    """SafeLoader that turns CloudFormation short-form tags into {'Fn': value}."""


def _construct(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_mapping(node, deep=True)
    return {suffix: value}


CfnLoader.add_multi_constructor("!", _construct)


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return yaml.load(stream, Loader=CfnLoader)


class TemplateParseTest(unittest.TestCase):
    def test_templates_parse(self):
        for path in TEMPLATES:
            with self.subTest(template=path.name):
                document = load(path)
                self.assertEqual(document["AWSTemplateFormatVersion"], "2010-09-09")
                self.assertIsInstance(document["Resources"], dict)

    @unittest.skipUnless(shutil.which("cfn-lint"), "cfn-lint is not installed")
    def test_cfn_lint_clean(self):
        result = subprocess.run(
            ["cfn-lint", *map(str, TEMPLATES)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class NetworkTemplateTest(unittest.TestCase):
    def setUp(self):
        self.doc = load(NETWORK)

    def test_contract_outputs(self):
        for name in ("VpcId", "PrivateSubnetIds", "PrivateRouteTableIds", "VpcCidr"):
            self.assertIn(name, self.doc["Outputs"])

    def test_private_subnets_in_two_different_azs(self):
        resources = self.doc["Resources"]
        az1 = resources["PrivateSubnet1"]["Properties"]["AvailabilityZone"]["If"]
        az2 = resources["PrivateSubnet2"]["Properties"]["AvailabilityZone"]["If"]
        self.assertEqual(az1[2]["Select"][0], 0)
        self.assertEqual(az2[2]["Select"][0], 1)
        self.assertIn("DistinctAvailabilityZones", self.doc["Rules"])
        for name in ("PrivateSubnet1", "PrivateSubnet2", "NatSubnet"):
            self.assertFalse(resources[name]["Properties"]["MapPublicIpOnLaunch"])

    def test_private_routes_use_nat(self):
        resources = self.doc["Resources"]
        for name in ("PrivateDefaultRoute1", "PrivateDefaultRoute2"):
            self.assertIn("NatGatewayId", resources[name]["Properties"])


class BatchTemplateTest(unittest.TestCase):
    def setUp(self):
        self.doc = load(BATCH)
        self.resources = self.doc["Resources"]

    def test_gpu_parameters(self):
        params = self.doc["Parameters"]
        self.assertEqual(params["EnableCpu"]["Default"], "true")
        self.assertEqual(params["EnableGpu"]["Default"], "false")
        self.assertEqual(params["GpuInstanceTypes"]["Default"], "g5.xlarge,g6.xlarge")
        self.assertEqual(params["GpuMaxvCpus"]["Default"], 8)
        self.assertIn("MaxvCpus", params)
        self.assertIn("InstanceTypes", params)

    def test_rules_reject_no_compute(self):
        rule = self.doc["Rules"]["AtLeastOneComputeType"]["Assertions"][0]["Assert"]
        self.assertEqual(
            rule,
            {"Or": [{"Equals": [{"Ref": "EnableCpu"}, "true"]}, {"Equals": [{"Ref": "EnableGpu"}, "true"]}]},
        )
        self.assertIn("CpuInputsRequired", self.doc["Rules"])

    def test_gpu_compute_environment(self):
        ce = self.resources["GpuComputeEnvironment"]
        self.assertEqual(ce["Condition"], "GpuEnabled")
        compute = ce["Properties"]["ComputeResources"]
        self.assertEqual(compute["Ec2Configuration"], [{"ImageType": "ECS_AL2023_NVIDIA"}])
        self.assertEqual(compute["Subnets"], {"Ref": "PrivateSubnetIds"})
        self.assertEqual(compute["SecurityGroupIds"], [{"Ref": "ComputeSecurityGroup"}])
        self.assertEqual(compute["MinvCpus"], 0)
        self.assertEqual(self.resources["GpuJobQueue"]["Condition"], "GpuEnabled")
        lt = self.resources["GpuLaunchTemplate"]["Properties"]["LaunchTemplateData"]
        self.assertEqual(lt["MetadataOptions"]["HttpTokens"], "required")
        self.assertEqual(lt["MetadataOptions"]["HttpPutResponseHopLimit"], 1)
        self.assertTrue(lt["BlockDeviceMappings"][0]["Ebs"]["Encrypted"])

    def test_cpu_resources_conditioned(self):
        for name in (
            "ComputeEnvironment", "JobQueue", "ComputeLaunchTemplate", "ImageBuildProject",
            "ImageBuildRole", "PipelineJobDefinition", "MountpointJobDefinition", "DataLoaderJobDefinition",
        ):
            with self.subTest(resource=name):
                self.assertEqual(self.resources[name].get("Condition"), "CpuEnabled")
        cpu = self.resources["ComputeEnvironment"]["Properties"]["ComputeResources"]
        self.assertEqual(cpu["Ec2Configuration"], [{"ImageType": "ECS_AL2023"}])

    def test_raptgen_repositories(self):
        for name, suffix in (("RaptgenCpuRepository", "raptgen-cpu"), ("RaptgenGpuRepository", "raptgen-gpu")):
            with self.subTest(repository=name):
                repo = self.resources[name]
                props = repo["Properties"]
                self.assertNotIn("Condition", repo)
                self.assertEqual(props["RepositoryName"], {"Sub": "${AWS::StackName}-" + suffix})
                self.assertEqual(props["ImageTagMutability"], "IMMUTABLE")
                self.assertTrue(props["ImageScanningConfiguration"]["ScanOnPush"])
                self.assertEqual(props["EncryptionConfiguration"]["EncryptionType"], "KMS")
                self.assertNotIn("RepositoryPolicyText", props)

    def test_outputs(self):
        outputs = self.doc["Outputs"]
        always = (
            "JobQueueName", "PipelineJobRoleArn", "WorkBucketName", "DataBucketName", "RepositoryUri",
            "LogGroupName", "RaptgenCpuRepositoryUri", "RaptgenGpuRepositoryUri", "KmsKeyArn",
        )
        for name in always:
            with self.subTest(output=name):
                self.assertIn(name, outputs)
                self.assertNotIn("Condition", outputs[name])
        self.assertEqual(outputs["CpuJobQueueName"]["Condition"], "CpuEnabled")
        self.assertEqual(outputs["GpuJobQueueName"]["Condition"], "GpuEnabled")
        self.assertIn("If", outputs["JobQueueName"]["Value"])

    def test_no_public_exposure(self):
        text = BATCH.read_text()
        self.assertNotIn("SecurityGroupIngress", text)
        self.assertNotIn("MapPublicIpOnLaunch: true", text)
        self.assertNotIn("AssociatePublicIpAddress", text)


class HealthOmicsVpcTemplateTest(unittest.TestCase):
    def setUp(self):
        self.doc = load(HEALTHOMICS_VPC)
        self.resources = self.doc["Resources"]

    def test_marked_not_yet_validated(self):
        self.assertIn("NOT YET VALIDATED", self.doc["Description"])
        self.assertEqual(self.doc["Outputs"]["ValidationStatus"]["Value"], "not yet validated")

    def test_run_security_group_https_egress_only(self):
        props = self.resources["RunSecurityGroup"]["Properties"]
        self.assertNotIn("SecurityGroupIngress", props)
        self.assertEqual(
            [(r["IpProtocol"], r["FromPort"], r["ToPort"]) for r in props["SecurityGroupEgress"]],
            [("tcp", 443, 443)],
        )

    def test_omics_configuration(self):
        config = self.resources["OmicsConfiguration"]
        self.assertEqual(config["Type"], "AWS::Omics::Configuration")
        vpc = config["Properties"]["RunConfigurations"]["VpcConfig"]
        self.assertEqual(vpc["SecurityGroupIds"], [{"Ref": "RunSecurityGroup"}])
        self.assertEqual(vpc["SubnetIds"], {"Ref": "PrivateSubnetIds"})

    def test_interface_endpoints_opt_in(self):
        self.assertEqual(self.doc["Parameters"]["CreateInterfaceEndpoints"]["Default"], "false")
        services = set()
        for resource in self.resources.values():
            if resource["Type"] == "AWS::EC2::VPCEndpoint":
                self.assertEqual(resource["Condition"], "MakeEndpoints")
                services.add(resource["Properties"]["ServiceName"]["Sub"].rsplit(".", 1)[1])
        self.assertEqual(
            services,
            {"workflows-omics", "storage-omics", "control-storage-omics", "analytics-omics", "tags-omics"},
        )
        ingress = self.resources["EndpointSecurityGroup"]["Properties"]["SecurityGroupIngress"]
        self.assertEqual(ingress[0]["CidrIp"], {"Ref": "VpcCidr"})

    def test_restricted_template_unchanged_contract(self):
        doc = load(HEALTHOMICS)
        for name in ("BucketName", "RepositoryUri", "PipelineImage", "RunRoleArn", "KmsKeyArn"):
            self.assertIn(name, doc["Outputs"])


if __name__ == "__main__":
    unittest.main()
