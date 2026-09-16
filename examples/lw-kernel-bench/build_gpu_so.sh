#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Build the OFFLOAD (GPU) librtekernels.so as a standalone swap-in, the accel twin of
# build_cpu_so.sh. Same shim, same soname, same exported entry symbol (rte_lw_solver_noscat_gpu),
# same nvhpc -- the ONLY difference from build_cpu_so.sh is that this compiles the ACCEL kernels
# with -acc -gpu=cc80, so lw_solver_noscat runs on the device.
#
# Why this exists: the in-model offload crash (22:00 seg1, "Areas do not add to 1" -> Infinity)
# has to be re-tested against the confirmed nvfortran -O3 auto-vectorizer bug. The CPU-side bug
# lives in the TOP-LEVEL mo_rte_solver_kernels.F90 (a vectorized store through a target+pointer
# alias in lw_source_noscat). The ACCEL lw_source_noscat is a scalar `!$acc routine seq` and does
# NOT contain that construct -- so the device kernel itself is clean. But the accel file's HOST
# driver code (lw_solver_noscat driver, data-clause setup) is still nvfortran -O3 host code that
# could be miscompiled by the same vectorizer. This script lets us swap in an offload .so with
# -Mnovect added (EXTRA_FCFLAGS) to test exactly that, without a full GEOS build.
#
# Disciplined use -- build TWO and swap both on gpu_a100:
#   1) CONTROL (plain, must reproduce the 22:00 crash, proving the standalone .so matches the model):
#        ./build_gpu_so.sh $PWD/gpu_so
#   2) TEST (-Mnovect; disables the host auto-vectorizer, device codegen unaffected):
#        EXTRA_FCFLAGS="-Mnovect" ./build_gpu_so.sh $PWD/gpu_so_novect
#   Then, under the unchanged GPU GEOSgcm.x on gpu_a100 (real gcm_run.j, --gres=gpu:4), swap each
#   in via the launch wrapper's LD_LIBRARY_PATH (same mechanism as the CPU discriminators):
#     * control crashes 22:00, test runs clean -> the offload crash IS a host-vectorizer bug in
#       the accel driver; narrow it in source (or ship -Mnovect on the offload build).
#     * both crash                             -> the fault is device-side; run compute-sanitizer
#       memcheck on the offload .so to localize it.
#     * control does NOT crash                 -> the standalone .so does not match the model's
#       CMake-built .so; do not trust the test -- fall back to adding -Mnovect in the build-gpu
#       CMake Fortran flags and rebuilding the rtekernels target.
#
# Compiling -acc -gpu=cc80 does NOT need a GPU (only nvfortran) -- a login node is fine for this
# 6-file build. Only RUNNING the result needs gpu_a100.
#
# Usage:  [OPT=-O3] [EXTRA_FCFLAGS="..."] ./build_gpu_so.sh  [OUTDIR]   (default OUTDIR=./gpu_so)
# Output: $OUTDIR/librtekernels.so  (offload), plus a symbol + NEEDED report.
# ------------------------------------------------------------------------------------------------
set -euo pipefail

OUTDIR="${1:-$(pwd)/gpu_so}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # rte-rrtmgp repo root
RTEK="$ROOT/rte-kernels"
FRONT="$ROOT/rte-frontend"

echo "repo root : $ROOT"
echo "output    : $OUTDIR"
mkdir -p "$OUTDIR"

# --- environment: same nvhpc the model's accel .so was built with (24.7) -------------------------
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
which nvfortran
nvfortran --version | head -1

# --- flags: OFFLOAD. OPT holds the opt level (default -O3); ACC holds the device flags;
#     EXTRA_FCFLAGS appends (e.g. -Mnovect to kill the host auto-vectorizer, or -Minfo=accel).
#     Keep the opt level in OPT, NOT in EXTRA_FCFLAGS -- see the -Mvect note in build_cpu_so.sh.
FC=nvfortran
OPT="${OPT:--O3}"
ACC="-acc -gpu=cc80"
FCFLAGS="$OPT $ACC -fPIC ${EXTRA_FCFLAGS:-}"
MODOUT="-module $OUTDIR"

# Compile order follows the use-graph. Accel twins of solver + optical_props; util_array and
# fluxes have no accel variant (top-level, compiled -acc so any !$acc in them is honored) -- this
# mirrors what the RTE_KERNELS=accel CMake build selects.
#   mo_rte_kind -> mo_rte_util_array -> mo_rte_solver_kernels(ACCEL) -> mo_optical_props(ACCEL)
#   -> mo_fluxes_broadband_kernels -> lw_solver_noscat_gpu(shim)
SRCS=(
  "$FRONT/mo_rte_kind.F90"
  "$RTEK/mo_rte_util_array.F90"
  "$RTEK/accel/mo_rte_solver_kernels.F90"    # ACCEL -- !$acc, device lw_solver_noscat
  "$RTEK/accel/mo_optical_props_kernels.F90" # ACCEL
  "$RTEK/mo_fluxes_broadband_kernels.F90"
  "$RTEK/accel/lw_solver_noscat_gpu.F90"     # the shim (unchanged; binds the accel driver)
)

cd "$OUTDIR"
rm -f ./*.o ./*.mod ./librtekernels.so
echo ""
echo "=== compile (nvfortran $FCFLAGS) ==="
for f in "${SRCS[@]}"; do
  echo "  FC $f"
  $FC $FCFLAGS $MODOUT -c "$f"
done

echo ""
echo "=== link -shared -> librtekernels.so (soname matches the model's accel .so) ==="
$FC $FCFLAGS -shared -o librtekernels.so ./*.o -Wl,-soname,librtekernels.so
ls -l "$OUTDIR/librtekernels.so"

echo ""
echo "=== the entry symbol must be DEFINED (T), not undefined (U) ==="
nm -D "$OUTDIR/librtekernels.so" | grep rte_lw_solver_noscat_gpu || { echo "MISSING ENTRY SYMBOL"; exit 1; }

echo ""
echo "=== sanity: this OFFLOAD .so SHOULD pull the CUDA device runtime (unlike the CPU .so) ==="
echo "--- NEEDED libraries ---"
readelf -d "$OUTDIR/librtekernels.so" | grep NEEDED || true
echo "--- device deps present? (expect SOME cuda/acc here -- this is the offload build) ---"
nm -D -u "$OUTDIR/librtekernels.so" | grep -iE 'cuda|acc_|__pgi|nvhpc' | head && \
  echo "  ^ device deps present -- good, this is the offload .so." || \
  echo "  NONE found -- WARNING: this may not actually be an offload build (check -acc)."

echo ""
echo "DONE. Offload drop-in: $OUTDIR/librtekernels.so"
echo "Next: swap under the GPU GEOSgcm.x on gpu_a100 (wrapper LD_LIBRARY_PATH), run the 22:00 step."
