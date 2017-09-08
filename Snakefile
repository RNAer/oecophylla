configfile: "config.yaml"

samples = config["samples"]


rule all:
    input:
        fwd = expand("test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz", sample=samples),
        rev = expand("test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz", sample=samples),
        humann2 = "test_out/humann2/genefamilies.biom",
        shogun = "test_out/shogun/joined_taxon_counts.tsv"
    run:
        print('Fooing foo:')


rule qc_atropos:
    """
    Does adapter trimming and read QC with Atropos
    """
    input:
        forward = "test_data/{sample}.R1.fastq.gz",
        reverse = "test_data/{sample}.R2.fastq.gz"
    output:
        forward = "test_out/trimmed/{sample}.trimmed.R1.fastq.gz",
        reverse = "test_out/trimmed/{sample}.trimmed.R2.fastq.gz"
    threads:
        2
    params:
        atropos = config['params']['atropos'],
        env = config['envs']['qc']
    log:
        "test_out/logs/qc_atropos.sample=[{sample}].log"
    shell:
        """
        set +u; {params.env}; set -u

        atropos --threads {threads} {params.atropos} --report-file {log} --report-formats txt -o {output.forward} -p {output.reverse} -pe1 {input.forward} -pe2 {input.reverse}"
        """

rule qc_filter:
    """
    Performs host read filtering on paired end data using Bowtie and Samtools/
    BEDtools. Takes the four output files generated by Trimmomatic. 

    Also requires an indexed reference (path specified in config). 

    First, uses Bowtie output piped through Samtools to only retain read pairs
    that are never mapped (either concordantly or just singly) to the indexed
    reference genome. Fastqs from this are gzipped into matched forward and 
    reverse pairs. 

    Unpaired forward and reverse reads are simply run through Bowtie and
    non-mapping gzipped reads output.

    All piped output first written to localscratch to avoid tying up filesystem.
    """
    input:
        forward = "test_out/trimmed/{sample}.trimmed.R1.fastq.gz",
        reverse = "test_out/trimmed/{sample}.trimmed.R2.fastq.gz"
    output:
        forward = "test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz",
        reverse = "test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz"
    params:
        filter = config['params']['filter'],
        env = config['envs']['qc']
    threads:
        2
    log:
        bowtie = "test_out/logs/qc_filter.bowtie.sample=[{sample}].log",
        other = "test_out/logs/qc_filter.other.sample=[{sample}].log"
    shell:
        """
        set +u; {params.env}; set -u

        bowtie2 -p {threads} {params.filter} -1 {input.forward} -2 {input.reverse} 2> {log.bowtie} | \
        samtools view -f 12 -F 256 2> {log.other} | \
        samtools sort -@ {threads} -n 2> {log.other} | \
        samtools view -bS 2> {log.other} | \
        bedtools bamtofastq -i - -fq {wildcards.sample}.R1.trimmed.filtered.fastq -fq2 {wildcards.sample}.R2.trimmed.filtered.fastq 2> {log.other}

        gzip -c {wildcards.sample}.R1.trimmed.filtered.fastq > {output.forward}
        gzip -c {wildcards.sample}.R2.trimmed.filtered.fastq > {output.reverse}

        rm {wildcards.sample}.R1.trimmed.filtered.fastq
        rm {wildcards.sample}.R2.trimmed.filtered.fastq
        """


rule function_humann2:
    """
    Runs HUMAnN2 pipeline using general defaults.

    Other HUMAnN2 parameters can be specified as a quoted string in 
    PARAMS: HUMANN2: OTHER. 

    Going to do just R1 reads for now. Because of how I've split PE vs SE
    processing and naming, still will need to make a separate rule for PE. 
    """
    input:
        forward = "test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz",
        reverse = "test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz"
    output:
        genefamilies = temp("test_out/humann2/{sample}/{sample}_genefamilies.tsv"),
        pathcoverage = temp("test_out/humann2/{sample}/{sample}_pathcoverage.tsv"),
        pathabundance = temp("test_out/humann2/{sample}/{sample}_pathabundance.tsv")
    params:
        humann2 = config['params']['humann2'],
        metaphlan2 = config['params']['metaphlan2'],
        env = config['envs']['qc']
    threads:
        1
    log:
        "test_out/logs/function_humann2_{sample}.log"
    shell:
        """
        set +u; {params.env}; set -u
        
        mkdir -p test_out/humann2/{wildcards.sample}
        cat {input.forward} {input.reverse} > test_out/humann2/{wildcards.sample}/input.fastq.gz

        humann2 --input test_out/humann2/{wildcards.sample}/input.fastq.gz \
        --output test_out/humann2/{wildcards.sample} \
        --output-basename {wildcards.sample} \
        --o-log {log} \
        --threads {threads} \
        {params.humann2} 2> {log} 1>&2
    
        rm test_out/humann2/{wildcards.sample}/input.fastq.gz
        """


rule function_humann2_combine_tables:
    """
    Combines the per-sample normalized tables into a single run-wide table. 

    Because HUMAnN2 takes a directory as input, first copies all the individual
    tables generated in this run to a temp directory and runs on that.
    """
    input:
        lambda wildcards: expand("test_out/humann2/{sample}/{sample}_genefamilies.tsv",
               sample=samples),
        lambda wildcards: expand("test_out/humann2/{sample}/{sample}_pathcoverage.tsv",
               sample=samples),
        lambda wildcards: expand("test_out/humann2/{sample}/{sample}_pathabundance.tsv",
               sample=samples)
    output:
        genefamilies = "test_out/humann2/genefamilies.biom",
        pathcoverage = "test_out/humann2/pathcoverage.biom",
        pathabundance = "test_out/humann2/pathabundance.biom",
        genefamilies_cpm = "test_out/humann2/genefamilies_cpm.biom",
        pathcoverage_relab = "test_out/humann2/pathcoverage_relab.biom",
        pathabundance_relab = "test_out/humann2/pathabundance_relab.biom",
        genefamilies_cpm_strat = "test_out/humann2/genefamilies_cpm_stratified.biom",
        pathcoverage_relab_strat = "test_out/humann2/pathcoverage_relab_stratified.biom",
        pathabundance_relab_strat = "test_out/humann2/pathabundance_relab_stratified.biom",
        genefamilies_cpm_unstrat = "test_out/humann2/genefamilies_cpm_unstratified.biom",
        pathcoverage_relab_unstrat = "test_out/humann2/pathcoverage_relab_unstratified.biom",
        pathabundance_relab_unstrat = "test_out/humann2/pathabundance_relab_unstratified.biom"
    log:
        "test_out/logs/function_humann2_combine_tables.log"
    params:
        env = config['envs']['qc']
    shell:
        """
        set +u; {params.env}; set -u

        humann2_join_tables --input test_out/humann2/ \
        --search-subdirectories \
        --output test_out/humann2/genefamilies.tsv \
        --file_name genefamilies 2> {log} 1>&2

        humann2_join_tables --input test_out/humann2/ \
        --search-subdirectories \
        --output test_out/humann2/pathcoverage.tsv \
        --file_name pathcoverage 2>> {log} 1>&2

        humann2_join_tables --input test_out/humann2/ \
        --search-subdirectories \
        --output test_out/humann2/pathabundance.tsv \
        --file_name pathabundance 2>> {log} 1>&2


        # normalize
        humann2_renorm_table --input test_out/humann2/genefamilies.tsv \
        --output test_out/humann2/genefamilies_cpm.tsv \
        --units cpm -s n 2>> {log} 1>&2

        humann2_renorm_table --input test_out/humann2/pathcoverage.tsv \
        --output test_out/humann2/pathcoverage_relab.tsv \
        --units relab -s n 2>> {log} 1>&2

        humann2_renorm_table --input test_out/humann2/pathabundance.tsv \
        --output test_out/humann2/pathabundance_relab.tsv \
        --units relab -s n 2>> {log} 1>&2


        # stratify
        humann2_split_stratified_table --input test_out/humann2/genefamilies_cpm.tsv \
        --output test_out/humann2 2>> {log} 1>&2

        humann2_split_stratified_table --input test_out/humann2/pathcoverage_relab.tsv \
        --output test_out/humann2 2>> {log} 1>&2

        humann2_split_stratified_table --input test_out/humann2/pathabundance_relab.tsv \
        --output test_out/humann2 2>> {log} 1>&2

        # convert to biom
        for f in test_out/humann2/*.tsv
        do
        fn=$(basename "$f")
        biom convert -i $f -o test_out/humann2/"${{fn%.*}}".biom --to-hdf5
        done

        # remove tsv
        rm test_out/humann2/*.tsv
        """


rule taxonomy_shogun:
    """
    Runs SHOGUN to infer taxonomic composition of sample.
    """
    input:
        forward = "test_out/filtered/{sample}.trimmed.filtered.R1.fastq.gz",
        reverse = "test_out/filtered/{sample}.trimmed.filtered.R2.fastq.gz"
    output:
        taxon_counts = temp("test_out/shogun/{sample}/{sample}.taxon_counts.tsv")
    params:
        shogun = config['params']['shogun'],
        env = config['envs']['qc']
    threads:
        2
    log:
        "test_out/logs/taxonomy_shogun_{sample}.log"
    shell:
        """
        set +u; {params.env}; set -u

        mkdir -p test_out/shogun/{wildcards.sample}/temp

        # convert and merge fastq's into fasta
        seqtk seq -A {input.forward} > test_out/shogun/{wildcards.sample}/temp/{wildcards.sample}.fna
        seqtk seq -A {input.reverse} >> test_out/shogun/{wildcards.sample}/temp/{wildcards.sample}.fna

        # run shogun with utree
        shogun_utree_lca {params.shogun} --threads {threads} \
        --input test_out/shogun/{wildcards.sample}/temp \
        --output test_out/shogun/{wildcards.sample}/temp \
        2> {log} 1>&2

        # parse output
        echo '#'SampleID$'\t'{wildcards.sample} > {output.taxon_counts}
        cat test_out/shogun/{wildcards.sample}/temp/taxon_counts.csv | \
        tail -n+2 | tr "," "\\t" >> {output.taxon_counts}

        rm -rf test_out/shogun/{wildcards.sample}/temp
        """


rule taxonomy_shogun_combine_tables:
    """
    Combines the per-sample normalized tables into a single run-wide table. 
    """
    input:
        lambda wildcards: expand("test_out/shogun/{sample}/{sample}.taxon_counts.tsv",
               sample=samples)
    output:
        "test_out/shogun/joined_taxon_counts.tsv"
    log:
        "test_out/logs/taxonomy_shogun_combine_tables.log"
    run:
        taxa, samples = {}, []
        for file in input:
            with open(file, 'r') as f:
                sample = f.readline().strip().split('\t')[1]
                samples.append(sample)
                for line in f:
                    taxon, count = line.strip().split('\t')
                    if taxon in taxa:
                        taxa[taxon][sample] = count
                    else:
                        taxa[taxon] = {sample: count}
        with open(output[0], 'w') as f:
            f.write('#SampleID\t%s\n' % '\t'.join(samples))
            for taxon in sorted(taxa):
                row = [taxon]
                for sample in samples:
                    if sample in taxa[taxon]:
                        row.append(taxa[taxon][sample])
                    else:
                        row.append('0.0')
                f.write('%s\n' % '\t'.join(row))
        with open(log[0], 'w') as f:
            f.write('Successfully merged counts of %d taxa from %d samples.\n'
                    % (len(taxa), len(samples)))

