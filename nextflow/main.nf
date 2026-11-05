#!/usr/bin/env nextflow
/*
 * Aptamer sequencing workflow.
 *
 * Input modes:
 *   stage  Nextflow stages local or S3 inputs into each task directory.
 *   mount  Tasks read input from a read-only Mountpoint for Amazon S3 path.
 *          The path is carried as a val/string, never as a Nextflow path.
 *
 * Every intermediate and output write stays in the Nextflow task directory.
 * A Mountpoint path is input-only and is never used as the Nextflow work directory.
 */

nextflow.enable.dsl = 2

def helpMessage() {
    return '''
    Aptamer sequencing workflow

    Local:
      nextflow run main.nf -profile local \
        --reads 'inputs/*.fastq.gz' \
        --front_primer <DNA_SEQUENCE> --back_primer <DNA_SEQUENCE> \
        --outdir results

    AWS Batch with native S3 staging:
      nextflow run main.nf -profile batch \
        --samplesheet samplesheet.tsv --input_dir s3://<input-bucket>/<prefix> \
        --work_uri s3://<work-bucket>/<prefix> --outdir s3://<output-bucket>/<prefix> \
        --aws_region <region> --batch_queue <queue> --batch_job_role <role-arn> \
        --container <private-ecr-image> \
        --front_primer <DNA_SEQUENCE> --back_primer <DNA_SEQUENCE>

    AWS Batch with read-only Mountpoint input:
      nextflow run main.nf -profile batch_mountpoint \
        --samplesheet samplesheet.tsv --input_dir /mnt/s3-input/<prefix> \
        --mount_path /mnt/s3-input \
        --work_uri s3://<work-bucket>/<prefix> --outdir s3://<output-bucket>/<prefix> \
        --aws_region <region> --batch_queue <queue> --batch_job_role <role-arn> \
        --container <private-ecr-image> \
        --front_primer <DNA_SEQUENCE> --back_primer <DNA_SEQUENCE>

    Mountpoint caveat:
      Mounted inputs are val/string values. Nextflow -resume cannot detect that an
      object changed at the same mounted path. Use versioned object keys or launch
      without -resume whenever mounted input content may have changed.
    '''.stripIndent()
}

def activeProfiles() {
    return (workflow.profile ?: '').tokenize(',')
}

def shellQuote(value) {
    return "'${value.toString().replace("'", "'\"'\"'")}'"
}

def resolvedContainer() {
    return params.container ?: params.local_container
}

def validateParams() {
    if (!(params.input_mode in ['stage', 'mount'])) {
        error "--input_mode must be stage or mount"
    }
    if (!params.reads && !params.samplesheet) {
        error "Provide --reads or --samplesheet"
    }
    if (!params.reads && !params.input_dir) {
        error "--samplesheet requires --input_dir"
    }
    if (params.input_mode == 'mount') {
        if (params.reads) {
            error "Mount mode requires a samplesheet; --reads is not supported"
        }
        if (!params.input_dir.toString().startsWith('/')) {
            error "Mount mode --input_dir must be an absolute path"
        }
        if (!(params.input_dir.toString() ==~ /[A-Za-z0-9._\/-]+/)) {
            error "Mount mode --input_dir contains unsupported characters"
        }
        if (activeProfiles().contains('healthomics')) {
            error "The healthomics profile uses S3 staging, not Mountpoint"
        }
    }

    def remoteProfiles = activeProfiles().findAll { it in ['batch', 'batch_mountpoint', 'healthomics'] }
    if (remoteProfiles && !params.container) {
        error "Remote profiles require --container with a private ECR image URI"
    }
    if (activeProfiles().any { it.startsWith('batch') }) {
        if (!params.aws_region) {
            error "AWS Batch profiles require --aws_region"
        }
        if (!params.batch_queue) {
            error "AWS Batch profiles require --batch_queue"
        }
        if (!params.batch_job_role) {
            error "AWS Batch profiles require --batch_job_role"
        }
        if (!workflow.workDir.toUriString().startsWith('s3://')) {
            error "AWS Batch profiles require an S3 work directory via --work_uri or -work-dir"
        }
    }
    if (activeProfiles().contains('healthomics')) {
        def image = params.container.toString()
        if (!(image ==~ /[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?\/.+(:[A-Za-z0-9._-]+|@sha256:[a-fA-F0-9]{64})/)) {
            error "HealthOmics requires a tagged or digest-pinned private ECR image URI"
        }
    }

    if (!(params.front_primer ==~ /[ACGTNacgtn]+/)) {
        error "--front_primer must contain only DNA bases A, C, G, T, or N"
    }
    if (!(params.back_primer ==~ /[ACGTNacgtn]+/)) {
        error "--back_primer must contain only DNA bases A, C, G, T, or N"
    }
    if (params.min_length < 1 || params.max_length < params.min_length) {
        error "Require 1 <= --min_length <= --max_length"
    }
    if (params.cutadapt_error_rate < 0 || params.cutadapt_error_rate > 1) {
        error "--cutadapt_error_rate must be between 0 and 1"
    }
    if (params.cutadapt_overlap < 1 || params.top_n < 1 || params.pseudocount_rpm <= 0) {
        error "Overlap, top_n, and pseudocount_rpm must be positive"
    }
}

def roundOf(String name) {
    def match = (name =~ /^R(\d+)_/)
    if (!match.find()) {
        error "Cannot determine a round from '${name}'; expected R<number>_<name>.fastq.gz"
    }
    return match.group(1) as Integer
}

def isAbsoluteRef(String ref) {
    return ref.contains('://') || ref.startsWith('/')
}

def joinRef(String dir, String name) {
    return dir.endsWith('/') ? "${dir}${name}".toString() : "${dir}/${name}".toString()
}

def resolveSamplesheet(String value) {
    def launchCandidate = file(value)
    if (launchCandidate.exists()) {
        return launchCandidate
    }
    def bundledCandidate = file("${projectDir}/${value}")
    if (bundledCandidate.exists()) {
        return bundledCandidate
    }
    error "Samplesheet not found: ${value}"
}

def toolEnv() {
    return params.tool_path ? "export PATH=${shellQuote(params.tool_path)}:\$PATH" : 'true'
}

process QC {
    tag "round-${round}"
    label 'small'

    input:
    tuple val(round), val(mounted_input), path(staged_input)

    output:
    tuple val(round), path("R${round}.stats.tsv")

    script:
    def inputRef = staged_input ? staged_input : mounted_input
    def inputArg = shellQuote(inputRef)
    """
    ${toolEnv()}
    seqkit stats --tabular --basename --threads ${task.cpus} ${inputArg} > R${round}.stats.tsv
    """
}

process QC_MERGE {
    label 'small'
    publishDir "${params.outdir}/qc", mode: params.publish_mode

    input:
    path(stats, stageAs: 'per_round/*')

    output:
    path('stats.tsv')

    script:
    '''
    set -o pipefail
    first=$(find per_round -type f -name '*.stats.tsv' | LC_ALL=C sort -V | head -n 1)
    head -n 1 "$first" > stats.tsv
    tail -q -n +2 per_round/*.stats.tsv | LC_ALL=C sort -k1,1V >> stats.tsv
    '''
}

process TRIM {
    tag "round-${round}"
    label 'medium'
    publishDir "${params.outdir}/trimmed", mode: params.publish_mode, pattern: '*.fastq.gz'
    publishDir "${params.outdir}/logs", mode: params.publish_mode, pattern: '*.cutadapt.log'

    input:
    tuple val(round), val(mounted_input), path(staged_input)

    output:
    tuple val(round), path("R${round}.fastq.gz"), emit: trimmed
    path("R${round}.cutadapt.log"), emit: log

    script:
    def inputRef = staged_input ? staged_input : mounted_input
    def inputArg = shellQuote(inputRef)
    """
    ${toolEnv()}
    cutadapt \\
      --cores ${task.cpus} \\
      --error-rate ${params.cutadapt_error_rate} \\
      --overlap ${params.cutadapt_overlap} \\
      --discard-untrimmed \\
      --minimum-length ${params.min_length} \\
      --maximum-length ${params.max_length} \\
      --adapter '${params.front_primer.toUpperCase()}...${params.back_primer.toUpperCase()}' \\
      --output R${round}.fastq.gz \\
      ${inputArg} > R${round}.cutadapt.log 2>&1
    """
}

process COUNT {
    tag "round-${round}"
    label 'medium'
    publishDir "${params.outdir}/counts", mode: params.publish_mode

    input:
    tuple val(round), path(trimmed)

    output:
    path("R${round}.tsv")

    script:
    """
    ${toolEnv()}
    set -o pipefail
    mkdir -p tmp
    export TMPDIR="\$PWD/tmp"
    seqkit seq --seq-type dna --seq --line-width 0 ${trimmed} \\
      | tr '[:lower:]' '[:upper:]' > tmp/sequences.txt
    LC_ALL=C sort --temporary-directory=tmp --parallel=${task.cpus} tmp/sequences.txt \\
      | uniq -c > tmp/counts.txt
    total=\$(awk '{sum += \$1} END {print sum + 0}' tmp/counts.txt)
    (( total > 0 )) || { echo 'No trimmed reads remain' >&2; exit 1; }
    {
      printf 'sequence\\tcount\\trpm\\n'
      awk -v total="\$total" '{printf "%s\\t%d\\t%.6f\\n", \$2, \$1, (\$1 * 1000000.0 / total)}' tmp/counts.txt \\
        | LC_ALL=C sort -t \$'\\t' -k2,2nr -k1,1
    } > R${round}.tsv
    rm -rf tmp
    """
}

process ENRICH {
    label 'medium'
    publishDir "${params.outdir}/enrich", mode: params.publish_mode

    input:
    path(counts, stageAs: 'counts/*')

    output:
    path('top_candidates.tsv'), emit: top
    path('unique_ratio.tsv'), emit: unique_ratio

    script:
    """
    ${toolEnv()}
    enrich.py \\
      --counts-dir counts \\
      --output-dir enrich_out \\
      --counts-pattern 'R*.tsv' \\
      --round-regex '^R([0-9]+)$' \\
      --top-candidates ${params.top_n} \\
      --pseudocount-rpm ${params.pseudocount_rpm}
    mv enrich_out/top_candidates.tsv top_candidates.tsv
    mv enrich_out/unique_ratio.tsv unique_ratio.tsv
    """
}

process FOLD {
    label 'medium'
    publishDir "${params.outdir}/fold", mode: params.publish_mode

    input:
    path(top)

    output:
    path('top_candidates.fold')

    script:
    '''
    set -o pipefail
    awk -F '\t' 'NR > 1 {print ">rank_" $1 "\n" $2}' top_candidates.tsv \
      | tr 'T' 'U' \
      | RNAfold --noPS > top_candidates.fold
    '''
}

process CHECKSUMS {
    label 'small'
    publishDir "${params.outdir}", mode: params.publish_mode

    input:
    path(qc, stageAs: 'qc/*')
    path(trimmed, stageAs: 'trimmed/*')
    path(counts, stageAs: 'counts/*')
    path(enrich, stageAs: 'enrich/*')
    path(fold, stageAs: 'fold/*')

    output:
    path('checksums.sha256')

    script:
    '''
    set -o pipefail
    find -L qc trimmed counts enrich fold -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum > checksums.sha256
    '''
}

workflow {
    if (params.help) {
        log.info helpMessage()
        exit 0
    }
    validateParams()

    def references
    if (params.reads) {
        references = Channel.fromPath(params.reads, checkIfExists: true)
            .map { inputFile -> tuple(roundOf(inputFile.name), inputFile.toUriString()) }
    } else {
        references = Channel.fromPath(resolveSamplesheet(params.samplesheet.toString()))
            .splitCsv(header: true, sep: '\t', strip: true)
            .map { row ->
                def name = row.file ?: row.filename
                if (row.round == null || !name) {
                    error "Each samplesheet row requires round and file columns"
                }
                def ref = isAbsoluteRef(name.toString()) ? name.toString() : joinRef(params.input_dir.toString(), name.toString())
                tuple(row.round as Integer, ref)
            }
    }

    references.map { round, ref -> round }
        .collect()
        .subscribe { rounds ->
            if (rounds.size() < 2) {
                error "At least two rounds are required"
            }
            if (rounds.size() != rounds.unique(false).size()) {
                error "Duplicate round values are not allowed"
            }
        }

    def workflowInputs = references.map { round, ref ->
        params.input_mode == 'mount'
            ? tuple(round, ref, [])
            : tuple(round, '', file(ref, checkIfExists: true))
    }

    QC(workflowInputs)
    QC_MERGE(QC.out.map { round, stats -> stats }.collect())
    TRIM(workflowInputs)
    COUNT(TRIM.out.trimmed)
    ENRICH(COUNT.out.collect())
    FOLD(ENRICH.out.top)
    CHECKSUMS(
        QC_MERGE.out,
        TRIM.out.trimmed.map { round, fastq -> fastq }.collect(),
        COUNT.out.collect(),
        ENRICH.out.top.mix(ENRICH.out.unique_ratio).collect(),
        FOLD.out
    )
}

workflow.onComplete {
    log.info "Workflow ${workflow.success ? 'completed' : 'failed'}; outputs: ${params.outdir}"
}
