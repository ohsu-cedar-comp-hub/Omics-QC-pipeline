rule trimming:
    input:
        fwd = "samples/raw/{sample}_R1.fq",
        rev = "samples/raw/{sample}_R2.fq"
    output:
        fwd_P = "samples/trimmed/{sample}_R1_P_t.fq",
        fwd_UP = "samples/trimmed/{sample}_R1_UP_t.fq",
        rev_P = "samples/trimmed/{sample}_R2_P_t.fq",
        rev_UP = "samples/trimmed/{sample}_R2_UP_t.fq"
    params:
        adapter=config["adapter-PE"]
    log:
        "logs/trimming/{sample}_trimming.log"
    conda:
        "../envs/trim.yaml"
    message:
        """--- Trimming."""
    shell:
        """trimmomatic PE -trimlog {log} {input.fwd} {input.rev} {output.fwd_P} {output.fwd_UP} {output.rev_P} {output.rev_UP} ILLUMINACLIP:{params.adapter}:2:30:10 LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36"""

rule fastqc:
    input:
        fwd = "samples/trimmed/{sample}_R1_P_t.fq",
        rev = "samples/trimmed/{sample}_R2_P_t.fq"
    output:
        fwd = "samples/fastqc/{sample}/{sample}_R1_P_t_fastqc.zip",
        rev = "samples/fastqc/{sample}/{sample}_R2_P_t_fastqc.zip"
    log:
        "logs/fastqc/{sample}_fastqc.log"
    conda:
        "../envs/fastqc.yaml"
    message:
        """--- Quality check of raw data with Fastqc."""
    shell:
        """fastqc --outdir samples/fastqc/{wildcards.sample} --extract  -f fastq {input.fwd} {input.rev}"""

rule fastqscreen:
    input:
        fwd = "samples/trimmed/{sample}_R1_P_t.fq",
        rev = "samples/trimmed/{sample}_R2_P_t.fq"
    output:
        "samples/fastqscreen/{sample}/{sample}_R1_P_t_screen.html",
        "samples/fastqscreen/{sample}/{sample}_R1_P_t_screen.png",
        "samples/fastqscreen/{sample}/{sample}_R1_P_t_screen.txt",
        "samples/fastqscreen/{sample}/{sample}_R2_P_t_screen.html",
        "samples/fastqscreen/{sample}/{sample}_R2_P_t_screen.png",
        "samples/fastqscreen/{sample}/{sample}_R2_P_t_screen.txt"
    params:
        conf = config["conf"]
    conda:
        "../envs/fastqscreen.yaml"
    shell:
        """fastq_screen --aligner bowtie2 --conf {params.conf} --outdir samples/fastqscreen/{wildcards.sample} {input.fwd} {input.rev}"""

rule STAR:
    input:
        fwd = "samples/trimmed/{sample}_R1_P_t.fq",
        rev = "samples/trimmed/{sample}_R2_P_t.fq"
    output:
        "samples/star/{sample}_bam/Aligned.sortedByCoord.out.bam",
        "samples/star/{sample}_bam/ReadsPerGene.out.tab",
        "samples/star/{sample}_bam/Log.final.out"
    threads: 12
    params:
        gtf=config["gtf_file"]
    log:
        "logs/star/{sample}_star.log"
    run:
         STAR=config["star_tool"],
         pathToGenomeIndex = config["star_index"]

         shell("""
                {STAR} --runThreadN {threads} --runMode alignReads --genomeDir {pathToGenomeIndex} \
                --readFilesIn {input.fwd} {input.rev} \
                --outFileNamePrefix samples/star/{wildcards.sample}_bam/ \
                --sjdbGTFfile {params.gtf} --quantMode GeneCounts \
                --sjdbGTFtagExonParentGene gene_name \
                --outSAMtype BAM SortedByCoordinate \
                #--readFilesCommand zcat \
                --twopassMode Basic
                """)

rule star_statistics:
    input:
        expand("samples/star/{sample}_bam/Log.final.out",sample=SAMPLES)
    output:
        "results/tables/{project_id}_STAR_mapping_statistics.txt".format(project_id = config["project_id"])
    script:
        "../scripts/compile_star_log.py"

rule picard:
  input:
      "samples/star/{sample}_bam/Aligned.sortedByCoord.out.bam"
  output:
      temp("samples/genecounts_rmdp/{sample}_bam/{sample}.rmd.bam")
  params:
      name="rmd_{sample}",
      mem="5300"
  threads: 1
  run:
    picard=config["picard_tool"]

    shell("java -Xmx3g -jar {picard} \
    INPUT={input} \
    OUTPUT={output} \
    METRICS_FILE=samples/genecounts_rmdp/{wildcards.sample}_bam/{wildcards.sample}.rmd.metrics.text \
    REMOVE_DUPLICATES=true")


rule sort:
  input:
    "samples/genecounts_rmdp/{sample}_bam/{sample}.rmd.bam"
  output:
    "samples/genecounts_rmdp/{sample}_bam/{sample}_sort.rmd.bam"
  params:
    name = "sort_{sample}",
    mem = "6400"
  conda:
    "../envs/omic_qc_wf.yaml"
  shell:
    """samtools sort -O bam -n {input} -o {output}"""


rule samtools_stats:
    input:
        "samples/genecounts_rmdp/{sample}_bam/{sample}_sort.rmd.bam"
    output:
        "samples/samtools_stats/{sample}.txt"
    log:
        "logs/samtools_stats/{sample}_samtools_stats.log"
    conda:
        "../envs/omic_qc_wf.yaml"
    wrapper:
        "0.17.0/bio/samtools/stats"


rule genecount:
    input:
        "samples/genecounts_rmdp/{sample}_bam/{sample}_sort.rmd.bam"
    output:
        "samples/htseq_count/{sample}_htseq_gene_count.txt",
    log:
        "logs/genecount/{sample}_genecount.log"
    params:
        name = "genecount_{sample}",
        gtf = config["gtf_file"]
    conda:
        "../envs/omic_qc_wf.yaml"
    threads: 1
    shell:
        """
          htseq-count \
                -f bam \
                -r name \
                -s reverse \
                -m union \
                {input} \
                {params.gtf} > {output}"""


rule count_exons:
    input:
        "samples/genecounts_rmdp/{sample}_bam/{sample}_sort.rmd.bam"
    output:
        "samples/htseq_exon_count/{sample}_htseq_exon_count.txt"
    params:
        exon_gtf = config["exon_gtf"]
    conda:
        "../envs/omic_qc_wf.yaml"
    shell:
        """htseq-count \
                -f bam \
                -m intersection-nonempty \
                -i exon_id \
                --additional-attr=gene_name \
                {input} \
                {params.exon_gtf} > {output}"""


rule compile_counts:
    input:
        expand("samples/htseq_count/{sample}_htseq_gene_count.txt",sample=SAMPLES)
    output:
        "data/{project_id}_counts.txt".format(project_id=config["project_id"])
    script:
        "../scripts/compile_counts_table.py"


rule compile_counts_and_stats:
    input:
        expand("samples/htseq_count/{sample}_htseq_gene_count.txt",sample=SAMPLES)
    output:
        "data/{project_id}_counts_w_stats.txt".format(project_id=config["project_id"])
    script:
        "../scripts/compile_counts_table_w_stats.py"


rule compile_exon_counts:
    input:
        expand("samples/htseq_exon_count/{sample}_htseq_exon_count.txt", sample=SAMPLES)
    output:
        "data/{project_id}_exon_counts.txt".format(project_id = config["project_id"])
    conda:
        "../envs/junction_counts.yaml"
    script:
        "../scripts/compile_exon_counts.R"

