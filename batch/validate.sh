#!/usr/bin/env bash
# Offline syntax, CloudFormation, exposure, and public-safety checks. Makes no AWS calls.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
rc=0

echo '== YAML parse'
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - network.yaml infrastructure.yaml <<'PY' || rc=1
import sys, yaml
class Loader(yaml.SafeLoader):
    pass
def construct(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)
Loader.add_multi_constructor('!', construct)
for path in sys.argv[1:]:
    with open(path, encoding='utf-8') as stream:
        document = yaml.load(stream, Loader=Loader)
    assert isinstance(document.get('Resources'), dict)
    print(f"ok  {path}: {len(document['Resources'])} resources")
PY
else
  echo 'skip: PyYAML is unavailable'
fi

echo '== cfn-lint'
if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint --template network.yaml infrastructure.yaml || rc=1
else
  echo 'skip: cfn-lint is unavailable'
fi

echo '== bash -n'
for file in ./*.sh ./lib/*.sh; do
  if bash -n "$file"; then echo "ok  $file"; else rc=1; fi
done

echo '== shellcheck'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning ./*.sh ./lib/*.sh || rc=1
else
  echo 'skip: shellcheck is unavailable'
fi

echo '== JSON parse'
while IFS= read -r json_file; do
  python3 -m json.tool "$json_file" >/dev/null || rc=1
done < <(find . -type f -name '*.json' -print)

echo '== exposure checks'
exposure_pattern='SecurityGroup'"Ingress"'|FromPort:[[:space:]]*(22|3389)|MapPublicIpOnLaunch:[[:space:]]*true|PubliclyAccessible:[[:space:]]*true'
if grep -RInE "$exposure_pattern" .; then
  echo 'FAIL: inbound, remote-admin, or public-address configuration found' >&2
  rc=1
else
  echo 'ok  no inbound rules, SSH/RDP rules, or public resource flags'
fi
if ! grep -q 'HttpPutResponseHopLimit: 1' infrastructure.yaml; then
  echo 'FAIL: IMDS hop limit 1 is missing' >&2; rc=1
fi
if ! grep -q 'ReadOnly: true' infrastructure.yaml || ! grep -q -- '--read-only' infrastructure.yaml; then
  echo 'FAIL: read-only Mountpoint controls are missing' >&2; rc=1
fi
for setting in BlockPublicAcls BlockPublicPolicy IgnorePublicAcls RestrictPublicBuckets; do
  count=$(grep -c "$setting: true" infrastructure.yaml || true)
  [[ "$count" -ge 2 ]] || { echo "FAIL: $setting is missing from a bucket" >&2; rc=1; }
done

echo '== sensitive-string checks'
sensitive_pattern='(/local/'"home/"'|/'"home/"'[^/]+/|code\.'"amazon\.com"'|w\.'"amazon\.com"'|a2z\.'"com"'|corp\.'"amazon\.com"'|arn:aws[^:]*:[^:]*:[^:]*:[0-9]{12}:|(^|[^0-9])[0-9]{12}([^0-9]|$))'
if grep -RInE "$sensitive_pattern" .; then
  echo 'FAIL: internal path, internal URL, or fixed account identifier found' >&2
  rc=1
else
  echo 'ok  no internal paths, internal URLs, or fixed account identifiers'
fi
exit "$rc"
