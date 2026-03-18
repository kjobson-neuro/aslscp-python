#!/bin/bash
#
# Optional T1w Registration Script
# Registers M0 and CBF images to T1w anatomical space
#

# Parse command line arguments
while getopts "m:c:t:o:" arg; do
    case "$arg" in
        m) m0_image="$OPTARG" ;;
        c) cbf_image="$OPTARG" ;;
        t) t1w_image="$OPTARG" ;;
        o) output_dir="$OPTARG" ;;
        *) echo "Usage: $0 -m <m0_image> -c <cbf_image> -t <t1w_image> -o <output_dir>" >&2; exit 1 ;;
    esac
done

# Validate required arguments
if [[ -z "$m0_image" || -z "$cbf_image" || -z "$t1w_image" || -z "$output_dir" ]]; then
    echo "Error: All arguments required: -m <m0_image> -c <cbf_image> -t <t1w_image> -o <output_dir>" >&2
    exit 1
fi

# ==============================================================================
# SKULLSTRIPPING
# ==============================================================================

"${FREESURFER_HOME}/bin/mri_synthstrip" -i "${m0_image}" -m "${output_dir}/m0_mask.nii.gz" -o "${output_dir}/m0_stripped.nii.gz"

"${FREESURFER_HOME}/bin/mri_synthstrip" -i "${t1w_image}" -m "${output_dir}/t1w_mask.nii.gz" -o "${output_dir}/t1w_brain.nii.gz"

# ==============================================================================
# IMAGE REGISTRATION
# ==============================================================================

# Register M0 to T1w space using ANTs
${ANTSPATH}/antsRegistration \
        --dimensionality 3 \
        --transform "Affine[0.25]" \
        --metric "MI["${output_dir}/t1w_brain.nii.gz","${output_dir}/m0_stripped.nii.gz",1,32]" \
        --convergence 100x20 \
        --shrink-factors 4x1 \
        --smoothing-sigmas 2x0mm \
        --transform "SyN[0.1]" \
        --metric "CC["${output_dir}/t1w_brain.nii.gz","${output_dir}/m0_stripped.nii.gz",1,1]" \
        --convergence 40x20 \
        --shrink-factors 2x1 \
        --smoothing-sigmas 2x0mm \
        -o "[${output_dir}/m02t1,${output_dir}/m02t1_warped.nii.gz,${output_dir}/t12m0_warped.nii.gz]" \
        --collapse-output-transforms 1 \
        --interpolation BSpline \
        -v 1
      
# Use M0 transformation .mat file to transform CBF map
${ANTSPATH}/antsApplyTransforms \
  -d 3 \
  -i "${cbf_image}" \
  -r "${output_dir}/t1w_brain.nii.gz" \
  -t ${output_dir}/m02t11Warp.nii.gz \
  -t ${output_dir}/m02t10GenericAffine.mat \
  -o "${output_dir}/t1wspace_cbf.nii.gz"
