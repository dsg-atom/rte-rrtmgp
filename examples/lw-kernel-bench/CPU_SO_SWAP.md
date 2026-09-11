# CPU-math .so swap — bisecting the in-model GPU crash without a GPU queue wait

The running GPU `GEOSgcm.x` crashes at the first longwave step ("Areas do not add to 1" →
Infinity). The isolated solver, its copyback, every block/width pattern, and the build flags are
all proven clean. The fault only appears inside the full model. This test splits the remaining
space in two, and runs on the **fast compute partition** (no `gpu_a100` wait).

## What it does

Rebuild `librtekernels.so` so the shim `rte_lw_solver_noscat_gpu` forwards to the **CPU**
`lw_solver_noscat` instead of the GPU-offloaded one. Everything else stays identical: same
compiler (nvfortran), same runtime ABI, same soname, same entry symbol. The only change is: no
device offload, CPU math. Swap it under the *unchanged* GPU executable and run.

- **Crashes the same way** → the offload is **not** the cause. The fault is in the calling glue /
  ABI / copy temporaries / front-end drive / MAPL context. Keep narrowing — no GPU slot needed.
- **Runs clean** → the fault **is** the device offload. The in-model `compute-sanitizer` memcheck
  is then worth its queue cost.

## Step 1 — build the CPU-math .so (login node is fine; it's 6 small files, not a GEOS build)

```
cd <rte-rrtmgp fork>/examples/lw-kernel-bench
./build_cpu_so.sh
```

Produces `./cpu_so/librtekernels.so` and prints a symbol report. Confirm the report shows
`rte_lw_solver_noscat_gpu` as **T** (defined) and "none -- good, pure host" for device deps.

## Step 2 — find how the exe resolves the .so (decides the swap mechanism)

```
cd <your gpu_c180_L91 run dir>
ldd GEOSgcm.x | grep rtekernels          # note the resolved path of the accel librtekernels.so
readelf -d GEOSgcm.x | grep -E 'RPATH|RUNPATH'
```

- If it prints **RUNPATH** → `LD_LIBRARY_PATH` overrides it. Use Step 3a.
- If it prints **RPATH** (or nothing) → `LD_LIBRARY_PATH` will *not* win; do the in-place file
  swap. Use Step 3b.

Paste both outputs back before running so we pick the right path.

## Step 3a — override via LD_LIBRARY_PATH (RUNPATH case)

In the run script (`gcm_run.j` / the launch wrapper), before the `GEOSgcm.x` launch:

```
export LD_LIBRARY_PATH=<abs path>/cpu_so:$LD_LIBRARY_PATH
```

Keep the nvhpc module loaded / its lib dir on the path exactly as the current GPU run does — the
CPU .so still links the nvfortran runtime.

## Step 3b — in-place file swap (RPATH case; the .so is a build artifact, safe to swap)

```
SO=<resolved path from ldd>                 # e.g. .../librtekernels.so
cp -a "$SO" "$SO.accel.bak"                  # back up the GPU .so
cp -a <abs path>/cpu_so/librtekernels.so "$SO"
ldd GEOSgcm.x | grep rtekernels             # confirm it still resolves
```

Restore afterward with `cp -a "$SO.accel.bak" "$SO"`.

## Step 4 — run on the fast partition

Submit the existing 3-hr segment on the fast compute partition (not `gpu_a100`). No relink, no
GEOSgcm rebuild. Watch `gcm_run.o*` for the first longwave step:

- reaches it and continues past the first radiation step → **CLEAN** → offload is the culprit.
- "Areas do not add to 1" / Infinity at the same place → crash reproduced with CPU math → the
  offload is exonerated; the fault is in the glue/ABI/front-end/context.

Restore the accel .so (Step 3b) or drop the `LD_LIBRARY_PATH` line (Step 3a) when done.
