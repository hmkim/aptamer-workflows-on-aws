FROM mambaorg/micromamba:2.3.3@sha256:800e7ade3ffe29c9a9ac2026163131495f8197c3852e572c5835beb4e8a33cd6

COPY --chown=$MAMBA_USER:$MAMBA_USER environment.yml /tmp/environment.yml
RUN micromamba install --yes --name base --file /tmp/environment.yml \
    && micromamba clean --all --yes \
    && rm /tmp/environment.yml

COPY --chown=$MAMBA_USER:$MAMBA_USER --chmod=755 pipeline/ /opt/aptamer/bin/
COPY --chown=$MAMBA_USER:$MAMBA_USER --chmod=755 \
    batch/job_common.sh \
    batch/run_copyin.sh \
    batch/run_stage.sh \
    batch/run_mountpoint.sh \
    batch/mountpoint_compat.sh \
    batch/load_data.sh \
    /opt/aptamer/batch/
COPY --chown=$MAMBA_USER:$MAMBA_USER data/dra009383_manifest.tsv /opt/aptamer/data/dra009383_manifest.tsv
ENV PATH="/opt/conda/bin:/opt/aptamer/bin:${PATH}"

USER root
RUN mkdir -p /work && chown "$MAMBA_USER:$MAMBA_USER" /work
USER $MAMBA_USER
WORKDIR /work

CMD ["bash"]
