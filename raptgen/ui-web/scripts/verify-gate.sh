#!/usr/bin/env bash
# Anonymous-denial check for the RaptGen-UI front door. Exit 1 on any failure.
#  - every page and API path (any method) must redirect (302) to THIS pool's Cognito login
#  - the OAuth callback with a forged code/state must be rejected without setting tokens
#  - /logout must redirect to the Cognito logout
#  - a forged token cookie must not get through
set -euo pipefail
STACK=RaptGenUiWeb; REGION=us-east-1
out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
SITE=$(out SiteUrl); COGNITO=$(out CognitoDomain); CID=$(out UserPoolClientId)
fail=0
check() { # method path kind [cookie]
  local m=$1 p=$2 kind=$3 ck=${4:-} hdr code loc tokens
  hdr=$(curl -s -X "$m" ${ck:+-H "Cookie: $ck"} -D - -o /dev/null "$SITE$p")
  code=$(printf '%s' "$hdr" | awk 'NR==1{print $2}')
  loc=$(printf '%s' "$hdr" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
  tokens=$(printf '%s' "$hdr" | grep -ciE '^set-cookie:.*(idToken|accessToken)=[^;]' || true)
  case $kind in
    login)    [[ $code == 302 && $loc == "https://$COGNITO/authorize"* ]] ;;
    rejected) [[ $code =~ ^(400|403|503)$ && $tokens == 0 ]] ;;
    logout)   [[ $code == 302 && $loc == "https://$COGNITO/logout"* ]] ;;
  esac && echo "OK    $m $p -> $code ($kind)" || { echo "FAIL  $m $p -> $code ${loc:-}"; fail=1; }
}
for p in / /viewer /trainer /bayesopt /api/data/VAE-model-names /api/train/device/process "/?code=forged&state=x" /_next/static/x.js; do
  check GET "$p" login; done
for p in /api/train/jobs/submit /api/upload/upload-vae; do check POST "$p" login; done
check DELETE /api/data/items/x login
check GET "/oauth2/idpresponse" rejected
check GET "/oauth2/idpresponse?code=forged&state=eyJ4IjoxfQ" rejected
check GET /logout logout
FORGED="CognitoIdentityServiceProvider.$CID.u.idToken=eyJhbGciOiJub25lIn0.eyJjb2duaXRvOmdyb3VwcyI6WyJyYXB0Z2VuLWZ1bGwiXX0.; CognitoIdentityServiceProvider.$CID.LastAuthUser=u"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $FORGED" "$SITE/api/data/VAE-model-names")
[[ $code =~ ^(302|403)$ ]] && echo "OK    forged token -> $code" || { echo "FAIL  forged token -> $code"; fail=1; }
exit $fail
