#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Build an IFORT (Intel) CPU-MATH drop-in for librtekernels.so, to split the two remaining
# suspects for the in-model GPU crash -- WITHOUT a gpu_a100 queue wait.
#
# Background. The nvfortran CPU-math .so (build_cpu_so.sh) already reproduced the crash exactly
# under the unchanged GPU GEOSgcm.x. That exonerated the device offload: the GPU kernel and its
# OpenACC copies never ran, yet the corruption ("Areas do not add to 1" -> Infinity) was
# identical. Two suspects remain, both host-side and both present ONLY in the GPU build:
#   H1  the bind(C) call path itself -- the #ifdef RTE_LW_GPU_OFFLOAD redirect in mo_rte_lw.F90,
#       the copy-in/out temporaries, the argument marshalling into the .so entry.
#   H2  the nvhpc runtime PRESENCE -- loading a second OpenMP runtime (libnvomp) alongside the
#       exe's own Intel libiomp5, and the nvhpc allocator, independent of any offload.
#
# This .so is the discriminator. It compiles the SAME shim + SAME CPU kernels + SAME bind(C)
# entry symbol (rte_lw_solver_noscat_gpu) -- but with IFORT, so it links the Intel runtime and
# pulls NO nvhpc runtime at all. readelf on the exe confirmed the exe's own NEEDED list has
# libiomp5 (Intel OpenMP) but none of libnvf/libnvomp/libacchost -- those enter the process
# ONLY through librtekernels.so. So swapping in this ifort .so removes the entire nvhpc runtime
# and leaves a single (Intel) OpenMP runtime loaded.
#
# Swap it under the unchanged GPU GEOSgcm.x (same mechanism as the nvfortran CPU .so) and run on
# the FAST compute partition:
#   * crashes the SAME way  -> H2 is out; the fault is the bind(C) call path / copy temporaries /
#                              marshalling (H1). Debug the front-end drive path -- no GPU needed.
#   * runs CLEAN            -> H1 is out; the fault is the nvhpc-runtime presence (H2, e.g. the
#                              dual-OpenMP libnvomp+libiomp5 or the nvhpc allocator).
#
# This compiles 6 small Fortran files -- it is NOT a GEOS build; a login node is fine.
#
# IMPORTANT -- match the exe's Intel runtime. The GPU GEOSgcm.x was built with GEOS's Intel
# toolchain. To keep the runtime ABI identical, build this .so with the SAME Intel module the
# GEOS build loaded (its g5_modules / the module set used for build-gpu/). Point IFORT_MODULE at
# it, or (cleaner) source the GEOS build's module file before running this script so `ifort` and
# its runtime match. At RUN time no extra module is needed: the exe already links libiomp5 /
# libifcore / libintlc, so this .so's Intel runtime deps are already resolved in the run env.
#
# Usage:  [IFORT_MODULE=<intel module>] ./build_cpu_so_ifort.sh  [OUTDIR]   (default OUTDIR=./cpu_so_ifort)
# Output: $OUTDIR/librtekernels.so  (Intel CPU-math), plus a symbol + NEEDED report.
# ------------------------------------------------------------------------------------------------
set -euo pipefail

OUTDIR="${1:-$(pwd)/cpu_so_ifort}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # rte-rrtmgp repo root
RTEK="$ROOT/rte-kernels"
FRONT="$ROOT/rte-frontend"

echo "repo root : $ROOT"
echo "output    : $OUTDIR"
mkdir -p "$OUTDIR"

# --- environment: the SAME Intel toolchain the GPU GEOSgcm.x was built with ---------------------
# If IFORT_MODULE is set, load it. Otherwise assume `ifort` is already on PATH (e.g. you sourced
# the GEOS build's module file first). Either way we print the version so you can confirm it
# matches the exe's Intel runtime.
if [ -n "${IFORT_MODULE:-}" ]; then
  echo "loading module: $IFORT_MODULE"
  module load "$IFORT_MODULE"
fi
command -v ifort >/dev/null 2>&1 || { echo "ERROR: ifort not on PATH. Set IFORT_MODULE or source the GEOS build module file first."; exit 1; }
which ifort
ifort --version | head -1

# --- compile order follows the use-graph; CPU kernels (top-level), plain host -------------------
# mo_rte_kind -> mo_rte_util_array -> mo_rte_solver_kernels(CPU) -> mo_optical_props_kernels(CPU)
# -> mo_fluxes_broadband_kernels -> lw_solver_noscat_gpu(shim)
FC=ifort
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
echo "=== compile (ifort, plain host) ==="
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
echo "=== NEEDED libraries -- expect Intel runtime (libifcore/libintlc/libsvml/libimf), and"
echo "    CRITICALLY no nvhpc runtime (no libnvf/libnvomp/libnvcpumath/libacchost) ==="
readelf -d "$OUTDIR/librtekernels.so" | grep NEEDED || true
echo "--- any nvhpc / cuda / acc deps? (expect NONE) ---"
readelf -d "$OUTDIR/librtekernels.so" | grep NEEDED | grep -iE 'nv|cuda|acc' && \
  echo "  ^ UNEXPECTED nvhpc/cuda dep -- this would defeat the test" || echo "  none -- good, no nvhpc runtime."
echo "--- any cuda/acc-device undefined symbols? (expect NONE) ---"
nm -D -u "$OUTDIR/librtekernels.so" | grep -iE 'cuda|acc_|__pgi.*device' && \
  echo "  ^ unexpected device deps" || echo "  none -- good, pure host."

echo ""
echo "DONE. Intel CPU-math drop-in: $OUTDIR/librtekernels.so"
echo "Next: point LD_LIBRARY_PATH at this OUTDIR (ahead of the accel build dir) under the"
echo "      unchanged GPU GEOSgcm.x, and run on the fast compute partition."
