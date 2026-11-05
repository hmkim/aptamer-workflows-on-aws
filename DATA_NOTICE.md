# Data notice

This repository does not contain sequencing reads or derived research results.

The optional example manifest in `data/dra009383_manifest.tsv` refers to [DRA009383](https://ddbj.nig.ac.jp/resource/sra-submission/DRA009383) in the DDBJ Sequence Read Archive, a public repository for sequencing data. The accession contains nine sequencing runs from rounds 0 through 8 of an RNA SELEX experiment. SELEX is a laboratory process that repeatedly selects nucleic-acid sequences that bind to a target.

The manifest contains only public accession metadata, download URLs, output file names, and published MD5 checksums. `data/fetch_dra009383.sh` downloads the reads directly from the public archive and verifies each file against its checksum. Downloaded files are stored under `inputs/` by default and are excluded from the container build context. The optional `data/dra009383.env.example` records the primer sequences used by the linked study so that the public example is reproducible; those values must not be assumed to fit another library.

The associated method is described in the [RaptGen publication](https://pmc.ncbi.nlm.nih.gov/articles/PMC10766510/).

Users are responsible for reviewing the archive record, linked publication, and applicable data-use terms before downloading or redistributing the data. Cite the original study and accession when publishing analyses based on DRA009383.
