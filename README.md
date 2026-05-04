# Intact DIA Neutral Mass Pipeline

This repository provides a bash-first, Docker-based workflow for intact protein DIA data that:

1. Converts Thermo `.raw` files to centroided `.mzML` with ProteoWizard `msconvert`
2. Performs MS1 deconvolution with OpenMS `FLASHDeconv`
3. Normalizes the deconvolution output into a clean tabular list of neutral masses, intensity, and retention time
4. Optionally applies an R-based deduplication and denoising pass

The primary entry point is [pipeline.sh](/home/jkg/github/intact/pipeline.sh).

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

- `sample_id`
- `source_file`
- `neutral_mass`
- `intensity`
- `retention_time_min`
- `charge`
- `quality_score`
- `trace_start_min`
- `trace_end_min`
- `flashdeconv_feature_id`

## Configuration

Defaults are read from [config/pipeline.env.example](/home/jkg/github/intact/config/pipeline.env.example) unless a local `config/pipeline.env` file exists. The most important values are:

- `PWIZ_IMAGE`: ProteoWizard container image
- `PWIZ_DOCKER_SECURITY_OPT`: Docker security option for Wine-based ProteoWizard runs; default is `seccomp=unconfined` because some Docker hosts fail with `wine: socket : Function not implemented` under the default seccomp profile
- `OPENMS_IMAGE`: OpenMS container image
- `FLASHDECONV_INI`: path to the baseline `FLASHDeconv` INI file
- `MSCONVERT_PEAK_PICKING`: `vendor` or `cwt`
- `FLASHDECONV_THREADS`: thread count passed to `FLASHDeconv`
- `MIN_MASS`, `MAX_MASS`, `MIN_CHARGE`, `MAX_CHARGE`: intact-protein defaults for MS1 deconvolution
- `FILTER_*`: optional R filter thresholds

You can also override most settings with environment variables at runtime:

```bash
OPENMS_IMAGE=openms/executables:latest FLASHDECONV_THREADS=8 ./pipeline.sh ...
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
docker run --rm openms/executables:latest FLASHDeconv --help
docker run --rm -v "$PWD/config:/config" openms/executables:latest FLASHDeconv -write_ini /config/generated.ini
```

## Notes on tuning

- The default `FLASHDeconv` mass and charge bounds are conservative starting points for intact proteins and may need adjustment for your instrument and sample complexity.
- For direct infusion or very short traces, switch quantification logic in [config/flashdeconv.ini](/home/jkg/github/intact/config/flashdeconv.ini) from `area` to `median` or `max_height`.
- Keep both raw and filtered tables. The filtered table is a convenience view, not a provenance-preserving replacement.
