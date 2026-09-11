#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Build a CPU-MATH drop-in for librtekernels.so, to bisect the in-model GPU crash WITHOUT a
# gpu_a100 queue wait.
#
# The idea: the running accel .so and this one are identical in every way that matters to the
# GEOSgcm.x link -- same compiler (nvfortran), same Fortran runtime ABI, same soname
# (librtekernels.so), same exported entry symbol (rte_lw_solver_noscat_gpu). The ONLY difference:
#   accel .so : nvfortran -O3 -acc -gpu=cc80, using rte-kernels/accel/mo_rte_solver_kernels.F90
#               -> the shim forwards to the GPU-offloaded lw_solver_noscat.
#   this  .so : nvfortran -O3 (NO -acc, NO -gpu), using rte-kernels/mo_rte_solver_kernels.F90
#               -> the SAME shim forwards to the plain-host (CPU) lw_solver_noscat.
# The shim (rte-kernels/accel/lw_solver_noscat_gpu.F90) does `use mo_rte_solver_kernels, only:
# lw_solver_noscat` and just passes its arguments through -- it does not care which module
# supplies lw_solver_noscat, so it compiles unchanged against the CPU kernel. The CPU and accel
# lw_solver_noscat have identical bind(C) signatures (verified), so the ABI is unchanged.
#
# Swap this in for the accel .so under the existing GPU GEOSgcm.x (LD_LIBRARY_PATH / file swap;
# see the run instructions) and run on the FAST compute partition:
#   * crashes the SAME way ("Areas do not add to 1" -> Infinity)  -> the GPU offload is NOT the
#     cause; the fault is in the calling glue / ABI / copy temporaries / front-end drive / MAPL
#     context -- and no GPU slot is needed to keep narrowing it.
#   * runs CLEAN                                                   -> the fault IS the device
#     offload; the in-model compute-sanitizer memcheck is then worth its gpu_a100 queue cost.
#
# This compiles 6 small Fortran files -- it is NOT a GEOS build; a login node is fine.
#
# Usage:  ./build_cpu_so.sh  [OUTDIR]      (default OUTDIR=./cpu_so)
# Output: $OUTDIR/librtekernels.so  (CPU-math), plus a symbol report.
# ------------------------------------------------------------------------------------------------
set -euo pipefail

OUTDIR="${1:-$(pwd)/cpu_so}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # rte-rrtmgp repo root
RTEK="$ROOT/rte-kernels"
FRONT="$ROOT/rte-frontend"

echo "repo root : $ROOT"
echo "output    : $OUTDIR"
mkdir -p "$OUTDIR"

# --- environment: same nvhpc the accel .so was built with (24.7) --------------------------------
module purge
module load nvidia/nvhpc-hpcx-cuda12/24.7
which nvfortran
nvfortran --version | head -1

# --- compile order follows the use-graph; CPU kernels (top-level), NO -acc/-gpu ------------------
# mo_rte_kind -> mo_rte_util_array -> mo_rte_solver_kernels(CPU) -> mo_optical_props_kernels(CPU)
# -> mo_fluxes_broadband_kernels -> lw_solver_noscat_gpu(shim)
FC=nvfortran
FCFLAGS="-O3 -fPIC"
MODOUT="-module $OUTDIR"

# The shim lives in accel/ but forwards to whatever mo_rte_solver_kernels module is in scope.
# We compile the CPU mo_rte_solver_kernels FIRST so the shim binds to the CPU lw_solver_noscat.
SRCS=(
  "$FRONT/mo_rte_kind.F90"
  "$RTEK/mo_rte_util_array.F90"
  "$RTEK/mo_rte_solver_kernels.F90"          # CPU (top-level) -- no !$acc
  "$RTEK/mo_optical_props_kernels.F90"       # CPU (top-level)
  "$RTEK/mo_fluxes_broadband_kernels.F90"
  "$RTEK/accel/lw_solver_noscat_gpu.F90"     # the shim (unchanged)
)

cd "$OUTDIR"
rm -f ./*.o ./*.mod ./librtekernels.so
echo ""
echo "=== compile (nvfortran, NO -acc -- pure host) ==="
for f in "${SRCS[@]}"; do
  echo "  FC $f"
  $FC $FCFLAGS $MODOUT -c "$f"
done

echo ""
echo "=== link -shared -> librtekernels.so (soname matches the accel .so) ==="
$FC $FCFLAGS -shared -o librtekernels.so ./*.o -Wl,-soname,librtekernels.so
ls -l "$OUTDIR/librtekernels.so"

echo ""
echo "=== the entry symbol must be DEFINED (T), not undefined (U) ==="
nm -D "$OUTDIR/librtekernels.so" | grep rte_lw_solver_noscat_gpu || { echo "MISSING ENTRY SYMBOL"; exit 1; }

echo ""
echo "=== sanity: this CPU .so should pull NO CUDA device runtime (accel one does) ==="
echo "--- NEEDED libraries ---"
readelf -d "$OUTDIR/librtekernels.so" | grep NEEDED || true
echo "--- any cuda/acc-device undefined symbols? (expect NONE) ---"
nm -D -u "$OUTDIR/librtekernels.so" | grep -iE 'cuda|acc_|__pgi.*device|nvhpc.*device' && \
  echo "  ^ unexpected device deps (would mean this isn't pure host)" || echo "  none -- good, pure host."

echo ""
echo "DONE. CPU-math drop-in: $OUTDIR/librtekernels.so"
echo "Next: back up the accel .so, swap this one in by path, run GEOSgcm.x on the fast partition."
