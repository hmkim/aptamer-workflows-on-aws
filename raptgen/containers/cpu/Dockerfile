# syntax=docker/dockerfile:1.7
#
# aptamer-raptgen (CPU) -- RaptGen (hmdlab/raptgen) on Python 3.12 + PyTorch CPU.
#
# Source rebuild of the pinned upstream commit:
#   Python 3.12.16 (Debian trixie slim, digest-pinned)
#   PyTorch 2.14.1+cpu (PyTorch CPU index, sha256-pinned wheel)
#   every other Python dependency from requirements.lock / requirements-s3.lock
#     (--require-hashes); boto3 is used only by raptgen-job for S3 I/O
#   two auditable source patches under patches/ (np.int -> int, float64
#   probability normalization; Bayesian optimization excluded)
# Scope: train (scripts/real.py), encode, decode. scripts/bo.py (GPyOpt) is
# excluded. Ships upstream data/sample and data/real/A_4R.fastq (paper dataset A).
# Entry points: /usr/local/bin/{raptgen-job,raptgen-bench,smoke-test,tool-version}.
#
# Build:  raptgen/containers/build.sh cpu     (or: docker build -t raptgen-cpu raptgen/containers/cpu)
# Smoke (no network, read-only rootfs, non-root):
#   docker run --rm --network none --read-only --tmpfs /tmp --tmpfs /smoke-out \
#     -e SMOKE_OUT=/smoke-out --user 10001:10001 <image> /usr/local/bin/smoke-test
ARG PYTHON_IMAGE=python:3.12.16-slim-trixie@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

# ---------------------------------------------------------------- source ---
FROM ${PYTHON_IMAGE} AS source
ARG RAPTGEN_REPO=https://github.com/hmdlab/raptgen.git
# Pinned upstream commit (default branch HEAD, 2022-12-17).
ARG RAPTGEN_COMMIT=c4986ca9fa439b9389916c05829da4ff9c30d6f3
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
COPY source-checksums.sha256 patched-checksums.sha256 /src/
COPY patches/0001-numpy-int-and-bo-exclusion.patch patches/0002-numpy-probability-normalization.patch /src/patches/
# Fetch the exact commit, verify upstream inputs, apply the patch with
# `git apply --check` first (fails on any drift), then verify patched files.
RUN git init -q /src/raptgen \
 && git -C /src/raptgen remote add origin "${RAPTGEN_REPO}" \
 && git -C /src/raptgen fetch -q --depth 1 origin "${RAPTGEN_COMMIT}" \
 && git -C /src/raptgen checkout -q --detach FETCH_HEAD \
 && test "$(git -C /src/raptgen rev-parse HEAD)" = "${RAPTGEN_COMMIT}" \
 && git -C /src/raptgen rev-parse HEAD > /src/raptgen/.source-commit \
 && cd /src/raptgen \
 && sha256sum -c /src/source-checksums.sha256 \
 && echo "5008fb291f4394b4c7a7cf3dbf92837102967b517e1f7f8764fc14a740f06e94  data/real/A_4R.fastq" | sha256sum -c - \
 && for p in /src/patches/*.patch; do git apply --unidiff-zero --check "${p}" && git apply --unidiff-zero "${p}"; done \
 && grep -v '^#' /src/patched-checksums.sha256 | sha256sum -c - \
 && ! grep -rnE 'np\.int\b' raptgen scripts/encode.py scripts/decode.py scripts/real.py \
 && rm -rf /src/raptgen/.git

# ----------------------------------------------------------------- build ---
FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.lock requirements-s3.lock /tmp/
# torch: PyTorch CPU index, exact local version, sha256 checked.
# Everything else: PyPI binary wheels only, every file hash-checked.
ARG TORCH_WHEEL=torch-2.14.1+cpu-cp312-cp312-manylinux_2_28_x86_64.whl
ARG TORCH_WHEEL_SHA256=5a6363570c753812540a05eb82380e329469cbe668643e88111414c12627711f
RUN python -m pip download --no-deps --only-binary=:all: --dest /wheels \
      --index-url https://download.pytorch.org/whl/cpu "torch==2.14.1+cpu" \
 && echo "${TORCH_WHEEL_SHA256}  /wheels/${TORCH_WHEEL}" | sha256sum -c - \
 && python -m pip download --no-deps --only-binary=:all: --require-hashes \
      --dest /wheels -r /tmp/requirements.lock \
 && python -m pip download --no-deps --only-binary=:all: --require-hashes \
      --dest /wheels -r /tmp/requirements-s3.lock
COPY --from=source /src/raptgen /src/raptgen
# raptgen has only setup.py; build it offline with the locked setuptools.
RUN python -m venv /tmp/buildenv \
 && /tmp/buildenv/bin/pip install --no-index --no-deps --find-links /wheels "setuptools==84.2.1" \
 && /tmp/buildenv/bin/pip wheel --no-index --no-deps --no-build-isolation \
      --wheel-dir /wheels /src/raptgen \
 && test -f /wheels/raptgen-0.1.0-py3-none-any.whl

# --------------------------------------------------------------- runtime ---
FROM ${PYTHON_IMAGE} AS runtime
ARG RAPTGEN_COMMIT=c4986ca9fa439b9389916c05829da4ff9c30d6f3
ARG PROJECT_REVISION=unknown
LABEL org.opencontainers.image.title="aptamer-raptgen" \
      org.opencontainers.image.description="RaptGen 0.1.0 modern CPU candidate (Python 3.12, PyTorch 2.14.1+cpu, np.int patch, Bayesian optimization excluded), sequence-level SELEX VAE" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.source="https://github.com/hmdlab/raptgen" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${PROJECT_REVISION}" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12.16-slim-trixie" \
      org.opencontainers.image.base.digest="sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b" \
      aptamer.toolchain.tool="raptgen" \
            aptamer.toolchain.molecule-scope="DNA,RNA" \
      aptamer.toolchain.dna-allowed="true" \
      aptamer.toolchain.gpu="false" \
      aptamer.toolchain.source-commit="${RAPTGEN_COMMIT}" \
      aptamer.toolchain.model-policy="upstream-sample-only" \
      aptamer.toolchain.variant="modern-cpu" \
      aptamer.toolchain.python="3.12.16" \
      aptamer.toolchain.torch="2.14.1+cpu" \
      aptamer.toolchain.source-patches="0001-numpy-int-and-bo-exclusion,0002-numpy-probability-normalization" \
      aptamer.toolchain.excluded-features="bayesian-optimization,gpyopt,gpy,torchvision,cuda" \
      aptamer.toolchain.dependency-lock="/usr/share/doc/aptamer-raptgen/requirements.lock"
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    LC_ALL=C.UTF-8 LANG=C.UTF-8 \
    HOME=/tmp/home MPLBACKEND=Agg MPLCONFIGDIR=/tmp/mpl TORCH_HOME=/tmp/torch \
    RAPTGEN_HOME=/opt/raptgen
# libcairo2: CairoSVG runtime dependency for upstream visualization helpers
# (upstream Dockerfile installs it too). Not used by the smoke path.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libcairo2 \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.lock requirements-s3.lock /usr/share/doc/aptamer-raptgen/
RUN --mount=type=bind,from=build,source=/wheels,target=/wheels \
    python -m pip install --no-index --no-deps /wheels/torch-2.14.1+cpu-cp312-cp312-manylinux_2_28_x86_64.whl \
 && python -m pip install --no-index --no-deps --require-hashes --find-links /wheels \
      -r /usr/share/doc/aptamer-raptgen/requirements.lock \
 && python -m pip install --no-index --no-deps --require-hashes --find-links /wheels \
      -r /usr/share/doc/aptamer-raptgen/requirements-s3.lock \
 && python -m pip install --no-index --no-deps /wheels/raptgen-0.1.0-py3-none-any.whl \
 && python -m pip freeze --all > /usr/share/doc/aptamer-raptgen/pip-freeze.txt \
 && python -m pip check \
 && python -c "import importlib.util as u, sys; sys.exit(any(u.find_spec(m) for m in ('GPy', 'GPyOpt', 'torchvision')))"
# Only the train/encode/decode scripts ship (no scripts/bo.py). Sample data stays read-only.
COPY --from=source /src/raptgen/scripts/encode.py /src/raptgen/scripts/decode.py /src/raptgen/scripts/real.py /opt/raptgen/scripts/
COPY --from=source /src/raptgen/data/sample /opt/raptgen/data/sample
COPY --from=source /src/raptgen/data/real/A_4R.fastq /opt/raptgen/data/real/A_4R.fastq
COPY --from=source /src/raptgen/.source-commit /opt/raptgen/.source-commit
COPY --from=source /src/raptgen/LICENSE /usr/share/licenses/raptgen/LICENSE
COPY NOTICE /usr/share/licenses/raptgen/NOTICE
COPY patches/0001-numpy-int-and-bo-exclusion.patch patches/0002-numpy-probability-normalization.patch /usr/share/doc/aptamer-raptgen/patches/
COPY raptgen_contract.py /usr/local/lib/aptamer/raptgen_contract.py
COPY smoke-test.sh /usr/local/bin/smoke-test
COPY tool-version.sh /usr/local/bin/tool-version
COPY bench.sh /usr/local/bin/raptgen-bench
COPY raptgen_job.py /usr/local/bin/raptgen-job
RUN chmod 0555 /usr/local/bin/smoke-test /usr/local/bin/tool-version /usr/local/bin/raptgen-bench /usr/local/bin/raptgen-job \
 && chmod 0444 /usr/local/lib/aptamer/raptgen_contract.py \
 && chmod -R a-w /opt/raptgen /usr/share/doc/aptamer-raptgen \
 && groupadd --gid 10001 aptamer \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin aptamer
USER 10001:10001
WORKDIR /tmp
# No EXPOSE, no server, no ENTRYPOINT daemon: batch CLI only.
CMD ["/usr/local/bin/tool-version"]
