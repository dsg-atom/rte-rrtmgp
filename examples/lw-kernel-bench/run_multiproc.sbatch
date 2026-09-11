#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Multi-process GPU-sharing probe for the in-model crash.
#
# memcheck cleared the kernel: no out-of-bounds access at model dims. So the corruption is
# triggered by the in-model CONTEXT, not the kernel math. The distinctive in-model condition is
# 12 MPI ranks sharing ONE A100 (gpu_wrap pins localrank%4, no MPS -> 12 processes time-slice each
# GPU context). The single-process bench never exercises that.
#
# This launches N copies of the SAME lw_cwrap binary concurrently, ALL pinned to GPU 0, at model
# dims, then checks:
#   - did any copy crash (non-zero exit)?
#   - do all copies print the SAME flux sums as a solo (baseline) run?
# A crash or a disagreeing sum = the GPU-sharing condition reproduces the fault, cheaply, on one
# GPU in seconds -- no full-model run needed.
#
# Prereq: ../../build/librtekernels.so must already exist.
# Submit:  sbatch run_multiproc.sbatch
# ------------------------------------------------------------------------------------------------
#SBATCH --job-name=lw_multiproc
#SBATCH --partition=gpu_a100
#SBATCH --constraint=rome
#SBATCH --gres=gpu:1
#SBATCH --account=ilab
#SBATCH --time=00:20:00
#SBATCH --output=lw_multiproc.%j.out

set -e
cd "$SLURM_SUBMIT_DIR"

NVLIB=/usr/local/other/nvidia/hpc_sdk/Linux_x86_64/24.7/compilers/lib
SO_DIR=$(cd ../../build && pwd)
NPROC=12                 # match ranks-per-A100 in the model (localrank%4 over 48 ranks)
DIMS="2048 91 128 1"     # model dims: nlay=91, ngpt=128, nmus=1

ls -l "$SO_DIR/librtekernels.so"
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
module load comp/gcc/12.3.0 comp/intel/2024.2.0

echo "=== compile + link the ifort caller against the nvfortran .so ==="
ifort -diag-disable=10448 -c lw_solver_cwrap_ifort.f90
ifort -diag-disable=10448 lw_solver_cwrap_ifort.o -o lw_cwrap \
      -L"$SO_DIR" -lrtekernels \
      -Wl,-rpath,"$SO_DIR" -Wl,-rpath,"$NVLIB" -L"$NVLIB"

export CUDA_VISIBLE_DEVICES=0   # force every process onto the SAME physical GPU

echo ""
echo "=== baseline: ONE process alone on the GPU ==="
./lw_cwrap $DIMS > solo.out 2>&1
echo "solo exit: $?"
grep -iE 'sum|nan|inf|error' solo.out || true

echo ""
echo "=== $NPROC processes concurrently, ALL on GPU 0 (mimics 12 ranks/A100) ==="
pids=""
for i in $(seq 1 $NPROC); do
  ./lw_cwrap $DIMS > proc_$i.out 2>&1 &
  pids="$pids $!"
done
fail=0
i=0
for p in $pids; do
  i=$((i+1))
  if wait "$p"; then :; else echo "proc $i CRASHED (exit $?)"; fail=1; fi
done
echo "concurrent launches done; crash flag=$fail"

echo ""
echo "=== compare every concurrent proc's sums against the solo baseline ==="
solo_sums=$(grep -iE 'sum' solo.out | tr -s ' ')
mismatch=0
for i in $(seq 1 $NPROC); do
  this=$(grep -iE 'sum' proc_$i.out | tr -s ' ')
  if [ "$this" != "$solo_sums" ]; then
    echo "proc $i SUMS DIFFER from solo:"; echo "  solo: $solo_sums"; echo "  proc: $this"
    mismatch=1
  fi
  grep -iE 'nan|inf|error|fault|invalid' proc_$i.out && echo "  ^ proc $i above" || true
done

echo ""
echo "=== VERDICT ==="
if [ "$fail" = 0 ] && [ "$mismatch" = 0 ]; then
  echo "CLEAN: $NPROC processes shared GPU 0 with no crash and identical sums."
  echo "  -> GPU context-sharing alone does NOT reproduce it; look at the front-end integration next."
else
  echo "REPRODUCED: sharing one A100 across $NPROC processes crashes or corrupts the LW result."
  echo "  -> the fix is in how the model drives the GPU under rank-sharing (MPS / 1 rank-per-GPU / serialize)."
fi
