#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Standalone cross-compiler proof: ifort caller -> rte_lw_solver_noscat in the nvfortran .so.
# Builds lw_solver_cwrap_ifort.f90 with ifort, links librtekernels.so (from ../../build, produced
# by the step-1 nvfortran shared-lib build), runs on one A100, and prints the flux checksums to
# compare against the recorded nvfortran reference.
#
# Prereq: ../../build/librtekernels.so must already exist (nvfortran -O3 -acc -gpu=cc80 -shared).
# Submit:  sbatch run_cwrap_test.sbatch
# ------------------------------------------------------------------------------------------------
#SBATCH --job-name=lw_cwrap
#SBATCH --partition=gpu_a100
#SBATCH --constraint=rome
#SBATCH --gres=gpu:1
#SBATCH --account=ilab
#SBATCH --time=00:10:00
#SBATCH --output=lw_cwrap.%j.out

set -e
cd "$SLURM_SUBMIT_DIR"

NVLIB=/usr/local/other/nvidia/hpc_sdk/Linux_x86_64/24.7/compilers/lib
SO_DIR=$(cd ../../build && pwd)

echo "=== prebuilt GPU kernel .so present? ==="
ls -l "$SO_DIR/librtekernels.so"

echo "=== load toolchain: nvhpc runtime (for the .so's CUDA/acc libs) + Intel (for ifort) ==="
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
module load comp/gcc/12.3.0 comp/intel/2024.2.0
which ifort

echo "=== compile the ifort caller ==="
ifort -diag-disable=10448 -c lw_solver_cwrap_ifort.f90

echo "=== link against the nvfortran .so (ifort drives the host link) ==="
ifort -diag-disable=10448 lw_solver_cwrap_ifort.o -o lw_cwrap \
      -L"$SO_DIR" -lrtekernels \
      -Wl,-rpath,"$SO_DIR" -Wl,-rpath,"$NVLIB" -L"$NVLIB"
echo "link exit: $?"

echo "=== resolved libraries (want librtekernels.so + nv/acc/cuda runtime) ==="
ldd lw_cwrap | grep -iE 'rtekernels|nv|acc|cuda' || true

echo "=== run on the A100 ==="
./lw_cwrap 1024 72 256 1
echo "run exit: $?"

echo "=== VERDICT: the two printed sums must equal 6.80340094E+07 and 1.31914742E+05 ==="
