#!/usr/bin/env bash
# Print the aptamer-raptgen (modern CPU) tool versions as one JSON object.
# No network. Bayesian optimization (GPyOpt/GPy) is reported as excluded.
set -euo pipefail
exec python - <<'PY'
import importlib.metadata as md, importlib.util, json, os, platform
import numpy, pandas, sklearn, scipy, torch
with open("/opt/raptgen/.source-commit") as fh:
    commit = fh.read().strip()
print(json.dumps({
    "tool": "raptgen",
    "tool_version": md.version("raptgen"),
    "image_variant": os.environ.get("RAPTGEN_VARIANT", "modern-cpu"),
    "source_repository": "https://github.com/hmdlab/raptgen",
    "source_commit": commit,
    "source_patches": ["0001-numpy-int-and-bo-exclusion"],
    "python": platform.python_version(),
    "torch": torch.__version__,
    "torch_cuda_build": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "numpy": numpy.__version__,
    "pandas": pandas.__version__,
    "scipy": scipy.__version__,
    "scikit_learn": sklearn.__version__,
    "bayesian_optimization": "excluded",
    "gpyopt_installed": importlib.util.find_spec("GPyOpt") is not None,
    "gpy_installed": importlib.util.find_spec("GPy") is not None,
}, sort_keys=True))
PY
