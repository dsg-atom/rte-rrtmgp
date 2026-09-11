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
echo "### (1) do_broadband=1, NON-CONTIGUOUS section targets, model dims, do_rescaling=0"
echo "############################################################"
compute-sanitizer --tool memcheck --print-limit 20 ./lw_bband 2048 91 128 1 1 0
echo "memcheck (non-contiguous) exit: $?"

echo ""
echo "############################################################"
echo "### (2) GEOS EXACT PATH: do_broadband=1, NON-CONTIGUOUS, do_rescaling=1"
echo "###     ty_optical_props_2str + use_2stream=.false. -> the rescaling branch"
echo "###     (mo_rte_lw.F90:461-472). Reads ssa/g on the device -- ssa has NO copyin"
echo "###     in the kernel (mo_rte_solver_kernels.F90:141 maps g only) -- and runs"
echo "###     lw_transport_1rescl. Nothing has ever exercised this path."
echo "############################################################"
compute-sanitizer --tool memcheck --print-limit 20 ./lw_bband 2048 91 128 1 1 1
echo "memcheck (rescaling) exit: $?"

echo ""
echo "=== VERDICT ==="
echo "memcheck 'Invalid __global__ read'  in run (2) -> ssa read on the device with no copyin"
echo "                                                  (mo_rte_solver_kernels.F90:157); that is the fix."
echo "memcheck 'Invalid __global__ write' in any run -> OOB in the device path (kernel line named)."
echo "'GUARD STOMPED' in run (1) or (2)              -> copyback overflows the non-contiguous target."
echo "all CLEAN + GUARD CLEAN                         -> rescaling path is clean too; widen further."
