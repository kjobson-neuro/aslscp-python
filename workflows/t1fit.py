import os
import numpy as np
import nibabel as nib
import matplotlib.pyplot as plt
import scipy 
import argparse
import sys

parser = argparse.ArgumentParser(description='get dcm parameters from the pipeline script')

# Set up parser for the parameters extracted from the dicom header
parser.add_argument('-m0_ir', type=str, help="The path to the m0_ir file.")
parser.add_argument('-stats', type=str, help="The path to the stats directory.")
parser.add_argument('-m', type=str, help="The path to the mask file.")
parser.add_argument('-out',type=str, help='The output directory.')
args = parser.parse_args()

m0_ir_file = args.m0_ir
mask = args.m
out_dir = args.out
stats_dir = args.stats

ref_data = nib.load(m0_ir_file).get_fdata().astype(np.float64)

mask_img = nib.load(mask).get_fdata().astype(np.float64)

T1 = np.arange(100, 5010, 10)
trec = 5000
TI = 1978

z = (1 - 2 * np.exp(-TI / T1) + np.exp(-trec / T1)) / (1 - np.exp(-trec / T1))

ratio = ref_data[:,:,:,1] / ref_data[:,:,:,0]
# ratio = ratio * mask_img
ratio[ratio==0] = np.min(z)
ratio[ratio>=1] = np.max(z)
f = scipy.interpolate.interp1d(z,T1, fill_value='extrapolate')

t1 = f(ratio)
t1[np.isnan(t1)] = 0
t1 = t1 * mask_img

nii = nib.load(mask)
nii.header.set_data_dtype(np.float32)
nii_data = np.asarray(t1, dtype=np.float32)
nii_img = nib.Nifti1Image(nii_data, nii.affine,nii.header)
name = out_dir + '/t1.nii.gz'
nib.save(nii_img, name)

nii_data_m0 = ref_data[:,:,:,0]
nii_data_m0 = np.asarray(nii_data_m0, dtype=np.float32)
nii_img_m0 = nib.Nifti1Image(nii_data_m0, nii.affine,nii.header)
name_m0 = out_dir + '/m0.nii.gz'
nib.save(nii_img_m0, name_m0)
