#!/bin/bash
#
# ASLscp Pipeline - Minimal ASL Pre-processing and CBF Calculation
# Original script by Manuel Taso
# Edited, added and uploaded to FW by krj
#
# Processes Siemens and GE ASL data for CBF calculation
#

# ==============================================================================
# INPUT VARIABLES
# ==============================================================================

script_name=$(basename "$0")
syntax="${script_name} [-a ASL input][-m M0 input][-l LD][-p PLD][-n NBS][-k M0_SCALE]"

while getopts "a:c:k:l:m:n:p:" arg; do
    case "$arg" in
        a) opt_a="$OPTARG" ;;
        c) opt_c="$OPTARG" ;;
        k) opt_k="$OPTARG" ;;
        l) opt_l="$OPTARG" ;;
        m) opt_m="$OPTARG" ;;
        n) opt_n="$OPTARG" ;;
        p) opt_p="$OPTARG" ;;
        *) echo "Usage: $syntax" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Determine config file location
if [ -n "${opt_c:-}" ]; then
    config_json_file="$opt_c"
else
    config_json_file="${FLYWHEEL:-.}/config.json"
fi

# Load ASL input path
if [ -n "${opt_a:-}" ]; then
    asl_zip="$opt_a"
else
    asl_zip=$(jq -r '.inputs.asl.location.path' "$config_json_file")
fi

# Load M0 input path
if [ -n "${opt_m:-}" ]; then
    m0_zip="$opt_m"
else
    m0_zip=$(jq -r '.inputs.m0.location.path' "$config_json_file")
fi

# Load optional parameters from config or command line
ld_input="${opt_l:-$(jq -r '.config.ld // empty' "$config_json_file")}"
pld_input="${opt_p:-$(jq -r '.config.pld // empty' "$config_json_file")}"
nbs_input="${opt_n:-$(jq -r '.config.nbs // empty' "$config_json_file")}"
m0scale_input="${opt_k:-$(jq -r '.config.m0_scale // empty' "$config_json_file")}"


# ==============================================================================
# DIRECTORY SETUP
# ==============================================================================

flywheel_dir="/flywheel/v0"
[ -e "$flywheel_dir" ] || mkdir "$flywheel_dir"

data_dir="${flywheel_dir}/input"
[ -e "$data_dir" ] || mkdir "$data_dir"

export_dir="${flywheel_dir}/output"
[ -e "$export_dir" ] || mkdir "$export_dir"


work_dir="${flywheel_dir}/work"
[ -e "$work_dir" ] || mkdir "$work_dir"

m0_dcm_dir="${work_dir}/m0_dcmdir"
[ -e "$m0_dcm_dir" ] || mkdir "$m0_dcm_dir"

asl_dcm_dir="${work_dir}/asl_dcmdir"
[ -e "$asl_dcm_dir" ] || mkdir "$asl_dcm_dir"

exe_dir="${flywheel_dir}/workflows"
[ -e "$exe_dir" ] || mkdir "$exe_dir"

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

is_valid_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# ==============================================================================
# DATA PREPROCESSING
# ==============================================================================

preprocess_data() {
    log "Starting data preprocessing"

    # Detect input type and process accordingly
    if [[ "$asl_zip" == *.nii.gz ]] || [[ "$asl_zip" == *.nii ]]; then
        # NIfTI input - copy directly, skip dcm2niix
        log "Detected NIfTI input for ASL - skipping dcm2niix"
        nifti_input=true
        cp "$asl_zip" "${asl_dcm_dir}/"
        asl_file="${asl_dcm_dir}/$(basename "$asl_zip")"
    elif file "$asl_zip" | grep -q 'Zip archive data'; then
        # DICOM zip
        unzip -d "$asl_dcm_dir" "$asl_zip"
        dcm2niix -f %d -b y -o "${asl_dcm_dir}/" "$asl_dcm_dir"
        nifti_input=false
    else
        die "ASL input must be a DICOM zip file or NIfTI file (.nii or .nii.gz)"
    fi

    # Process M0 input
    if [[ "$m0_zip" == *.nii.gz ]] || [[ "$m0_zip" == *.nii ]]; then
        # NIfTI input - copy directly, skip dcm2niix
        log "Detected NIfTI input for M0 - skipping dcm2niix"
        cp "$m0_zip" "${m0_dcm_dir}/"
        m0_file="${m0_dcm_dir}/$(basename "$m0_zip")"
    elif file "$m0_zip" | grep -q 'Zip archive data'; then
        # DICOM zip
        unzip -d "$m0_dcm_dir" "$m0_zip"
        dcm2niix -f %d -b y -o "${m0_dcm_dir}/" "$m0_dcm_dir"
    else
        die "M0 input must be a DICOM zip file or NIfTI file (.nii or .nii.gz)"
    fi

    # For DICOM input, find the converted NIfTI files
    if [ "$nifti_input" = false ]; then
        # Dcm2niix doesn't always work first try, so check and redo if files aren't present
        local attempt=1
        local max_attempt=2

        while (( attempt <= max_attempt )); do
            log "Attempt $attempt of $max_attempt..."

            asl_file=$(find "$asl_dcm_dir" -maxdepth 1 -type f -name "*ASL.nii")
            m0_file=$(find "$m0_dcm_dir" -maxdepth 1 -type f -name "*M0.nii")

            log "ASL file: $asl_file"
            log "M0 file: $m0_file"

            if [[ -n "$asl_file" && -n "$m0_file" ]]; then
                log "Both files found: $asl_file and $m0_file"
                break
            else
                if (( attempt < max_attempt )); then
                    log "Files missing. Retrying..."
                    for dir_name in ${asl_zip} ${m0_zip}; do
                        dcm2niix -f %d -b y -o "${work_dir}/" "${dir_name}/"
                    done
                else
                    die "Files still missing after $max_attempt attempts. Exiting."
                fi
            fi
            (( attempt++ ))
            sleep 5
        done
    else
        log "NIfTI input detected"
        log "ASL file: $asl_file"
        log "M0 file: $m0_file"
    fi
}

# ==============================================================================
# PARAMETER EXTRACTION
# ==============================================================================

extract_parameters() {
    log "Extracting acquisition parameters"

    # Check if parameters were provided via command line or config
    if is_valid_number "${ld_input:-}" && \
       is_valid_number "${pld_input:-}" && \
       is_valid_number "${nbs_input:-}" && \
       is_valid_number "${m0scale_input:-}"; then
        log "Using parameters from command line or config"
        ld="$ld_input"
        pld="$pld_input"
        nbs="$nbs_input"
        m0_scale="$m0scale_input"
        log "ld: ${ld}"
        log "pld: ${pld}"
        log "nbs: ${nbs}"
        log "m0_scale: ${m0_scale}"
    elif [ "$nifti_input" = true ]; then
        # NIfTI input requires manual parameters
        die "NIfTI input requires manual parameters. Provide -l (LD), -p (PLD), -n (NBS), and -k (M0_SCALE)."
    else
        # Extract from DICOM header
        log "Extracting parameters from DICOM files."
        dcm_file=$(find "${m0_dcm_dir}" -type f ! -name "*.nii" ! -name "*.nii.gz" ! -name "*.json" | head -n 1)

        if [ -z "$dcm_file" ]; then
            die "No DICOM file found for parameter extraction!"
        fi

        log "$dcm_file"
        ld=$(iconv -f UTF-8 -t UTF-8//IGNORE "$dcm_file" 2>/dev/null | awk -F 'sWipMemBlock.alFree\\[0\\][[:space:]]*=[[:space:]]*' '{print $2}' | tr -d '[:space:]')
        log "ld: ${ld}"
        pld=$(iconv -f UTF-8 -t UTF-8//IGNORE "$dcm_file" 2>/dev/null | awk -F 'sWipMemBlock.alFree\\[1\\][[:space:]]*=[[:space:]]*' '{print $2}' | tr -d '[:space:]')
        log "pld: ${pld}"
        nbs=$(iconv -f UTF-8 -t UTF-8//IGNORE "$dcm_file" 2>/dev/null | awk -F 'sWipMemBlock.alFree\\[11\\][[:space:]]*=[[:space:]]*' '{print $2}' | tr -d '[:space:]')
        log "nbs: ${nbs}"
        m0_scale=$(iconv -f UTF-8 -t UTF-8//IGNORE "$dcm_file" 2>/dev/null | awk -F 'sWipMemBlock.alFree\\[20\\][[:space:]]*=[[:space:]]*' '{print $2}' | tr -d '[:space:]')
        log "m0_scale: ${m0_scale}"
    fi

    if [[ -z "$ld" || -z "$pld" || -z "$nbs" || -z "$m0_scale" ]]; then
        die "One or more required variables (ld, pld, nbs, m0_scale) are unset or empty."
    fi
}

# ==============================================================================
# MOTION CORRECTION
# ==============================================================================

run_motion_correction() {
    log "Running motion correction"

    # Merge Data
    fslmerge -t "${work_dir}/all_data.nii.gz" "$m0_file" "$asl_file"

    # Motion correction
    mcflirt -in "${work_dir}/all_data.nii.gz" -out "${work_dir}/mc.nii.gz"

    # Split the data back up after motion correction
    fslroi "${work_dir}/mc.nii.gz" "${work_dir}/m0_mc.nii.gz" 0 1
    fslroi "${work_dir}/mc.nii.gz" "${work_dir}/m0_ir_mc.nii.gz" 0 2
    fslroi "${work_dir}/mc.nii.gz" "${work_dir}/asl_mc.nii.gz" 2 -1
}

# ==============================================================================
# SKULL STRIPPING
# ==============================================================================

skull_strip() {
    log "Performing skull stripping"
    "${FREESURFER_HOME}/bin/mri_synthstrip" -i "${work_dir}/m0_mc.nii.gz" -m "${work_dir}/mask.nii.gz"
    fslmaths "${work_dir}/mask.nii.gz" -ero "${work_dir}/mask_ero.nii.gz"
}

# ==============================================================================
# ASL SUBTRACTION
# ==============================================================================

run_asl_subtraction() {
    log "Running ASL subtraction"

    # If statement to check for nbs of 3 - this is from old data, should not come up for any protocol 2023 and on
    if [ "$nbs" == 3 ]; then
        asl_file --data="${work_dir}/asl_mc.nii.gz" --ntis=1 --iaf=ct --diff --out="${work_dir}/sub.nii.gz"
        log "nbs is 3, switching label and control"
    else
        asl_file --data="${work_dir}/asl_mc.nii.gz" --ntis=1 --iaf=tc --diff --out="${work_dir}/sub.nii.gz"
        log "nbs is greater than 3, no changes made to pipeline"
    fi

    fslmaths "${work_dir}/sub.nii.gz" -Tmean "${work_dir}/sub_av.nii.gz"
}

# ==============================================================================
# CBF CALCULATION
# ==============================================================================

calculate_cbf() {
    log "Calculating CBF"
    python3 /flywheel/v0/workflows/cbf_calc.py \
        -m0 "${work_dir}/m0_mc.nii.gz" \
        -asl "${work_dir}/sub_av.nii.gz" \
        -m "${work_dir}/mask.nii.gz" \
        -ld "$ld" \
        -pld "$pld" \
        -nbs "$nbs" \
        -scale "$m0_scale" \
        -out "${work_dir}"

    fslmaths "${work_dir}/cbf.nii.gz" -mas "${work_dir}/mask_ero.nii.gz" "${work_dir}/cbf_mas.nii.gz"
}

# ==============================================================================
# T1 QUANTIFICATION CHECK
# ==============================================================================

check_qt1_capability() {
    log "Checking T1 quantification capability"

    sidecar_json="${asl_file%.nii*}.json"
    qt1_capable=false

    if [[ -f "$sidecar_json" ]]; then
        while IFS= read -r s; do
            # Rule 1 - exact Upenn research sequence
            if [[ $s =~ %CustomerSeq%\\upenn_spiral_pcasl ]]; then
                qt1_capable=true
                break
            fi
            # Rule 2 - GE spiral Vnn (nn >= 23) *without* _Hwem
            if [[ $s =~ %CustomerSeq%\\SPIRAL_V([0-9]{2})_GE ]]; then
                ver=${BASH_REMATCH[1]}
                (( 10#$ver >= 23 )) && [[ ! $s =~ _Hwem ]] && { qt1_capable=true; break; }
            fi
        done < <(jq -r '.. | strings' "$sidecar_json")
    else
        log "Warning: side-car JSON not found - falling back to filename test."
    fi

    if [ "$qt1_capable" = true ]; then
        log "Version is greater than 22. Generating quantitative T1."
        python3 /flywheel/v0/workflows/t1fit.py \
            -m0_ir "${work_dir}/m0_ir_mc.nii.gz" \
            -m "${work_dir}/mask.nii.gz" \
            -out "${work_dir}"
    else
        log "Version is 22 or lower. Cannot generate quantitative T1."
    fi
}

# ==============================================================================
# OUTPUT PACKAGING
# ==============================================================================

package_outputs() {
    log "Packaging outputs"

    # Move all files we want easy access to into the output directory
    find "${work_dir}" -maxdepth 1 \
        \( -name "cbf.nii.gz" -o -name "t1.nii.gz" -o -name "mask.nii.gz" \) \
        -print0 | xargs -0 -I {} mv {} "${export_dir}/"

    zip -q -r "${export_dir}/final_output.zip" "${export_dir}"
    zip -q -r "${export_dir}/work_dir.zip" "${work_dir}"
}

# ==============================================================================
# MAIN PIPELINE
# ==============================================================================

log "Starting ASLscp pipeline"

preprocess_data
extract_parameters
run_motion_correction
skull_strip
run_asl_subtraction
calculate_cbf
check_qt1_capability
package_outputs

log "Pipeline completed successfully"
