#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Run the BLOCKED-pattern reproducer under compute-sanitizer memcheck.
#
# This is the one call pattern nothing has tested: the model drives the LW solver on blocks of
# RRTMGP_LW_BLOCKSIZE=4 columns (GEOS_IrradGridComp.F90:3922-3924), looping ceil(ncol/4) blocks
# per flavor into one big host flux array, and the FINAL block is partial (1/2/3 columns) whenever
# a rank's column count is not a multiple of 4. Every earlier test used width 4 or 2048 in a single
# call. See lw_blocked_test.f90 for the full rationale.
#
# memcheck catches an out-of-bounds device write inside any block; the sentinel guard band catches
# a device->host copyback that overflows its (colS:colE) slice into neighbouring columns -- which is
# exactly the in-model "Areas do not add to 1" host stomp.
#
# Prereq: ../../build/librtekernels.so must already exist.
# Submit:  sbatch run_blocked_test.sbatch
# ------------------------------------------------------------------------------------------------
#SBATCH --job-name=lw_blocked
#SBATCH --partition=gpu_a100
#SBATCH --constraint=rome
#SBATCH --gres=gpu:1
#SBATCH --account=ilab
#SBATCH --time=00:25:00
#SBATCH --output=lw_blocked.%j.out

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
ifort -diag-disable=10448 -c lw_blocked_test.f90
ifort -diag-disable=10448 lw_blocked_test.o -o lw_blocked \
      -L"$SO_DIR" -lrtekernels \
      -Wl,-rpath,"$SO_DIR" -Wl,-rpath,"$NVLIB" -L"$NVLIB"

export CUDA_LAUNCH_BLOCKING=1

echo ""
echo "############################################################"
echo "### (A) tiny ncol = the partial-block widths in isolation"
echo "###     ncol=1,2,3 -> a SINGLE call at each sub-4 width"
echo "############################################################"
for n in 1 2 3; do
  echo "--- ncol=$n (one block, width $n) ---"
  compute-sanitizer --tool memcheck --print-limit 20 ./lw_blocked $n 91 128 4
  echo "memcheck (ncol=$n) exit: $?"
done

echo ""
echo "############################################################"
echo "### (B) model-scale blocked loop WITH a partial final block"
echo "###     ncol=4093 -> 1024 blocks of 4, last block = 1 column"
echo "###     exercises thousands of back-to-back calls + the copyback"
echo "###     into non-contiguous 4-wide slices + the partial tail"
echo "############################################################"
compute-sanitizer --tool memcheck --print-limit 20 ./lw_blocked 4093 91 128 4
echo "memcheck (blocked, partial tail) exit: $?"

echo ""
echo "############################################################"
echo "### (C) exact-multiple control: ncol=4096 -> 1024 full blocks"
echo "###     same call count, NO partial tail. If (B) stomps but (C)"
echo "###     is clean, the partial final block is the trigger."
echo "############################################################"
compute-sanitizer --tool memcheck --print-limit 20 ./lw_blocked 4096 91 128 4
echo "memcheck (blocked, no tail) exit: $?"

echo ""
echo "=== VERDICT ==="
echo "'Invalid __global__ write' at any width       -> OOB device write (kernel line named)."
echo "'BLOCKED STOMP' in (A) at ncol=1/2/3          -> the partial final block is the bug."
echo "'BLOCKED STOMP' in (B) but CLEAN in (A)+(C)    -> the partial TAIL after many blocks is the bug."
echo "'BLOCKED STOMP' in (B) AND (C)                 -> thousands of back-to-back calls corrupt (alloc churn)."
echo "all CLEAN everywhere                           -> the .so is clean even for the exact blocked+partial"
echo "                                                  pattern; the stomp is in host glue / runtime, not the kernel."
