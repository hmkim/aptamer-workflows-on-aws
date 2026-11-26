#!/usr/bin/env bash
# Create a RaptGen-UI user in a role group with a random permanent password.
# The password is never printed: it is stored in Secrets Manager
# /<name-prefix>/users/<username> (read it there; default /raptgen-ui-web/users/<username>,
# for UI_WEB_STACK=<name> it is /<name in lower case>/users/<username>). Temporary files are 0600 in a private
# directory and removed on exit.
# Usage: [UI_WEB_STACK=<stack>] scripts/add-user.sh <username> full|readonly
set -euo pipefail
# shellcheck source=names.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/names.sh"
[[ $# -eq 2 ]] || { echo "usage: $0 <username> full|readonly" >&2; exit 2; }
user=$1
case $2 in full) group=raptgen-full ;; readonly) group=raptgen-readonly ;; *) echo "role must be full|readonly" >&2; exit 2 ;; esac
[[ $user =~ ^[a-z0-9][a-z0-9-]{2,40}$ ]] || { echo "bad username" >&2; exit 2; }
POOL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
umask 077
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
pwfile="$dir/$user.pw"
python3 - "$pwfile" <<'PY'
import secrets, string, sys
a = string.ascii_letters + string.digits
pw = (secrets.choice(string.ascii_uppercase) + secrets.choice(string.ascii_lowercase)
      + secrets.choice(string.digits) + secrets.choice("!#%+-=?@^_")
      + "".join(secrets.choice(a) for _ in range(16)))
pw = "".join(secrets.SystemRandom().sample(pw, len(pw)))
open(sys.argv[1], "w").write(pw)
PY
python3 - "$pwfile" "$POOL" "$user" "$dir/$user.set.json" "$dir/$user.secret.json" <<'PY'
import json, sys
pw = open(sys.argv[1]).read()
json.dump({"UserPoolId": sys.argv[2], "Username": sys.argv[3], "Password": pw, "Permanent": True}, open(sys.argv[4], "w"))
json.dump({"username": sys.argv[3], "password": pw}, open(sys.argv[5], "w"))
PY
aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL" --username "$user" \
  --message-action SUPPRESS --query 'User.Username' --output text
aws cognito-idp admin-set-user-password --region "$REGION" --cli-input-json "file://$dir/$user.set.json"
aws cognito-idp admin-add-user-to-group --region "$REGION" --user-pool-id "$POOL" --username "$user" --group-name "$group"
sid="$SECRET_PREFIX/users/$user"
if aws secretsmanager describe-secret --region "$REGION" --secret-id "$sid" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "$sid" --secret-string "file://$dir/$user.secret.json" --query Name --output text
else
  aws secretsmanager create-secret --region "$REGION" --name "$sid" --description "RaptGen-UI login ($group)" \
    --tags Key=Component,Value=raptgen-ui-web "Key=UiWebStack,Value=$STACK" \
    --secret-string "file://$dir/$user.secret.json" --query Name --output text
fi
rm -f "$dir/$user.set.json" "$dir/$user.secret.json"
echo "$user -> $group (password in Secrets Manager $sid)"
