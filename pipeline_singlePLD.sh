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
syntax="${script_name} [-a ASL input][-m M0 input][-s SubjectID][-l LD][-p PLD][-n NBS][-k M0_SCALE][-t T1w][-e][-r]"

while getopts "a:c:k:l:m:n:p:s:t:er" arg; do
    case "$arg" in
        a) opt_a="$OPTARG" ;;
        c) opt_c="$OPTARG" ;;
        e) opt_e=1 ;;
        k) opt_k="$OPTARG" ;;
        l) opt_l="$OPTARG" ;;
        m) opt_m="$OPTARG" ;;
        n) opt_n="$OPTARG" ;;
        p) opt_p="$OPTARG" ;;
        r) opt_r=1 ;;
        s) opt_s="$OPTARG" ;;
        t) opt_t="$OPTARG" ;;
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

# Load optional T1w input path
if [ -n "${opt_t:-}" ]; then
    t1w_input="$opt_t"
else
    t1w_input=$(jq -r '.inputs.t1w.location.path // empty' "$config_json_file")
fi

# Load optional parameters from config or command line
ld_input="${opt_l:-$(jq -r '.config.ld // empty' "$config_json_file")}"
pld_input="${opt_p:-$(jq -r '.config.pld // empty' "$config_json_file")}"
nbs_input="${opt_n:-$(jq -r '.config.nbs // empty' "$config_json_file")}"
m0scale_input="${opt_k:-$(jq -r '.config.m0_scale // empty' "$config_json_file")}"

# Skip extended analysis flag (registration, atlas, PDF)
if [ -n "${opt_e:-}" ]; then
    skip_extended="true"
else
    skip_extended=$(jq -r '.config.skip_extended // false' "$config_json_file" || echo "false")
fi

# Optional T1w registration (boolean config option)
if [ -n "${opt_r:-}" ]; then
    run_t1w_reg="true"
else
    run_t1w_reg=$(jq -r '.config.run_t1w_reg // false' "$config_json_file" || echo "false")
fi

# Subject ID from config
subject_id_input=$(jq -r '.config.subject_id // empty' "$config_json_file" || echo "")

# BIDS output option
bids_output=$(jq -r '.config.bids_output // false' "$config_json_file" || echo "false")


# ==============================================================================
# DIRECTORY SETUP
# ==============================================================================

flywheel_dir="/flywheel/v0"
[ -e "$flywheel_dir" ] || mkdir "$flywheel_dir"

data_dir="${flywheel_dir}/input"
[ -e "$data_dir" ] || mkdir "$data_dir"

export_dir="${flywheel_dir}/output"
[ -e "$export_dir" ] || mkdir "$export_dir"

std_dir="${data_dir}/std"
[ -e "$std_dir" ] || mkdir "$std_dir"

viz_dir="${export_dir}/viz"
[ -e "$viz_dir" ] || mkdir "$viz_dir"

work_dir="${flywheel_dir}/work"
[ -e "$work_dir" ] || mkdir "$work_dir"

m0_dcm_dir="${work_dir}/m0_dcmdir"
[ -e "$m0_dcm_dir" ] || mkdir "$m0_dcm_dir"

asl_dcm_dir="${work_dir}/asl_dcmdir"
[ -e "$asl_dcm_dir" ] || mkdir "$asl_dcm_dir"

t1w_dcm_dir="${work_dir}/t1w_dcmdir"
[ -e "$t1w_dcm_dir" ] || mkdir "$t1w_dcm_dir"

stats_dir="${export_dir}/stats"
[ -e "$stats_dir" ] || mkdir "$stats_dir"

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
# BIDS FUNCTIONS
# ==============================================================================

# Detect if input filename is BIDS-formatted and extract subject/session labels
parse_bids_filename() {
    local filename="$1"
    local basename
    basename=$(basename "$filename")

    # Reset BIDS variables
    bids_subject=""
    bids_session=""
    is_bids_input=false

    # Check for BIDS pattern: sub-<label>[_ses-<label>]_*
    if [[ "$basename" =~ ^sub-([a-zA-Z0-9]+) ]]; then
        bids_subject="${BASH_REMATCH[1]}"
        is_bids_input=true
        log "Detected BIDS subject label: $bids_subject"

        # Check for session label
        if [[ "$basename" =~ _ses-([a-zA-Z0-9]+) ]]; then
            bids_session="${BASH_REMATCH[1]}"
            log "Detected BIDS session label: $bids_session"
        fi
    fi
}

# Validate BIDS requirements
validate_bids_config() {
    if [ "$bids_output" = "true" ]; then
        log "BIDS output enabled"

        # Parse input filename for BIDS info
        parse_bids_filename "$asl_zip"

        # Determine subject ID: BIDS input > config > Flywheel metadata
        if [ "$is_bids_input" = true ]; then
            bids_sub="$bids_subject"
            bids_ses="$bids_session"
            log "Using BIDS labels from input filename"
        elif [ -n "$subject_id_input" ]; then
            bids_sub="$subject_id_input"
            bids_ses=""
            log "Using subject_id from config: $bids_sub"
        else
            die "BIDS output enabled but no subject ID available. Either provide BIDS-formatted input or set subject_id in config."
        fi

        log "BIDS subject: sub-$bids_sub"
        [ -n "$bids_ses" ] && log "BIDS session: ses-$bids_ses"
    fi
}

# Create BIDS derivatives output structure
create_bids_output() {
    log "Creating BIDS derivatives output structure"

    local bids_deriv_dir="${export_dir}/derivatives/aslscp"

    # Build path with optional session
    if [ -n "$bids_ses" ]; then
        bids_output_dir="${bids_deriv_dir}/sub-${bids_sub}/ses-${bids_ses}/perf"
        bids_prefix="sub-${bids_sub}_ses-${bids_ses}"
    else
        bids_output_dir="${bids_deriv_dir}/sub-${bids_sub}/perf"
        bids_prefix="sub-${bids_sub}"
    fi

    mkdir -p "$bids_output_dir"

    # Create dataset_description.json
    cat > "${bids_deriv_dir}/dataset_description.json" << 'BIDS_DESC'
{
    "Name": "ASLscp",
    "BIDSVersion": "1.8.0",
    "DatasetType": "derivative",
    "GeneratedBy": [
        {
            "Name": "ASLscp",
            "Description": "Self-Contained Processing for single-PLD ASL data",
            "CodeURL": "https://github.com/kjobson-neuro/ASLscp"
        }
    ]
}
BIDS_DESC

    log "BIDS output directory: $bids_output_dir"
    log "BIDS file prefix: $bids_prefix"
}

# Package outputs in BIDS format
package_bids_outputs() {
    log "Packaging BIDS outputs"

    create_bids_output

    # Copy and rename CBF map
    if [ -f "${work_dir}/cbf.nii.gz" ]; then
        cp "${work_dir}/cbf.nii.gz" "${bids_output_dir}/${bids_prefix}_desc-cbf_asl.nii.gz"

        # Create sidecar JSON
        cat > "${bids_output_dir}/${bids_prefix}_desc-cbf_asl.json" << BIDS_CBF_JSON
{
    "Description": "Cerebral blood flow map",
    "Units": "mL/100g/min",
    "LabelingDuration": ${ld},
    "PostLabelingDelay": ${pld},
    "BackgroundSuppressionPulseNumber": ${nbs},
    "M0ScaleFactor": ${m0_scale},
    "Sources": ["bids::sub-${bids_sub}${bids_ses:+/ses-${bids_ses}}/perf/${bids_prefix}_asl.nii.gz"]
}
BIDS_CBF_JSON
    fi

    # Copy and rename tSNR map
    if [ -f "${work_dir}/tSNR_map.nii.gz" ]; then
        cp "${work_dir}/tSNR_map.nii.gz" "${bids_output_dir}/${bids_prefix}_desc-tsnr_asl.nii.gz"
    fi

    # Copy and rename T1 map (if qt1 capable)
    if [ -f "${work_dir}/t1.nii.gz" ]; then
        cp "${work_dir}/t1.nii.gz" "${bids_output_dir}/${bids_prefix}_T1map.nii.gz"
    fi

    # Copy mask
    if [ -f "${work_dir}/mask.nii.gz" ]; then
        cp "${work_dir}/mask.nii.gz" "${bids_output_dir}/${bids_prefix}_desc-brain_mask.nii.gz"
    fi

    # Copy T1w registered outputs if available
    if [ "$run_t1w_reg" = "true" ]; then
        find "${work_dir}" -maxdepth 1 -name "*_reg_t1w*" -print0 | while IFS= read -r -d '' f; do
            local fname
            fname=$(basename "$f")
            cp "$f" "${bids_output_dir}/${bids_prefix}_space-T1w_${fname}"
        done
    fi

    # Copy PDFs to derivatives root (not strictly BIDS but useful)
    if [ -f "${work_dir}/output.pdf" ]; then
        cp "${work_dir}/output.pdf" "${bids_output_dir}/${bids_prefix}_report.pdf"
    fi
    if [ -f "${work_dir}/qc.pdf" ]; then
        cp "${work_dir}/qc.pdf" "${bids_output_dir}/${bids_prefix}_qc.pdf"
    fi

    # Copy stats directory
    if [ -d "${stats_dir}" ]; then
        mkdir -p "${bids_output_dir}/stats"
        cp -r "${stats_dir}"/* "${bids_output_dir}/stats/" || true
    fi

    log "BIDS outputs packaged successfully"
}

# ==============================================================================
# PIPELINE CONSTANTS
# ==============================================================================

# ROI atlases for statistical analysis
readonly roi_list=("arterial2" "cortical" "subcortical" "thalamus" "landau" "schaefer2018")

# ROI atlases included in visualization/PDF output (without thalamus)
readonly viz_roi_list=("arterial2" "cortical" "subcortical" "schaefer2018")

# Target regions for AD-related analysis
readonly target_regions=(
    "Left_Hippocampus"
    "Right_Hippocampus"
    "Left_Putamen"
    "Right_Putamen"
    "Cingulate_Gyrus,_posterior_division"
    "Precuneous_Cortex"
)

# ==============================================================================
# METADATA EXTRACTION
# ==============================================================================

extract_metadata() {
    log "Extracting metadata"
    touch "${work_dir}/metadata.json"
    python3 "${exe_dir}/flywheel_context.py" -dir "${work_dir}"

    if [ ! -f "${work_dir}/metadata.json" ]; then
        log_error "Failed to generate metadata file"
    fi

    metadata_file="${work_dir}/metadata.json"
    log "Metadata file created at: $metadata_file"
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
            -out "${work_dir}" \
            -stats "${stats_dir}"
    else
        log "Version is 22 or lower. Cannot generate quantitative T1."
    fi
}

# ==============================================================================
# OPTIONAL T1W REGISTRATION
# ==============================================================================

preprocess_t1w() {
    log "Preprocessing T1w input"

    # Detect input type and process accordingly
    if [[ "$t1w_input" == *.nii.gz ]] || [[ "$t1w_input" == *.nii ]]; then
        # NIfTI input - copy directly, skip dcm2niix
        log "Detected NIfTI input for T1w - skipping dcm2niix"
        cp "$t1w_input" "${t1w_dcm_dir}/"
        t1w_file="${t1w_dcm_dir}/$(basename "$t1w_input")"
    elif file "$t1w_input" | grep -q 'Zip archive data'; then
        # DICOM zip - extract and convert
        log "Detected DICOM zip for T1w - running dcm2niix"
        unzip -d "$t1w_dcm_dir" "$t1w_input"
        dcm2niix -f %d -b y -o "${t1w_dcm_dir}/" "$t1w_dcm_dir"
        t1w_file=$(find "$t1w_dcm_dir" -maxdepth 1 -type f \( -name "*.nii" -o -name "*.nii.gz" \) | head -n 1)
        if [ -z "$t1w_file" ]; then
            die "Failed to convert T1w DICOM to NIfTI"
        fi
    else
        die "T1w input must be a DICOM zip file or NIfTI file (.nii or .nii.gz)"
    fi

    log "T1w file: $t1w_file"
}

run_t1w_registration() {
    log "Running optional T1w registration"

    "${exe_dir}/optional_regT1w.sh" \
        -m "${work_dir}/m0_mc.nii.gz" \
        -c "${work_dir}/cbf.nii.gz" \
        -t "$t1w_file" \
        -o "${work_dir}"

    log "T1w registration completed"
}

# ==============================================================================
# IMAGE REGISTRATION
# ==============================================================================

register_to_template() {
    log "Registering to template space"

    # Smoothing ASL image subject space, deforming images to match template
    fslmaths "${work_dir}/sub_av.nii.gz" -s 1.5 -mas "${work_dir}/mask.nii.gz" "${work_dir}/s_asl.nii.gz"

    "${ANTSPATH}/antsRegistration" \
        --dimensionality 3 \
        --transform "Affine[0.25]" \
        --metric "MI[${std_dir}/batsasl/bats_asl_masked.nii.gz,${work_dir}/s_asl.nii.gz,1,32]" \
        --convergence 100x20 \
        --shrink-factors 4x1 \
        --smoothing-sigmas 2x0mm \
        --transform "SyN[0.1]" \
        --metric "CC[${std_dir}/batsasl/bats_asl_masked.nii.gz,${work_dir}/s_asl.nii.gz,1,1]" \
        --convergence 40x20 \
        --shrink-factors 2x1 \
        --smoothing-sigmas 2x0mm \
        --output "[${work_dir}/ind2temp,${work_dir}/ind2temp_warped.nii.gz,${work_dir}/temp2ind_warped.nii.gz]" \
        --collapse-output-transforms 1 \
        --interpolation BSpline \
        -v 1

    log "ANTs Registration finished"

    # Warping atlases, deforming ROI
    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${std_dir}/batsasl/bats_cbf.nii.gz" \
        "${work_dir}/w_batscbf.nii.gz" \
        -R "${work_dir}/sub_av.nii.gz" \
        -i "${work_dir}/ind2temp0GenericAffine.mat" \
        "${work_dir}/ind2temp1InverseWarp.nii.gz"
}

# ==============================================================================
# ROI ANALYSIS
# ==============================================================================

process_roi() {
    local roi="$1"
    log "Processing ROI: ${roi}"

    touch "${stats_dir}/tmp_${roi}.txt"
    touch "${stats_dir}/cbf_${roi}.txt"
    touch "${stats_dir}/${roi}_vox.txt"
    log "Printed ${stats_dir}"

    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${std_dir}/${roi}.nii.gz" \
        "${work_dir}/w_${roi}.nii.gz" \
        -R "${work_dir}/sub_av.nii.gz" \
        --use-NN \
        -i "${work_dir}/ind2temp0GenericAffine.mat" \
        "${work_dir}/ind2temp1InverseWarp.nii.gz"

    fslmaths "${work_dir}/w_${roi}.nii.gz" -mas "${work_dir}/mask_ero.nii.gz" "${work_dir}/w_${roi}_mas.nii.gz"
    fslstats -K "${work_dir}/w_${roi}_mas.nii.gz" "${work_dir}/cbf_mas.nii.gz" -M -S > "${stats_dir}/tmp_${roi}.txt"
    fslstats -K "${work_dir}/w_${roi}_mas.nii.gz" "${work_dir}/cbf_mas.nii.gz" -V > "${stats_dir}/${roi}_vox.txt"
    paste "${std_dir}/${roi}_label.txt" -d ' ' "${stats_dir}/tmp_${roi}.txt" "${stats_dir}/${roi}_vox.txt" > "${stats_dir}/cbf_${roi}.txt"
}

format_roi_stats() {
    local roi="$1"
    local input_cbf="${stats_dir}/cbf_${roi}.txt"
    local output_cbf="${stats_dir}/formatted_cbf_${roi}.txt"
    local temp_dir="/flywheel/v0/work/temp_$(date +%s)"
    mkdir -p "$temp_dir"

    local temp_file="$temp_dir/tmp_cbf_${roi}.txt"
    echo "Region | Mean CBF | Standard Deviation | Voxels | Volume" > "$temp_file"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local mean_cbf std_dev voxels volume region
        mean_cbf=$(echo "$line" | awk '{print $(NF-3)}')
        std_dev=$(echo "$line" | awk '{print $(NF-2)}')
        voxels=$(echo "$line" | awk '{print $(NF-1)}')
        volume=$(echo "$line" | awk '{print $NF}')

        region=$(echo "$line" | awk '{
            for (i=1; i<=NF-4; i++)
            printf "%s ", $i;
        }' | sed 's/[[:space:]]$//')

        # Skip lines with 'missing label' or bad entries
        [[ -z "$region" || "$region" == "0" || "$region" == *"missing label"* || "$voxels" < "10" ]] && continue

        formatted_mean=$(printf "%.1f" "$mean_cbf")
        formatted_std=$(printf "%.1f" "$std_dev")
        formatted_voxels=$(printf "%.1f" "$voxels")
        formatted_volume=$(printf "%.1f" "$volume")

        echo "$region | $formatted_mean | $formatted_std | $formatted_voxels | $formatted_volume" >> "$temp_file"
    done < "$input_cbf"

    column -t -s '|' -o '|' "$temp_file" > "$output_cbf"
    rm -rf "$temp_dir"
}

run_roi_analysis() {
    log "Running ROI analysis"

    for roi in "${roi_list[@]}"; do
        process_roi "$roi"
    done

    for roi in "${roi_list[@]}"; do
        format_roi_stats "$roi"
    done
}

# ==============================================================================
# EXTRACT AD-RELATED REGIONS
# ==============================================================================

extract_ad_regions() {
    log "Extracting AD-related regions"

    local extracted_file="${stats_dir}/extracted_regions_combined.txt"
    echo "Region | Mean CBF | Standard Deviation | Voxels | Volume" > "$extracted_file"

    for type in cortical subcortical landau; do
        local source_file="${stats_dir}/formatted_cbf_${type}.txt"
        [[ -f "$source_file" ]] || continue

        while IFS= read -r line; do
            [[ "$line" == "Region |"* ]] || [[ -z "$line" ]] && continue

            local region
            region=$(echo "$line" | awk -F '|' '{print $1}' | xargs)

            for target in "${target_regions[@]}"; do
                if [[ "$region" == "$target" ]]; then
                    echo "$line" >> "$extracted_file"
                fi
            done
        done < "$source_file"
    done
}

# ==============================================================================
# WEIGHTED rCBF CALCULATIONS
# ==============================================================================

calculate_weighted_rcbf() {
    log "Calculating weighted rCBF values"

    local cortical="${stats_dir}/formatted_cbf_cortical.txt"
    local subcortical="${stats_dir}/formatted_cbf_subcortical.txt"
    local landau="${stats_dir}/formatted_cbf_landau.txt"

    pcc=$(grep "Cingulate_Gyrus,_posterior_division" "$cortical" | awk -F '|' '{print $2}' | xargs)
    pcc_voxel=$(grep "Cingulate_Gyrus,_posterior_division" "$cortical" | awk -F '|' '{print $5}' | xargs)
    precuneus=$(grep "Precuneous_Cortex" "$cortical" | awk -F '|' '{print $2}' | xargs)
    precuneus_voxel=$(grep "Precuneous_Cortex" "$cortical" | awk -F '|' '{print $5}' | xargs)
    hipp_left=$(grep "Left_Hippocampus" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    hipp_left_voxel=$(grep "Left_Hippocampus" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    hipp_right=$(grep "Right_Hippocampus" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    hipp_right_voxel=$(grep "Right_Hippocampus" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    grey_left=$(grep "Left_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    grey_left_vox=$(grep "Left_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    grey_right=$(grep "Right_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    grey_right_vox=$(grep "Right_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    white_left=$(grep "Left_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    white_left_vox=$(grep "Left_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    white_right=$(grep "Right_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    white_right_vox=$(grep "Right_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    putamen_left=$(grep "Left_Putamen" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    putamen_left_vox=$(grep "Left_Putamen" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    putamen_right=$(grep "Right_Putamen" "$subcortical" | awk -F '|' '{print $2}' | xargs)
    putamen_right_vox=$(grep "Right_Putamen" "$subcortical" | awk -F '|' '{print $5}' | xargs)
    landau_meta=$(grep "Landau_metaROI" "$landau" | awk -F '|' '{print $2}' | xargs)
    landau_meta_vox=$(grep "Landau_metaROI" "$landau" | awk -F '|' '{print $5}' | xargs)

    # Left and right grey matter
    grey_matter_weighted=$(echo "scale=4; ($grey_left * $grey_left_vox + $grey_right * $grey_right_vox) / ($grey_left_vox + $grey_right_vox)" | bc -l)

    # Left and right white matter
    white_matter_weighted=$(echo "scale=4; ($white_left * $white_left_vox + $white_right * $white_right_vox) / ($white_left_vox + $white_right_vox)" | bc -l)

    # Whole brain
    whole_brain_weighted=$(echo "scale=4; ($grey_left * $grey_left_vox + $grey_right * $grey_right_vox + $white_left * $white_left_vox + $white_right * $white_right_vox) / ($grey_left_vox + $grey_right_vox + $white_left_vox + $white_right_vox)" | bc -l)
    log "Whole brain weighted CBF: $whole_brain_weighted"

    # Left and right putamen
    putamen_weighted=$(echo "scale=4; ($putamen_left * $putamen_left_vox + $putamen_right * $putamen_right_vox) / ($putamen_left_vox + $putamen_right_vox)" | bc -l)

    # PCC+Precuneus calculation
    pcc_precuneus_weighted=$(echo "scale=4; ($pcc * $pcc_voxel + $precuneus * $precuneus_voxel) / ($pcc_voxel + $precuneus_voxel)" | bc -l)

    # Hippocampus calculation
    hippocampus_weighted=$(echo "scale=4; ($hipp_left * $hipp_left_voxel + $hipp_right * $hipp_right_voxel) / ($hipp_left_voxel + $hipp_right_voxel)" | bc -l)

    # Clear or create the output file
    local weighted_rcbf="${stats_dir}/weighted_rcbf.txt"
    : > "$weighted_rcbf"

    echo "Region | CBF | Voxels" > "$weighted_rcbf"

    # Whole brain
    if [[ -n "$whole_brain_weighted" && "$whole_brain_weighted" =~ ^[0-9.]+$ ]]; then
        whole_brain_vox=$(echo "scale=4; ($grey_left_vox + $grey_right_vox + $white_left_vox + $white_right_vox)" | bc -l)
        echo "Whole brain | $whole_brain_weighted | $whole_brain_vox" >> "$weighted_rcbf"
    else
        log "Whole brain CBF value is not a number"
    fi

    # Grey Matter
    if [[ -n "$grey_matter_weighted" && "$grey_matter_weighted" =~ ^[0-9.]+$ ]]; then
        grey_matter_vox=$(echo "$grey_right_vox + $grey_left_vox" | bc -l)
        echo "Grey_Matter L+R | $grey_matter_weighted | $grey_matter_vox" >> "$weighted_rcbf"
    else
        log "Grey_Matter_L+R value is not a number"
    fi

    # White Matter
    if [[ -n "$white_matter_weighted" && "$white_matter_weighted" =~ ^[0-9.]+$ ]]; then
        white_matter_vox=$(echo "$white_right_vox + $white_right_vox" | bc -l)
        echo "White_Matter L+R | $white_matter_weighted | $white_matter_vox" >> "$weighted_rcbf"
    else
        log "White_Matter_L+R value is not a number"
    fi

    # PCC+Precuneus row
    if [[ -n "$pcc_precuneus_weighted" && "$pcc_precuneus_weighted" =~ ^[0-9.]+$ ]]; then
        pcc_precuneus_vox=$(echo "$pcc_voxel + $precuneus_voxel" | bc -l)
        echo "PCC+Precuneus | $pcc_precuneus_weighted | $pcc_precuneus_vox" >> "$weighted_rcbf"
    else
        log "PCC+Precuneus value is not a number"
    fi

    # Hippocampus row
    if [[ -n "$hippocampus_weighted" && "$hippocampus_weighted" =~ ^[0-9.]+$ ]]; then
        hipp_vox=$(echo "$hipp_right_voxel + $hipp_left_voxel" | bc -l)
        echo "Hippocampus L+R | $hippocampus_weighted | $hipp_vox" >> "$weighted_rcbf"
    else
        log "Hippocampus_L+R value is not a number"
    fi

    cat "$weighted_rcbf"

    # Calculate reference CBF values
    wholebrain_cbf=$(sed -n 's/[^0-9]*\([0-9]\+\).*/\1/p; q' "${stats_dir}/cbf_wholebrain.txt")

    # Add ratio columns to extracted file
    local temp_file="${stats_dir}/temp_ratio_calc.txt"
    awk -F '|' -v put_cbf="$putamen_weighted" '
    BEGIN {
        OFS = " | "
        print "Region | Mean | rCBF | Voxels"
    }
    {
        if (NF < 3 || $0 ~ /^Region/) next

        mean = $2 + 0
        voxels = $3 + 0

        rCBF = (mean != 0) ? mean / put_cbf : "NA"

        printf "%s | %.0f | %.1f | %.0f\n", \
            $1, mean, rCBF, voxels
    }' "$weighted_rcbf" | column -t -s '|' -o '|' > "$temp_file"

    local weighted_table="${stats_dir}/weighted_table.txt"
    mv "$temp_file" "$weighted_table"
}

# ==============================================================================
# POST-PROCESSING
# ==============================================================================

run_post_processing() {
    log "Running post-processing"

    # Smoothing the deformation field of images obtained previously
    fslmaths "${work_dir}/ind2temp1Warp.nii.gz" -s 5 "${work_dir}/swarp.nii.gz"

    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${work_dir}/sub_av.nii.gz" \
        "${work_dir}/s_ind2temp_warped.nii.gz" \
        -R "${work_dir}/ind2temp_warped.nii.gz" \
        --use-BSpline \
        "${work_dir}/swarp.nii.gz" \
        "${work_dir}/ind2temp0GenericAffine.mat"

    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${work_dir}/cbf.nii.gz" \
        "${work_dir}/wcbf.nii.gz" \
        -R "${work_dir}/ind2temp_warped.nii.gz" \
        --use-BSpline \
        "${work_dir}/swarp.nii.gz" \
        "${work_dir}/ind2temp0GenericAffine.mat"

    # tSNR calculation
    fslmaths "${work_dir}/sub.nii.gz" -Tmean "${work_dir}/sub_mean.nii.gz"
    fslmaths "${work_dir}/sub.nii.gz" -Tstd "${work_dir}/sub_std.nii.gz"
    fslmaths "${work_dir}/sub_mean.nii.gz" -div "${work_dir}/sub_std.nii.gz" "${work_dir}/tSNR_map.nii.gz"
}

# ==============================================================================
# VISUALIZATION
# ==============================================================================

create_visualizations() {
    log "Creating visualizations"

    # Upsampling to 1mm and then smoothing to 2 voxels for nicer viz
    flirt -in "${work_dir}/cbf.nii.gz" -ref "${work_dir}/cbf.nii.gz" \
        -applyisoxfm 1.0 -nosearch -out "${work_dir}/cbf_1mm.nii.gz" -interp spline
    flirt -in "${work_dir}/mask.nii.gz" -ref "${work_dir}/mask.nii.gz" \
        -applyisoxfm 1.0 -nosearch -out "${work_dir}/mask_1mm.nii.gz"
    fslmaths "${work_dir}/cbf_1mm.nii.gz" -s 2 "${work_dir}/s_cbf_1mm.nii.gz"

    if [ "$qt1_capable" = true ]; then
        log "Version is greater than 22. Generating viz with quantitative T1."
        "${ANTSPATH}/WarpImageMultiTransform" 3 \
            "${work_dir}/t1.nii.gz" \
            "${work_dir}/wt1.nii.gz" \
            -R "${work_dir}/ind2temp_warped.nii.gz" \
            --use-BSpline \
            "${work_dir}/swarp.nii.gz" \
            "${work_dir}/ind2temp0GenericAffine.mat"

        python3 /flywheel/v0/workflows/viz.py \
            -cbf "${work_dir}/s_cbf_1mm.nii.gz" \
            -t1 "${work_dir}/t1.nii.gz" \
            -out "${viz_dir}/" \
            -seg_folder "${work_dir}/" \
            -seg "${viz_roi_list[@]}" \
            -mask "${work_dir}/mask_1mm.nii.gz"
    else
        log "Version is 22 or lower. Cannot generate viz with quantitative T1."
        python3 /flywheel/v0/workflows/not1_viz.py \
            -cbf "${work_dir}/s_cbf_1mm.nii.gz" \
            -out "${viz_dir}/" \
            -seg_folder "${work_dir}/" \
            -seg "${viz_roi_list[@]}" \
            -mask "${work_dir}/mask_1mm.nii.gz"
    fi
}

# ==============================================================================
# PDF GENERATION
# ==============================================================================

generate_reports() {
    log "Generating PDF reports"

    if [ "$qt1_capable" = true ]; then
        python3 /flywheel/v0/workflows/pdf.py \
            -viz "${viz_dir}" \
            -stats "${stats_dir}/" \
            -out "${work_dir}/" \
            -seg_folder "${work_dir}/" \
            -seg "${viz_roi_list[@]}"
    else
        python3 /flywheel/v0/workflows/not1_pdf.py \
            -viz "${viz_dir}" \
            -stats "${stats_dir}/" \
            -out "${work_dir}/" \
            -seg_folder "${work_dir}/" \
            -seg "${viz_roi_list[@]}"
    fi

    python3 /flywheel/v0/workflows/qc.py \
        -viz "${viz_dir}" \
        -out "${work_dir}" \
        -seg_folder "${work_dir}/" \
        -seg "${viz_roi_list[@]}"
}

# ==============================================================================
# OUTPUT PACKAGING
# ==============================================================================

package_outputs() {
    log "Packaging outputs"

    # If BIDS output is enabled, use BIDS packaging
    if [ "$bids_output" = "true" ]; then
        package_bids_outputs

        # Also create zip archives
        local zip_prefix="sub-${bids_sub}"
        [ -n "$bids_ses" ] && zip_prefix="${zip_prefix}_ses-${bids_ses}"
        zip -q -r "${export_dir}/${zip_prefix}_derivatives.zip" "${export_dir}/derivatives"
        zip -q -r "${export_dir}/${zip_prefix}_work_dir.zip" "${work_dir}"
        return
    fi

    # Standard (non-BIDS) output packaging
    # Move all files we want easy access to into the output directory
    find "${work_dir}" -maxdepth 1 \
        \( -name "cbf.nii.gz" -o -name "viz" -o -name "stats" -o -name "t1.nii.gz" -o -name "tSNR_map.nii.gz" -o -name "output.pdf" -o -name "qc.pdf" \) \
        -print0 | xargs -0 -I {} mv {} "${export_dir}/"

    mv "${export_dir}/stats/tmp"* "${work_dir}/" || true

    # Copy T1w registered outputs if T1w registration was run
    if [ "$run_t1w_reg" = "true" ]; then
        # Copy the T1w file to output directory
        cp "$t1w_file" "${export_dir}/t1w_anat.nii.gz" || true
        # Copy any registered outputs from the registration script
        find "${work_dir}" -maxdepth 1 -name "*_reg_t1w*" -print0 | xargs -0 -I {} cp {} "${export_dir}/" || true
    fi

    # Determine subject ID: config > Flywheel metadata
    local subject_id
    if [ -n "$subject_id_input" ]; then
        subject_id="$subject_id_input"
    else
        subject_id=$(grep "^Subject:" "${work_dir}/metadata.json" | cut -d' ' -f2- || echo "")
    fi

    if [ -z "$subject_id" ]; then
        log "Subject ID not found, using generic names"
        zip -q -r "${export_dir}/final_output.zip" "${export_dir}"
        zip -q -r "${export_dir}/work_dir.zip" "${work_dir}"
    else
        log "Subject ID: $subject_id"
        mv "${export_dir}/cbf.nii.gz" "${export_dir}/${subject_id}_cbf.nii.gz" || true
        mv "${export_dir}/output.pdf" "${export_dir}/${subject_id}_output.pdf" || true
        mv "${export_dir}/qc.pdf" "${export_dir}/${subject_id}_qc.pdf" || true
        mv "${export_dir}/t1.nii.gz" "${export_dir}/${subject_id}_t1.nii.gz" || true
        mv "${export_dir}/tSNR_map.nii.gz" "${export_dir}/${subject_id}_tSNR_map.nii.gz" || true
        mv "${export_dir}/t1w_anat.nii.gz" "${export_dir}/${subject_id}_t1w_anat.nii.gz" || true
        zip -q -r "${export_dir}/${subject_id}_final_output.zip" "${export_dir}"
        zip -q -r "${export_dir}/${subject_id}_work_dir.zip" "${work_dir}"
    fi
}

# ==============================================================================
# MAIN PIPELINE
# ==============================================================================

log "Starting ASLscp pipeline"

extract_metadata
preprocess_data
validate_bids_config
extract_parameters
run_motion_correction
skull_strip
run_asl_subtraction
calculate_cbf
check_qt1_capability

# Optional T1w registration
if [ "$run_t1w_reg" = "true" ]; then
    preprocess_t1w
    run_t1w_registration
fi

if [ "$skip_extended" != "true" ]; then
    register_to_template
    run_roi_analysis
    extract_ad_regions
    calculate_weighted_rcbf
    run_post_processing
    create_visualizations
    generate_reports
fi

package_outputs

log "Pipeline completed successfully"
