[English](README.md) | [한국어](README.ko.md)

# RaptGen on AWS HealthOmics (next phase)

Placeholder. Nothing here is implemented or validated yet. Documentation placeholder: [RaptGen on HealthOmics](../../docs/raptgen/healthomics.md).

Planned scope:

- RaptGen train / encode as a HealthOmics private workflow, using the images from `../containers`.
- GPU instance types available to HealthOmics runs, and whether the GPU image fits them.
- Parity check against the Batch results in `../results` (same input, same parameters, compare run
  time and loss curves; training is not seeded, so results are compared statistically, not bit for bit).

Keep this folder for the workflow definition, parameter templates and the parity notes.
