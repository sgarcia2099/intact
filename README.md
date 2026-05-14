# Intact Neutral Mass Pipeline (DIA and DDA)

This repository is a bash-first, Docker-based workflow for intact protein MS1 deconvolution and downstream mass annotation.

## Overview

The current implementation supports:

1. Thermo RAW to centroided mzML conversion with ProteoWizard msconvert
2. MS1 deconvolution with OpenMS FLASHDeconv
3. Stable normalization of FLASHDeconv feature output into a tabular neutral-mass table
4. Optional R-based filtering (mass/RT deduplication, intensity threshold, and QScore threshold)
5. Optional post-processing to map top features to candidate proteins from a FASTA-derived mass table

Primary entry point: [pipeline.sh](pipeline.sh)

Because deconvolution is MS1-based, the workflow applies to both DIA and DDA acquisitions.

## Requirements

- Linux
- Docker available to the current user
- Thermo .raw input files (or pre-converted mzML)
- Optional: Rscript on host for the filter stage

## Important Limitation

RAW conversion in Linux containers may still depend on vendor-reader compatibility from ProteoWizard. If Thermo RAW reading fails in your environment, pre-convert to centroided mzML outside this pipeline and start from FLASHDeconv.

## Repository Layout

- [pipeline.sh](pipeline.sh): orchestrates single-file or batch processing
- [config/pipeline.env.example](config/pipeline.env.example): environment defaults
- [config/flashdeconv.ini](config/flashdeconv.ini): baseline FLASHDeconv parameters
- [scripts/convert_raw_to_mzml.sh](scripts/convert_raw_to_mzml.sh): Docker wrapper for msconvert
- [scripts/run_flashdeconv.sh](scripts/run_flashdeconv.sh): Docker wrapper for FLASHDeconv
- [scripts/normalize_flashdeconv_output.sh](scripts/normalize_flashdeconv_output.sh): feature-table normalization
- [scripts/filter_neutral_masses.R](scripts/filter_neutral_masses.R): optional filtering and deduplication
- [scripts/calc_protein_mass.sh](scripts/calc_protein_mass.sh): FASTA to protein-mass table
- [scripts/match_top_features_to_proteins.sh](scripts/match_top_features_to_proteins.sh): top-feature to protein-candidate matching
- [examples/run_example.sh](examples/run_example.sh): example invocations

## Pipeline Flow

Raw or mzML input goes through these stages:

1. Convert RAW to mzML (if RAW input provided)
2. Run FLASHDeconv and collect feature table
3. Normalize output columns into a stable schema
4. Optionally filter normalized table with R

Optional downstream analysis:

5. Compute protein mass table from FASTA
6. Match top deconvolved features to protein candidates with fixed PTM-delta hypotheses

## Quick Start

Copy local config override:

```bash
cp config/pipeline.env.example config/pipeline.env
```

Single sample:

```bash
./pipeline.sh \
  --input /data/run01.raw \
  --output /data/results \
  --sample run01
```

Batch mode:

```bash
./pipeline.sh \
  --input /data/raw \
  --output /data/results \
  --batch
```

Batch with filtering:

```bash
./pipeline.sh \
  --input /data/raw \
  --output /data/results \
  --batch \
  --filter
```

Dry run:

```bash
./pipeline.sh --input /data/run01.raw --output /data/results --sample run01 --dry-run
```

## Outputs

Per sample output directories:

- mzml/<sample>.mzML
- flashdeconv/<sample>_features.tsv
- flashdeconv/<sample>_spec_ms1.tsv (optional intermediate)
- tables/<sample>_neutral_masses.tsv
- tables/<sample>_neutral_masses.filtered.tsv (if --filter)
- logs/<sample>/*.log

Optional downstream output:

- tables/<sample>_protein_matches.tsv

### Normalized Table Schema

The normalized table (`tables/<sample>_neutral_masses.tsv`) currently exports:

- `sample_id`: sample identifier passed to the pipeline (`--sample` or basename fallback).
- `source_file`: source mzML file path used for deconvolution.
- `neutral_mass`: deconvolved monoisotopic neutral mass in Da.
- `intensity`: deconvolved feature abundance (typically summed feature intensity).
- `retention_time_min`: representative retention time in minutes for the feature.
- `charge`: representative/anchor charge state for the feature (usually minimum reported charge).
- `quality_score`: FLASHDeconv deconvolution-quality metric (dimensionless; higher is better).
- `isotope_cosine`: isotope-envelope cosine similarity score (0-1; closer to 1 is better).
- `trace_start_min`: start retention time in minutes for the feature trace.
- `trace_end_min`: end retention time in minutes for the feature trace.
- `flashdeconv_feature_id`: feature identifier from FLASHDeconv (or row-based fallback ID).

The filtered table (`tables/<sample>_neutral_masses.filtered.tsv`) retains the same columns and schema, but with rows removed by quality/intensity/deduplication rules.

Quality mapping details from FLASHDeconv features table:

- quality_score: Qscore2D (fallbacks: QScore, Score, Quality)
- isotope_cosine: IsotopeCosineScore (fallbacks: IsotopeCosine, PerIsotopeCosine)

## Filtering Stage (R)

Script: [scripts/filter_neutral_masses.R](scripts/filter_neutral_masses.R)

Current filtering logic:

1. Remove rows with missing mass/intensity/RT
2. Apply min intensity threshold
3. Optionally apply minimum quality score threshold (--min-qscore)
4. Deduplicate rows in mass and RT windows by keeping highest-intensity representative

Defaults (from [config/pipeline.env.example](config/pipeline.env.example)):

- FILTER_PPM=10
- FILTER_RT_MINUTES=0.5
- FILTER_MIN_INTENSITY=0
- FILTER_MIN_QSCORE=0

Recommended quality threshold guidance:

- FLASHDeconv-style minimum quality acceptance: QScore greater than 0
- More conservative filtering for high-confidence candidates: min-qscore >= 0.5

## Protein Matching Stage

### 1) Build protein masses from FASTA

```bash
./scripts/calc_protein_mass.sh /data/proteins.fasta > /data/results/tables/protein_masses.tsv
```

Output columns:

- `entry_id`: FASTA identifier (header text up to first space).
- `description`: remaining FASTA header text after `entry_id`.
- `length`: count of canonical amino acid residues used in mass calculation.
- `avg_mass_Da`: calculated average intact-protein mass in Da (includes one terminal water).
- `mono_mass_Da`: calculated monoisotopic intact-protein mass in Da (includes one terminal water).
- `nonCanon`: semicolon-delimited non-canonical residues and 1-based positions excluded from mass calculation (empty if none).

### 2) Match top features to candidates

```bash
./scripts/match_top_features_to_proteins.sh \
  --features /data/results/tables/run01_neutral_masses.tsv \
  --protein-masses /data/results/tables/protein_masses.tsv \
  --output /data/results/tables/run01_protein_matches.tsv
```

Current matcher defaults:

- top features: 10
- max candidates per feature: 5
- tolerance: 10 ppm
- PTM deltas (Da): 0,57.0215,42.0106,79.9663

Example stricter run:

```bash
./scripts/match_top_features_to_proteins.sh \
  --features /data/results/tables/run01_neutral_masses.filtered.tsv \
  --protein-masses /data/results/tables/protein_masses.tsv \
  --output /data/results/tables/run01_protein_matches.tsv \
  --ppm 5 \
  --min-intensity 100000
```

`tables/<sample>_protein_matches.tsv` columns:

- `sample_id`: sample identifier carried from the normalized input table.
- `flashdeconv_feature_id`: originating deconvolved feature ID.
- `feature_rank`: rank of feature by intensity among selected top features (1 = highest).
- `feature_neutral_mass_Da`: observed deconvolved neutral mass in Da.
- `feature_intensity`: observed feature intensity from normalized table.
- `feature_retention_time_min`: observed feature retention time in minutes.
- `ptm_delta_Da`: PTM hypothesis delta mass in Da applied during matching.
- `ptm_label`: label for the PTM hypothesis (`unmodified`, `carbamidomethyl`, `acetyl`, `phospho`, or generic delta label).
- `candidate_rank`: rank of candidate protein for that feature (1 = best mass match).
- `entry_id`: matched protein identifier from the protein mass table.
- `description`: matched protein description from FASTA header.
- `length`: matched protein canonical residue length.
- `protein_mono_mass_Da`: matched protein monoisotopic mass in Da (unmodified baseline mass).
- `mass_error_Da`: signed mass error in Da between hypothesis and observed feature mass.
- `mass_error_ppm`: signed mass error in ppm.
- `nonCanon`: copied non-canonical residue annotation from protein mass table.

## Configuration Notes

Key controls in [config/pipeline.env.example](config/pipeline.env.example):

- PWIZ_IMAGE
- PWIZ_DOCKER_SECURITY_OPT
- OPENMS_IMAGE
- FLASHDECONV_INI
- FLASHDECONV_THREADS
- MSCONVERT_PEAK_PICKING
- FILTER_PPM
- FILTER_RT_MINUTES
- FILTER_MIN_INTENSITY
- FILTER_MIN_QSCORE
- KEEP_INTERMEDIATE
- CONTINUE_ON_ERROR

Algorithmic deconvolution constraints remain in [config/flashdeconv.ini](config/flashdeconv.ini), including:

- SD min_cos=0.85
- SD min_snr=1.0
- mass and charge ranges

## Validation

Basic checks:

```bash
bash -n pipeline.sh scripts/convert_raw_to_mzml.sh scripts/run_flashdeconv.sh scripts/normalize_flashdeconv_output.sh scripts/match_top_features_to_proteins.sh
Rscript --vanilla -e 'parse("scripts/filter_neutral_masses.R")'
./pipeline.sh --help
./pipeline.sh --input /data/run01.raw --output /tmp/out --sample run01 --dry-run
```

Container smoke tests:

```bash
docker run --rm --security-opt seccomp=unconfined proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses:latest wine msconvert --help
docker run --rm ghcr.io/openms/openms-executables:latest /opt/OpenMS/bin/FLASHDeconv --help
docker run --rm -v "$PWD/config:/config" ghcr.io/openms/openms-executables:latest /opt/OpenMS/bin/FLASHDeconv -write_ini /config/generated.ini
```

## Citations And Tool Links

### Mass Spectrometry Processing Tools

1. ProteoWizard / msconvert
- Project site: http://proteowizard.sourceforge.net/
- Source (GitHub): https://github.com/ProteoWizard/pwiz
- Citation: Chambers MC, Maclean B, Burke R, et al. A cross-platform toolkit for mass spectrometry and proteomics. Nat Biotechnol. 2012;30(10):918-920. https://doi.org/10.1038/nbt.2377

2. OpenMS
- Project site: https://www.openms.de/
- Source (GitHub): https://github.com/OpenMS/OpenMS
- Citation: Rost HL, Sachsenberg T, Aiche S, et al. OpenMS: a flexible open-source software platform for mass spectrometry data analysis. Nat Methods. 2016;13(9):741-748. https://doi.org/10.1038/nmeth.3959

3. FLASHDeconv (OpenMS TOPP tool)
- OpenMS docs: https://openms.de/documentation/TOPP_FLASHDeconv.html
- Source tree (GitHub): https://github.com/OpenMS/OpenMS
- Citation: Jeong K, Kim M, et al. FLASHDeconv: ultrafast, high-quality feature deconvolution for top-down proteomics. Cell Syst. 2020;10(2):213-218.e6. https://doi.org/10.1016/j.cels.2020.01.003

### Mass Constants and Reference Data Used In calc_protein_mass.sh

4. Unimod residue masses
- Site: https://www.unimod.org/
- Citation: Creasy DM, Cottrell JS. Unimod: protein modifications for mass spectrometry. Proteomics. 2004;4(6):1534-1536. https://doi.org/10.1002/pmic.200300744

5. ExPASy ProtParam average masses
- Site: https://web.expasy.org/protparam/
- Citation: Gasteiger E, Hoogland C, Gattiker A, et al. Protein Identification and Analysis Tools on the ExPASy Server. In: The Proteomics Protocols Handbook. 2005:571-607. https://doi.org/10.1385/1-59259-890-0:571

6. IUPAC standard atomic weights
- Citation: Meija J, Coplen TB, Berglund M, et al. Atomic weights of the elements 2013. Pure Appl Chem. 2016;88(3):265-291. https://doi.org/10.1515/pac-2015-0305

7. NIST monoisotopic atomic masses
- Site: https://www.nist.gov/pml/atomic-weights-and-isotopic-compositions-relative-atomic-masses
