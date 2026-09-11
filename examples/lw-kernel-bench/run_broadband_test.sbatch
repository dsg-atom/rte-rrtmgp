#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Run the do_broadband=.TRUE. reproducer under compute-sanitizer memcheck.
#
# GEOS always uses do_broadband=.TRUE. with NON-CONTIGUOUS section fluxes; the bench and the
# earlier memcheck run used do_broadband=.FALSE. with contiguous arrays. This exercises the model's
# actual path (see lw_broadband_test.f90) at model dims, in two modes, under memcheck:
#   mode 0 : contiguous broadband targets          -> isolates the broadband device path
#   mode 1 : non-contiguous section targets        -> adds the GEOS-like copyback + guard check
#
# Prereq: ../../build/librtekernels.so must already exist.
# Submit:  sbatch run_broadband_test.sbatch
# ------------------------------------------------------------------------------------------------
#SBATCH --job-name=lw_bband
#SBATCH --partition=gpu_a100
#SBATCH --constraint=rome
#SBATCH --gres=gpu:1
#SBATCH --account=ilab
#SBATCH --time=00:20:00
#SBATCH --output=lw_bband.%j.out

set -e
cd "$SLURM_SUBMIT_DIR"

NVLIB=/usr/local/other/nvidia/hpc_sdk/Linux_x86_64/24.7/compilers/lib
SO_DIR=$(cd ../../build && pwd)

ls -l "$SO_DIR/librtekernels.so"
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
module load comp/gcc/12.3.0 comp/intel/2024.2.0
which ifort
which compute-sanitizer || echo "WARNING: compute-sanitizer not on PATH"

echo "=== compile + link (ifort caller -> nvfortran .so) ==="
ifort -diag-disable=10448 -c lw_broadband_test.f90
ifort -diag-disable=10448 lw_broadband_test.o -o lw_bband \
      -L"$SO_DIR" -lrtekernels \
      -Wl,-rpath,"$SO_DIR" -Wl,-rpath,"$NVLIB" -L"$NVLIB"

export CUDA_LAUNCH_BLOCKING=1
export NVCOMPILER_ACC_NOTIFY=3

echo ""
echo "############################################################"
echo "### (0) do_broadband=1, CONTIGUOUS targets, model dims"
echo "############################################################"
compute-sanitizer --tool memcheck --print-limit 20 ./lw_bband 2048 91 128 1 0
echo "memcheck (contiguous) exit: $?"

echo ""
echo "############################################################"
echo "### (1) do_broadband=1, NON-CONTIGUOUS section targets, model dims"
echo "############################################################"
compute-sanitizer --tool memcheck --print-limit 20 ./lw_bband 2048 91 128 1 1
echo "memcheck (non-contiguous) exit: $?"

echo ""
echo "=== VERDICT ==="
echo "memcheck 'Invalid __global__ write' in either run -> OOB in the broadband device path (kernel line named)."
echo "'GUARD STOMPED' in run (1)             -> device->host copyback overflows the non-contiguous target."
echo "both CLEAN + GUARD CLEAN               -> broadband path is not the corruption; widen the search."
