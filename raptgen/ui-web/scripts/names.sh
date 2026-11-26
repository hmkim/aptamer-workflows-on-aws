# Sourced by the ui-web scripts. Names derived from the stack name; keep in sync with lib/names.ts.
#   UI_WEB_STACK  CloudFormation stack of the gate (default RaptGenUiWeb)
# The Region is always us-east-1: Lambda@Edge and its config secret must live there.
UI_WEB_STACK=${UI_WEB_STACK:-RaptGenUiWeb}
[[ $UI_WEB_STACK =~ ^[A-Za-z][A-Za-z0-9-]{0,39}$ ]] || { echo "bad UI_WEB_STACK: $UI_WEB_STACK" >&2; exit 2; }
STACK=$UI_WEB_STACK
REGION=us-east-1
if [[ $STACK == RaptGenUiWeb ]]; then NAME_PREFIX=raptgen-ui-web; else NAME_PREFIX=$(printf '%s' "$STACK" | tr '[:upper:]' '[:lower:]'); fi
SECRET_PREFIX="/$NAME_PREFIX"
