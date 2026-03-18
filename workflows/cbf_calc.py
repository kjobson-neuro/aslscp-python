import os
import numpy as np
import nibabel as nib
import subprocess
import argparse
import sys

parser = argparse.ArgumentParser(description='get dcm parameters from the pipeline script')

# Set up parser for the parameters extracted from the dicom header
parser.add_argument('-m0', type=str, help="The path to the m0 file.")
parser.add_argument('-asl', type=str, help="The path to the ASL file.")
parser.add_argument('-m', type=str, help="The path to the mask file.")
parser.add_argument('-ld',  type=int, help='An integer number.')
parser.add_argument('-pld', type=int, help='An integer number.')
parser.add_argument('-nbs', type=int, help='An integer number.')
parser.add_argument('-scale',type=float, help='An integer number.')
parser.add_argument('-out',type=str, help='The output directory.')
args = parser.parse_args()

nameref = args.m0
ref_data = nib.load(nameref).get_fdata().astype(np.float64)

nameasl = args.asl
asl_data = nib.load(nameasl).get_fdata().astype(np.float64)

namemask = args.m
mask_data = nib.load(namemask).get_fdata().astype(np.float64)
####

m0 = ref_data * args.scale
a = 0.8
abs_val = 0.95 ** args.nbs
lmbda = 0.9
t1b = 1.6
ld = args.ld/10**6
pld = args.pld/10**6

cbf = (asl_data / m0) * (6000 * lmbda * np.exp(pld / t1b)) / ((2 * a * abs_val * t1b) * (1 - np.exp(-ld / t1b)))
cbf[np.isinf(cbf) | np.isnan(cbf)] = 0

cbf = cbf * mask_data

modified_img = nib.Nifti1Image(cbf, nib.load(namemask).affine, nib.load(namemask).header)

out_dir = args.out
print(out_dir)
nameout = os.path.join(out_dir, 'cbf.nii.gz')
nib.save(modified_img, nameout)




