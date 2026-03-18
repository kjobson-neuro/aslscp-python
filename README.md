# ASL Self-Contained Processing Docker Container (ASLscp)

This GitHub repository contains a Docker container for processing Arterial Spin Labeling (ASL) MRI data without requiring a structural scan. The processing pipeline was developed at Penn Medicine by Manuel Taso. The Docker container and Flywheel gear were developed by Katie Jobson.

## Overview

This pipeline processes **Siemens 3D pCASL data** and computes cerebral blood flow (CBF) maps. Two input files are required: the ASL timeseries data and the M0 calibration image.

### Processing Steps

1. **DICOM to NIfTI conversion** using dcm2niix
2. **Motion correction** using FSL's mcflirt
3. **Skull stripping** using FreeSurfer's mri_synthstrip
4. **ASL subtraction** (label-control pairs)
5. **CBF quantification** using the standard kinetic model as reported in the White Paper (Alsop 2015)
6. **T1 quantification** (if data supports it - Penn Medicine sequences ONLY)
7. **Registration to template space** using ANTs
8. **ROI-based analysis** with multiple brain atlases for Alzheimer's specific regions of interest
9. **PDF report generation** with QC images and regional CBF values

### CBF Quantification Model

CBF is calculated using the standard kinetic model for pCASL as described in the ASL White Paper (Alsop et al., 2015):

$$
CBF = \frac{6000 \cdot \lambda \cdot \Delta M \cdot e^{PLD/T_{1b}}}{2 \cdot \alpha \cdot \alpha_{BS} \cdot T_{1b} \cdot M_0 \cdot (1 - e^{-LD/T_{1b}})}
$$

Where:
- **ΔM** = ASL difference signal (control - label)
- **M0** = equilibrium magnetization (with scaling factor applied)
- **LD** = labeling duration (seconds)
- **PLD** = post-labeling delay (seconds)

Fixed parameters:
| Parameter | Value | Description |
|-----------|-------|-------------|
| α | 0.8 | Labeling efficiency for pCASL |
| α_BS | 0.95^nbs | Background suppression efficiency (nbs = number of background suppressions) |
| λ | 0.9 mL/g | Blood–brain partition coefficient |
| T1b | 1.6 s | T1 of arterial blood at 3T |

CBF is output in units of mL/100g/min.

**Reference:** Alsop DC, et al. Recommended implementation of arterial spin-labeled perfusion MRI for clinical applications. *Magn Reson Med.* 2015;73(1):102-116.

## Inputs

| Input | Description | Required |
|-------|-------------|----------|
| `asl` | ASL timeseries data (DICOM zip or NIfTI file) | Yes |
| `m0` | M0 calibration image (DICOM zip or NIfTI file) | Yes |
| `t1w` | T1w image (DICOM zip or NIfTI file) | No |

## Configuration Parameters

These parameters can be provided via Flywheel config, command line flags, or will be automatically extracted from DICOM headers:

| Parameter | Description | Flag | Notes |
|-----------|-------------|------|-------|
| `ld` | Labeling duration (microseconds) | `-l` | Extracted from DICOM header |
| `pld` | Post-labeling delay (microseconds) | `-p` | Extracted from DICOM header |
| `nbs` | Number of background suppressions | `-n` | Extracted from DICOM header. Set to 1 if none. |
| `m0_scale` | M0 scaling factor | `no flag` | Extracted from DICOM header |
| `skip_extended` | Skip registration, atlas extraction, and PDF generation | `-e` | Default: false. When true, only outputs CBF map. |
| `run_t1w_reg` | Register CBF map to provided T1w image. | `-r` | Default: false When true, registration of CBF map to T1w will be run. |

If your sequence has not come from a modern Penn Medicine ASL sequence, you will need to provide the labeling delay, post-labeling delay and number of background suppressions via command line flags or Flywheel config. The `m0_scale` variable should not change, as all Siemens data is on a scale of 10. If your data does not include background suppression, please set nbs = 1.

For NIfTI input, parameters must always be provided manually since there are no DICOM headers to extract from.

## Outputs

| Output | Description |
|--------|-------------|
| `{subject_id}_cbf.nii.gz` | Quantitative CBF map |
| `{subject_id}_output.pdf` | PDF report with QC images and regional CBF tables |
| `{subject_id}_qc.pdf` | Quality control PDF |
| `{subject_id}_t1.nii.gz` | T1 relaxation map (if applicable) |
| `{subject_id}_tSNR_map.nii.gz` | Temporal SNR map |
| `stats/` | Directory containing regional CBF text files |
| `viz/` | Directory containing visualization images |
| `{subject_id}_final_output.zip` | Zipped output directory |
| `{subject_id}_work_dir.zip` | Zipped working directory with intermediate files |

If there is no subject ID supplied, or no subject ID present when you run this container as a Flywheel gear, the outputs will not include subject ID.

## Examples of Running the Docker Container

### Basic Usage

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/aslscp:latest \
           -a /flywheel/v0/input/asl_dicom.zip \
           -m /flywheel/v0/input/m0_dicom.zip
```

### With Manual Parameters

If your DICOM files do not contain the acquisition parameters in the headers, provide them manually:

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/aslscp:latest \
           -a /flywheel/v0/input/asl_dicom.zip \
           -m /flywheel/v0/input/m0_dicom.zip \
           -l 3000000 \
           -p 2025000 \
           -n 4
```

### With NIfTI Input

For NIfTI input, provide both ASL and M0 files along with acquisition parameters:

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/aslscp:latest \
           -a /flywheel/v0/input/asl.nii.gz \
           -m /flywheel/v0/input/m0.nii.gz \
           -l 3000000 \
           -p 2025000 \
           -n 4
```

### CBF Only (Skip Extended Analysis)

To output only the CBF map without registration, atlas extraction, or PDF generation:

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/aslscp:latest \
           -a /flywheel/v0/input/asl_dicom.zip \
           -m /flywheel/v0/input/m0_dicom.zip \
           -e
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `-a` | Path to ASL DICOM zip or NIfTI file |
| `-m` | Path to M0 DICOM zip or NIfTI file |
| `-t` | Path to T1w xip or NIfTI file. |
| `-l` | Labeling duration (microseconds) |
| `-p` | Post-labeling delay (microseconds) |
| `-n` | Number of background suppressions |
| `-e` | Skip extended analysis (registration, atlas extraction, PDF) |
| `-r` | Register CBF map to provided T1w image |
| `-s` | Subject ID |

The config JSON file directly relates to Flywheel - it is not necessary for almost anything if this is being run locally.

## Examples of Uploading the Container as a Flywheel Gear

### Prerequisites

1. Install the Flywheel CLI: https://docs.flywheel.io/CLI/
2. Log in to your Flywheel instance: `fw login <your-api-key>`
3. Edit the manifest file to fit with your specifications - you may have to change your username in place of `kjobson`

### Building and Uploading

1. **Build the Docker image:**

```bash
fw-beta gear build .
```

2. **Test**

```bash
fw-beta gear run .                  
```

3. **Upload to Flywheel:**

```bash
fw-beta gear upload .
```

This command reads the `manifest.json` and uploads the gear to your Flywheel instance.

### Running on Flywheel

1. Navigate to your session containing ASL data
2. Select the ASL timeseries file and M0 file
3. Click "Run Gear" and select "ASLscp: Self-Contained Processing"
4. Configure parameters if needed (or leave blank for automatic extraction)
5. Run the analysis

## Software Dependencies

The container includes:

- **FreeSurfer 7.4.1** - skull stripping (mri_synthstrip)
- **FSL 6.0.7.1** - motion correction, image math, registration tools
- **ANTs 2.5.4** - nonlinear registration
- **dcm2niix** - DICOM to NIfTI conversion
- **Python 3** with: scipy, nibabel, matplotlib, nilearn, reportlab

## Citation

If you use this pipeline, please cite the relevant software packages and acknowledge the developers.

## License

MIT License
