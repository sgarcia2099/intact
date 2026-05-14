# Intact Neutral Mass Pipeline (DIA and DDA)

This repository provides a bash-first, Docker-based workflow for intact protein mass spectrometry data (both DIA and DDA) that:

1. Converts Thermo `.raw` files to centroided `.mzML` with ProteoWizard `msconvert`
2. Performs MS1 deconvolution with OpenMS `FLASHDeconv`
3. Normalizes the deconvolution output into a clean tabular list of neutral masses, intensity, and retention time
4. Optionally applies an R-based deduplication and denoising pass

The primary entry point is [pipeline.sh](/home/jkg/github/intact/pipeline.sh).

Because deconvolution is performed at MS1, this pipeline works regardless of whether the acquisition was DIA or DDA.

## Requirements

- Linux with Docker installed and usable by the current user
- Thermo `.raw` input files
- Optional: `Rscript` on the host if you want the downstream filtering step

## Important limitation

The orchestration code in this repository is open-source, but Thermo RAW conversion through ProteoWizard in Linux containers may still depend on vendor reader components. That limitation is not hidden by this workflow. If Thermo RAW reading fails on your host, the fallback is to pre-convert to centroided `.mzML` externally and run the OpenMS and downstream stages from that point.

## Repository layout

- [pipeline.sh](/home/jkg/github/intact/pipeline.sh): single entry point for single-file and batch processing
- [config/pipeline.env.example](/home/jkg/github/intact/config/pipeline.env.example): editable defaults for images and processing parameters
- [config/flashdeconv.ini](/home/jkg/github/intact/config/flashdeconv.ini): baseline OpenMS parameter file for intact-protein deconvolution
- [scripts/convert_raw_to_mzml.sh](/home/jkg/github/intact/scripts/convert_raw_to_mzml.sh): Docker wrapper for ProteoWizard `msconvert`
- [scripts/run_flashdeconv.sh](/home/jkg/github/intact/scripts/run_flashdeconv.sh): Docker wrapper for OpenMS `FLASHDeconv`
- [scripts/normalize_flashdeconv_output.sh](/home/jkg/github/intact/scripts/normalize_flashdeconv_output.sh): stable final table generation
- [scripts/filter_neutral_masses.R](/home/jkg/github/intact/scripts/filter_neutral_masses.R): optional R-based filtering
- [examples/run_example.sh](/home/jkg/github/intact/examples/run_example.sh): example invocation

## Quick start

Copy the example config if you want to override defaults:

```bash
cp config/pipeline.env.example config/pipeline.env
```

Single file:

```bash
./pipeline.sh \
	--input /data/run01.raw \
	--output /data/results \
	--sample run01
```

Batch mode over a directory of `.raw` files:

```bash
./pipeline.sh \
	--input /data/raw \
	--output /data/results \
	--batch
```

Use the optional R filter stage:

```bash
./pipeline.sh \
	--input /data/raw \
	--output /data/results \
	--batch \
	--filter
```

Dry run the exact container commands without executing them:

```bash
./pipeline.sh --input /data/run01.raw --output /data/results --sample run01 --dry-run
```

## Final outputs

For each sample, the pipeline writes:

- `mzml/<sample>.mzML`: centroided mzML from `msconvert`
- `flashdeconv/<sample>_features.tsv`: raw `FLASHDeconv` feature output
- `flashdeconv/<sample>_spec_ms1.tsv`: optional deconvolved MS1 spectrum output
- `tables/<sample>_neutral_masses.tsv`: normalized final table
- `tables/<sample>_neutral_masses.filtered.tsv`: optional R-filtered table
- `logs/<sample>/*.log`: per-stage logs

The normalized table includes stable columns for:

- `sample_id`: sample label used by the pipeline for this row.
- `source_file`: mzML file path that produced the deconvolved feature.
- `neutral_mass`: deconvolved neutral monoisotopic mass (Da).
- `intensity`: feature abundance reported by `FLASHDeconv`.
- `retention_time_min`: representative retention time for the feature (minutes).
- `charge`: representative charge state for the feature.
- `quality_score`: deconvolution quality metric (for example `Score`/`Quality`), or `.` if unavailable.
- `trace_start_min`: start retention time of the traced feature (minutes).
- `trace_end_min`: end retention time of the traced feature (minutes).
- `flashdeconv_feature_id`: feature identifier from `FLASHDeconv` output (or row fallback ID).

## Configuration

Defaults are read from [config/pipeline.env.example](/home/jkg/github/intact/config/pipeline.env.example) unless a local `config/pipeline.env` file exists. The most important values are:

- `PWIZ_IMAGE`: ProteoWizard container image
- `PWIZ_DOCKER_SECURITY_OPT`: Docker security option for Wine-based ProteoWizard runs; default is `seccomp=unconfined` because some Docker hosts fail with `wine: socket : Function not implemented` under the default seccomp profile
- `OPENMS_IMAGE`: OpenMS container image
- `FLASHDECONV_INI`: path to the baseline `FLASHDeconv` INI file
- `MSCONVERT_PEAK_PICKING`: `vendor` or `cwt`
- `FLASHDECONV_THREADS`: thread count passed to `FLASHDeconv`
- `FILTER_*`: optional R filter thresholds
- `KEEP_INTERMEDIATE`: set to `0` to remove `<sample>_spec_ms1.tsv` after normalization
- `CONTINUE_ON_ERROR`: in batch mode, set to `0` to stop at first failed sample

Note: FLASHDeconv algorithm settings (mass range, charge range, tolerance, SNR, trace length, and quant method) are controlled in `config/flashdeconv.ini`.

You can also override most settings with environment variables at runtime:

```bash
OPENMS_IMAGE=ghcr.io/openms/openms-executables:latest FLASHDECONV_THREADS=8 ./pipeline.sh ...
```

## Validation

Shell-level validation available from this repo:

```bash
bash -n pipeline.sh scripts/convert_raw_to_mzml.sh scripts/run_flashdeconv.sh scripts/normalize_flashdeconv_output.sh
./pipeline.sh --help
./pipeline.sh --input /data/run01.raw --output /tmp/out --sample run01 --dry-run
```

Container smoke tests once Docker is available locally:

```bash
docker run --rm --security-opt seccomp=unconfined proteowizard/pwiz-skyline-i-agree-to-the-vendor-licenses:latest wine msconvert --help
docker run --rm ghcr.io/openms/openms-executables:latest /opt/OpenMS/bin/FLASHDeconv --help
docker run --rm -v "$PWD/config:/config" ghcr.io/openms/openms-executables:latest /opt/OpenMS/bin/FLASHDeconv -write_ini /config/generated.ini
```

## Notes on tuning

- The default `FLASHDeconv` mass and charge bounds are conservative starting points for intact proteins and may need adjustment for your instrument and sample complexity.
- For direct infusion or very short traces, switch quantification logic in [config/flashdeconv.ini](/home/jkg/github/intact/config/flashdeconv.ini) from `area` to `median` or `max_height`.
- Keep both raw and filtered tables. The filtered table is a convenience view, not a provenance-preserving replacement.

# calc_protein_mass.sh — Reference Documentation

## Usage

```bash
./calc_protein_mass.sh <protein.fasta>
```

Outputs a tab-separated table to stdout with columns:
`entry_id`, `description`, `length`, `avg_mass_Da`, `mono_mass_Da`, `nonCanon`

Redirect to a file as needed:
```bash
./calc_protein_mass.sh input.faa > output.tsv
```

---

## How Masses Are Calculated

Protein mass is the sum of **residue masses** for each amino acid in the sequence, plus **one water molecule** (lost from the termini is added back):

$$M_{\text{protein}} = \sum_{i=1}^{n} M_{\text{residue},i} + M_{\text{H}_2\text{O}}$$

> **Residue mass** = full amino acid mass − H₂O (18 Da), because one water molecule is released at each peptide bond during condensation. A single water is added back to account for the free N- and C-termini.

---

## Amino Acid Residue Masses

All masses are in **Daltons (Da)**.  
Residue formulas reflect the composition after water loss at the peptide bond.

| Code | Name           | Residue Formula | Monoisotopic (Da) | Average (Da) |
|------|----------------|-----------------|-------------------|--------------|
| A    | Alanine        | C₃H₅NO          | 71.03711          | 71.0788      |
| R    | Arginine       | C₆H₁₂N₄O        | 156.10111         | 156.1875     |
| N    | Asparagine     | C₄H₆N₂O₂        | 114.04293         | 114.1038     |
| D    | Aspartic acid  | C₄H₅NO₃         | 115.02694         | 115.0886     |
| C    | Cysteine       | C₃H₅NOS         | 103.00919         | 103.1388     |
| E    | Glutamic acid  | C₅H₇NO₃         | 129.04259         | 129.1155     |
| Q    | Glutamine      | C₅H₈N₂O₂        | 128.05858         | 128.1307     |
| G    | Glycine        | C₂H₃NO          | 57.02146          | 57.0519      |
| H    | Histidine      | C₆H₇N₃O         | 137.05891         | 137.1411     |
| I    | Isoleucine     | C₆H₁₁NO         | 113.08406         | 113.1594     |
| L    | Leucine        | C₆H₁₁NO         | 113.08406         | 113.1594     |
| K    | Lysine         | C₆H₁₂N₂O        | 128.09496         | 128.1741     |
| M    | Methionine     | C₅H₉NOS         | 131.04049         | 131.1926     |
| F    | Phenylalanine  | C₉H₉NO          | 147.06841         | 147.1766     |
| P    | Proline        | C₅H₇NO          | 97.05276          | 97.1167      |
| S    | Serine         | C₃H₅NO₂         | 87.03203          | 87.0782      |
| T    | Threonine      | C₄H₇NO₂         | 101.04768         | 101.1051     |
| W    | Tryptophan     | C₁₁H₁₀N₂O       | 186.07931         | 186.2132     |
| Y    | Tyrosine       | C₉H₉NO₂         | 163.06333         | 163.1760     |
| V    | Valine         | C₅H₉NO          | 99.06841          | 99.1326      |
| —    | Water (+1×)    | H₂O             | 18.01056          | 18.01528     |

---

## Atomic Composition of Residues

The residue formulas above are composed of four elements:

| Element  | Monoisotopic isotope | Monoisotopic mass (Da) | Standard atomic weight (Da) |
|----------|----------------------|------------------------|-----------------------------|
| Carbon   | ¹²C                  | 12.00000               | 12.0107                     |
| Hydrogen | ¹H                   | 1.0078250              | 1.00794                     |
| Nitrogen | ¹⁴N                  | 14.0030740             | 14.0067                     |
| Oxygen   | ¹⁶O                  | 15.9949146             | 15.9994                     |
| Sulfur   | ³²S                  | 31.9720707             | 32.065                      |

- **Monoisotopic mass**: calculated using the mass of the most abundant (lightest) isotope of each element.
- **Average mass**: calculated using the standard atomic weight of each element (weighted average over all naturally occurring isotopes).

---

## Non-Canonical Amino Acids

Residues not in the 20 canonical amino acids (e.g. `B`, `Z`, `X`, `U`, `O`, `J`) are:
- **Excluded** from mass calculation and sequence length count
- **Recorded** in the `nonCanon` output column as `<residue><1-based position>` pairs, e.g. `U56; B89`
- **Reported** as a warning to stderr

---

## Citations

1. **Monoisotopic residue masses** — Unimod: The Unimod database for protein modifications.  
   https://www.unimod.org  
   Creasy DM, Cottrell JS. "Unimod: Protein modifications for mass spectrometry." *Proteomics* 4(6):1534–6 (2004). https://doi.org/10.1002/pmic.200300744

2. **Average residue masses** — ExPASy ProtParam tool.  
   https://web.expasy.org/protparam/  
   Gasteiger E, Hoogland C, Gattiker A, Duvaud S, Wilkins MR, Appel RD, Bairoch A. "Protein Identification and Analysis Tools on the ExPASy Server." In: Walker JM (ed.), *The Proteomics Protocols Handbook*, Humana Press, pp. 571–607 (2005). https://doi.org/10.1385/1-59259-890-0:571

3. **Standard atomic weights** — IUPAC Commission on Isotopic Abundances and Atomic Weights.  
   Meija J, Coplen TB, Berglund M, et al. "Atomic weights of the elements 2013." *Pure Appl. Chem.* 88(3):265–291 (2016). https://doi.org/10.1515/pac-2015-0305

4. **Monoisotopic atomic masses** — NIST Atomic Weights and Isotopic Compositions.  
   https://www.nist.gov/pml/atomic-weights-and-isotopic-compositions-relative-atomic-masses
