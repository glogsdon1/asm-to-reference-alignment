import os
import sys
import pandas as pd

shell.prefix(f"set -eo pipefail;")

df = pd.read_csv(config.get("tbl"), sep="\t")
df.asm = df.asm.map(os.path.abspath)
df["asm"] = df.asm.str.split(",")
df = df.explode("asm")
df["num"] = df.groupby(level=0).cumcount() + 1
if len(df["num"].unique()) > 1:
    new_index = df["sample"] + "_" + df["num"].astype(str)
else:
    new_index = df["sample"].astype(str)

df.set_index(new_index, inplace=True)


wildcard_constraints:
    i="\\d+",
    sm="|".join(df.index) + "|" + "|".join(df["sample"].str.strip()),


def get_asm(wc):
    return df.loc[str(wc.sm)].asm


def get_ref(wc):
    return ancient(config.get("ref")[wc.ref])


def get_fai(wc):
    return config.get("ref")[wc.ref] + ".fai"


rule alignment_index:
    input:
        ref=get_ref,
    output:
        mmi="temp/{ref}/{ref}.mmi",
    threads: 4
    conda:
        "../envs/env.yml"
    shell:
        "minimap2 -t {threads} -ax asm20 -d {output.mmi} {input.ref}"


# ref=ancient(rules.alignment_index.output.mmi),
rule alignment:
    input:
        ref=get_ref,
        query=get_asm,
    output:
        aln="temp/{ref}/{sm}.bam",
    log:
        "logs/alignment.{ref}_{sm}.log",
    benchmark:
        "logs/alignment.{ref}_{sm}.benchmark.txt"
    conda:
        "../envs/env.yml"
    threads: config.get("aln_threads", 4)
    params:
        mm2_opts=config.get("mm2_opts", "-x asm20 --secondary=no -s 25000 -K 15G"),
    shell:
        """
        {{ minimap2 -t {threads} -a --eqx --cs \
            {params.mm2_opts} \
            {input.ref} {input.query} \
            | samtools view -F 4 -;}} \
            > {output.aln} 2> {log}
        """


rule alignment2:
    input:
        ref_fasta=get_ref,
        query=get_asm,
        aln=rules.alignment.output.aln,
    output:
        aln="temp/{ref}/{sm}.2.bam",
    log:
        "logs/alignment.{ref}_{sm}.2.log",
    benchmark:
        "logs/alignment.{ref}_{sm}.2.benchmark.txt"
    conda:
        "../envs/env.yml"
    threads: config.get("aln_threads", 4)
    params:
        mm2_opts=config.get("mm2_opts", "-x asm20 --secondary=no -s 25000 -K 8G"),
        second_aln=config.get("second_aln", "no"),
    shell:
        """
        if [ {params.second_aln} == "yes" ]; then
          {{ minimap2 -t {threads} -a --eqx --cs \
              {params.mm2_opts} \
              <(seqtk seq \
                  -M <(samtools view -h {input.aln} | paftools.js sam2paf - | cut -f 6,8,9 | bedtools sort -i -) \
                  -n "N" {input.ref_fasta} \
              ) \
              <(seqtk seq \
                  -M <(samtools view -h {input.aln} | paftools.js sam2paf - | cut -f 1,3,4 | bedtools sort -i -) \
                  -n "N" {input.query} \
              ) \
              | samtools view -F 4 -b -;}}\
              > {output.aln} 2> {log}
        else
          samtools view -b -H {input.aln} > {output.aln}
        fi
        """


rule compress_sam:
    input:
        aln=rules.alignment.output.aln,
        aln2=rules.alignment2.output.aln,
    output:
        aln="results/{ref}/bam/{sm}.bam",
    threads: 1  # dont increase this, it will break things randomly 
    conda:
        "../envs/env.yml"
    shell:
        """
        samtools cat {input.aln} {input.aln2} \
                 -o {output.aln}
        """
        # for some reason if I sort some cigars are turned into M instead of =/X
        #| samtools sort -m 8G --write-index \


rule sam_to_paf:
    input:
        aln=rules.compress_sam.output.aln,
    output:
        paf="results/{ref}/paf/{sm}.paf",
    conda:
        "../envs/env.yml"
    shell:
        """
        samtools view -h {input.aln} \
            | paftools.js sam2paf - \
        > {output.paf}
        """


rule trim_and_break_paf:
    input:
        paf=rules.sam_to_paf.output.paf,
    output:
        paf="results/{ref}/paf_trim_and_break/{sm}.paf",
    conda:
        "../envs/env.yml"
    params:
        break_paf=config.get("break_paf", 10_000),
    shell:
        """
        rustybam trim-paf {input.paf} \
            | rustybam break-paf --max-size {params.break_paf} \
        > {output.paf}
        """


rule aln_to_bed:
    input:
        #paf=rules.sam_to_paf.output.paf,
        aln=rules.compress_sam.output.aln,
    output:
        bed="results/{ref}/bed/{sm}.bed",
    conda:
        "../envs/env.yml"
    threads: 1
    shell:
        """
        rb --threads {threads} stats {input.aln} > {output.bed}
        """


rule bed_to_pdf:
    input:
        bed="results/{ref}/bed/{sm}_1.bed",
        bed2="results/{ref}/bed/{sm}_2.bed",
    output:
        pdf="results/{ref}/pdf/ideogram.{sm}.pdf",
    threads: 1
    conda:
        "../envs/R.yml"
    params:
        smkdir=config["smkdir"],
    shell:
        """
        Rscript {params.smkdir}/scripts/ideogram.R \
          --asm {input.bed} \
          --asm2 {input.bed2} \
          --plot {output.pdf}
        """


rule query_ends:
    input:
        paf=rules.sam_to_paf.output.paf,
    output:
        bed=temp("results/{ref}/ends/tmp.{sm}.bed"),
    params:
        smkdir=config["smkdir"],
    conda:
        "../envs/env.yml"
    threads: 1
    shell:
        """
        {params.smkdir}/scripts/ends_from_paf.py \
          --minwidth 10 \
          --width 1 \
          {input.paf} > {output.bed}
        """


rule find_contig_ends:
    input:
        paf=rules.sam_to_paf.output.paf,
        bed=rules.query_ends.output.bed,
    output:
        bed="results/{ref}/ends/{sm}.bed",
    threads: 1
    conda:
        "../envs/env.yml"
    shell:
        """
        rb liftover --largest --qbed \
            --bed <( grep -v "^#" {input.bed} ) \
            {input.paf} \
          | rb stats --paf --qbed \
          > {output.bed}
        """


rule collect_contig_ends:
    input:
        beds=expand(rules.find_contig_ends.output.bed, sm=df.index, ref="{ref}"),
    output:
        bed="results/{ref}/ends/all.ends.bed",
    threads: 1
    conda:
        "../envs/env.yml"
    shell:
        """
        head -n 1 {input.beds[0]} > {output.bed}
        cat {input.beds} \
          | grep -v "^#" \
          | awk '$2 > $3 {{ temp = $3; $3 = $2; $2 = temp }} 1' OFS='\t' \
          | bedtools sort -i - \
          >> {output.bed}
        """


rule windowed_ends:
    input:
        fai=get_fai,
        bed=rules.collect_contig_ends.output.bed,
    output:
        bed="results/{ref}/ends/windowed.all.ends.bed",
    threads: 1
    conda:
        "../envs/env.yml"
    shell:
        """
        bedtools intersect -wa -wb -header \
          -a <(printf "#chr\tstart\tend\n" ; bedtools makewindows -w 1000000 -g {input.fai} ) \
          -b {input.bed} \
          > {output.bed}
        header=$(head -n1 {input.bed})
        sed -i " 1 s/$/\t$header/" {output.bed}
        """


rule pre_end_content:
    input:
        ref=get_ref,
        fai=get_fai,
    output:
        allbed="results/{ref}/ends/all.nuc.content.bed.gz",
    threads: 1
    conda:
        "../envs/env.yml"
    shell:
        """
        bedtools nuc \
          -fi {input.ref} \
          -bed <(bedtools makewindows -s 100 -w 1000 -g {input.fai} ) \
          | pigz \
          > {output.allbed}
        """


rule end_content:
    input:
        bed=rules.collect_contig_ends.output.bed,
        allbed=rules.pre_end_content.output.allbed,
        fai=get_fai,
    output:
        bed="results/{ref}/ends/all.ends.nuc.content.bed.gz",
    threads: 1
    conda:
        "../envs/env.yml"
    shell:
        """
        bedtools intersect -header -u -a {input.allbed} \
          -b <(bedtools slop -b 10000 -g {input.fai} -i {input.bed}) \
          | pigz \
          > {output.bed}
        """


rule reference_alignment:
    input:
        #expand(rules.collect_contig_ends.output, ref=config.get("ref").keys()),
        #expand(rules.end_content.output, ref=config.get("ref").keys()),
        #expand(rules.windowed_ends.output, ref=config.get("ref").keys()),
        #expand(rules.find_contig_ends.output, sm=df.index, ref=config.get("ref").keys()),
        #expand(
        #    rules.bed_to_pdf.output,
        #    sm=df["sample"].str.strip(),
        #    ref=config.get("ref").keys(),
        #),
        expand(rules.aln_to_bed.output, sm=df.index, ref=config.get("ref").keys()),
        expand(rules.sam_to_paf.output, sm=df.index, ref=config.get("ref").keys()),
        expand(
            rules.trim_and_break_paf.output, sm=df.index, ref=config.get("ref").keys()
        ),
    message:
        "Reference alignments complete"
