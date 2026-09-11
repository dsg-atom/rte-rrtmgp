#!/bin/bash
# ------------------------------------------------------------------------------------------------
# The missing combination: 12 ranks sharing ONE A100 while running the MODEL'S ACTUAL LW path.
#
# Two dimensions were tested separately and each came back clean:
#   - run_multiproc.sbatch : 12 processes share GPU 0 -> clean, BUT ran lw_cwrap
#                            (do_broadband=0, do_rescaling=0 -- the cheap path that uses the
#                             caller's flux arrays directly, ~2 GB device working set).
#   - run_broadband_test   : the real path (do_broadband=1, do_rescaling=1) -> clean, BUT one
#                            process alone (only ~2.4 GB, fits the 40 GB card with room to spare).
# Never together. The real path allocates EXTRA device scratch each call (g-point this_flux_up/dn,
# ~390 MB on top of the ~2 GB), so 12 ranks running the REAL path at once is a much larger peak
# than the 12-way lw_cwrap test ever produced. If a device allocation quietly fails under that
# pressure and the kernel copies garbage back, it lands in HOST memory as corruption -- which is
# exactly the in-model symptom ("Areas do not add to 1"), fires when all 12 ranks hit the GPU at
# the first longwave step, and is invisible to the CPU (no device memory) and to a single-process
# test (fits easily).
#
# This launches NPROC copies of lw_bband on the GEOS-exact path (mode 1, do_rescaling 1), ALL on
# GPU 0, samples GPU memory during the run, and checks for any crash or disagreeing sum.
#
# Prereq: ../../build/librtekernels.so must already exist.
# Submit:  sbatch run_multiproc_bband.sbatch
# ------------------------------------------------------------------------------------------------
#SBATCH --job-name=lw_mp_bband
#SBATCH --partition=gpu_a100
#SBATCH --constraint=rome
#SBATCH --gres=gpu:1
#SBATCH --account=ilab
#SBATCH --time=00:20:00
#SBATCH --output=lw_mp_bband.%j.out

set -e
cd "$SLURM_SUBMIT_DIR"

NVLIB=/usr/local/other/nvidia/hpc_sdk/Linux_x86_64/24.7/compilers/lib
SO_DIR=$(cd ../../build && pwd)
NPROC=12                    # match ranks-per-A100 in the model (localrank%4 over 48 ranks)
ARGS="2048 91 128 1 1 1"    # model dims; mode 1 (non-contiguous); do_rescaling 1 == GEOS's real path

ls -l "$SO_DIR/librtekernels.so"
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
module load comp/gcc/12.3.0 comp/intel/2024.2.0

echo "=== compile + link the ifort caller against the nvfortran .so ==="
ifort -diag-disable=10448 -c lw_broadband_test.f90
ifort -diag-disable=10448 lw_broadband_test.o -o lw_bband \
      -L"$SO_DIR" -lrtekernels \
      -Wl,-rpath,"$SO_DIR" -Wl,-rpath,"$NVLIB" -L"$NVLIB"

export CUDA_VISIBLE_DEVICES=0   # force every process onto the SAME physical GPU

echo ""
echo "=== card memory before any launch ==="
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv

echo ""
echo "=== baseline: ONE process alone on the real path ==="
./lw_bband $ARGS > solo.out 2>&1
echo "solo exit: $?"
grep -iE 'sum|nan|inf|error|guard' solo.out || true

echo ""
echo "=== $NPROC processes concurrently, ALL on GPU 0, real path ==="
# sample GPU memory every 0.2 s while the 12 run, so a near-40-GB peak is visible
( for k in $(seq 1 100); do
    nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits
    sleep 0.2
  done ) > gpu_mem_samples.txt 2>&1 &
sampler=$!

pids=""
for i in $(seq 1 $NPROC); do
  ./lw_bband $ARGS > proc_$i.out 2>&1 &
  pids="$pids $!"
done
fail=0
i=0
for p in $pids; do
  i=$((i+1))
  if wait "$p"; then :; else echo "proc $i CRASHED (exit $?)"; fail=1; fi
done
kill "$sampler" 2>/dev/null || true
echo "concurrent launches done; crash flag=$fail"

echo ""
echo "=== peak GPU memory used during the concurrent run (MiB) ==="
sort -t, -k1 -n gpu_mem_samples.txt | tail -1
echo "(total card is 40960 MiB; a value near that = the real path exhausts the card under 12-way sharing)"

echo ""
echo "=== compare every concurrent proc against the solo baseline ==="
solo_sums=$(grep -iE 'sum|guard' solo.out | tr -s ' ')
mismatch=0
for i in $(seq 1 $NPROC); do
  this=$(grep -iE 'sum|guard' proc_$i.out | tr -s ' ')
  if [ "$this" != "$solo_sums" ]; then
    echo "proc $i DIFFERS from solo:"; echo "  solo: $solo_sums"; echo "  proc: $this"
    mismatch=1
  fi
  grep -iE 'nan|inf|error|fault|invalid|stomped' proc_$i.out && echo "  ^ proc $i above" || true
done

echo ""
echo "=== VERDICT ==="
if [ "$fail" = 0 ] && [ "$mismatch" = 0 ]; then
  echo "CLEAN: $NPROC processes ran the real LW path on one A100 with no crash and identical sums."
  echo "  -> device memory pressure under 12-way sharing is NOT the trigger; the fault is in the"
  echo "     full-model host glue (front-end reductions / four sequential calls / MAPL context)."
else
  echo "REPRODUCED: 12-way sharing of the REAL path crashes or corrupts the result."
  echo "  -> device memory pressure / failed device alloc under rank-sharing is the trigger."
  echo "     Fix: enable NVIDIA MPS, or fewer ranks per GPU, or serialize LW, or shrink the"
  echo "     per-call device footprint. Check the peak-memory line above against 40960 MiB."
fi
