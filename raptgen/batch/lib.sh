# Shared helpers for the raptgen/batch scripts (source this file).
# Reads outputs of the <prefix>-batch stack (see raptgen/README.md).

stack_output() { # stack key -> value, empty when the output does not exist
  local v
  v="$(aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null)" || return 1
  [[ "${v}" == None ]] && v=""
  printf '%s' "${v}"
}

queue_for_device() { # prefix cpu|gpu -> queue name, or exit with a clear message
  local key=CpuJobQueueName q
  [[ "$2" == gpu ]] && key=GpuJobQueueName
  q="$(stack_output "$1-batch" "${key}")" || { echo "cannot read stack $1-batch (wrong --stack-prefix, Region or credentials?)" >&2; exit 1; }
  if [[ -z "${q}" ]]; then
    echo "The $2 queue is disabled in stack $1-batch (no ${key} output)." >&2
    echo "Enable it (Enable${2^^}=true) and redeploy the batch stack, or use the other device." >&2
    exit 1
  fi
  printf '%s' "${q}"
}
