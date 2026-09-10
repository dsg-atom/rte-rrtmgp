#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Memory-error probe for the in-model GPU crash.
#
# The in-model GPU run corrupts HOST memory (land-tile "Areas do not add to 1") at the first
# longwave compute, while the standalone flux checks are bit-identical. A flux-only check cannot
# see a stray write that lands next to the flux arrays: padding in the bench, live land state in
# the model. compute-sanitizer memcheck DOES see it and names the offending kernel + line.
#
# This reuses the exact ifort-caller -> nvfortran .so path from run_cwrap_test.sbatch and runs it
# under compute-sanitizer at two sizes:
#   (1) 1024 72 256 1  -- the config that already printed "bit-identical" sums (control)
#   (2) 2048 91 128 1  -- GEOS model dims: nlay=91 (nlay+1=92 levels), ngpt=128 (LW g128), nmus=1
# An out-of-bounds device write or a copyout past a flux array will be reported for (1) even though
# its fluxes match -- that is the whole point.
#
# Prereq: ../../build/librtekernels.so must already exist (nvfortran -O3 -acc -gpu=cc80 -shared).
# Submit:  sbatch run_memcheck.sbatch
# ------------------------------------------------------------------------------------------------
#SBATCH --job-name=lw_memchk
#SBATCH --partition=gpu_a100
#SBATCH --constraint=rome
#SBATCH --gres=gpu:1
#SBATCH --account=ilab
#SBATCH --time=00:20:00
#SBATCH --output=lw_memchk.%j.out

set -e
cd "$SLURM_SUBMIT_DIR"

NVLIB=/usr/local/other/nvidia/hpc_sdk/Linux_x86_64/24.7/compilers/lib
SO_DIR=$(cd ../../build && pwd)

echo "=== prebuilt GPU kernel .so present? ==="
ls -l "$SO_DIR/librtekernels.so"

echo "=== load toolchain: nvhpc runtime + Intel (for ifort) ==="
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
module load comp/gcc/12.3.0 comp/intel/2024.2.0
which ifort
which compute-sanitizer || echo "WARNING: compute-sanitizer not on PATH -- check the CUDA bin under nvhpc"

echo "=== compile + link the ifort caller against the nvfortran .so ==="
ifort -diag-disable=10448 -c lw_solver_cwrap_ifort.f90
ifort -diag-disable=10448 lw_solver_cwrap_ifort.o -o lw_cwrap \
      -L"$SO_DIR" -lrtekernels \
      -Wl,-rpath,"$SO_DIR" -Wl,-rpath,"$NVLIB" -L"$NVLIB"

# Force blocking kernel launches so any fault is reported against the launch that caused it.
export CUDA_LAUNCH_BLOCKING=1
# Log every host<->device transfer with its byte size, so copyout extents are visible in the output.
export NVCOMPILER_ACC_NOTIFY=3

echo ""
echo "############################################################"
echo "### (1) CONTROL: the config that already printed bit-identical sums"
echo "############################################################"
compute-sanitizer --tool memcheck --leak-check full --print-limit 20 \
    ./lw_cwrap 1024 72 256 1
echo "memcheck (control) exit: $?"

echo ""
echo "############################################################"
echo "### (2) MODEL DIMS: nlay=91 ngpt=128 nmus=1"
echo "############################################################"
compute-sanitizer --tool memcheck --leak-check full --print-limit 20 \
    ./lw_cwrap 2048 91 128 1
echo "memcheck (model dims) exit: $?"

echo ""
echo "=== VERDICT ==="
echo "CLEAN  -> both runs print '0 errors' : the stray write is NOT in the kernel/copyback;"
echo "          the trigger is the in-model context (multi-rank-per-GPU / front-end), test that next."
echo "ERRORS -> memcheck names an 'Invalid __global__ write' or a bad host copy + the kernel line;"
echo "          that line is the corruption. Fix it in the dsg-atom fork, relink, revalidate."
