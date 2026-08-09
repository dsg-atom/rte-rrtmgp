#!/usr/bin/env make
#
# Standalone LW-solver kernel micro-benchmark.
# Links ONLY librtekernels.a -- no frontend, no gas optics, no netCDF.
#
# FC and FCFLAGS must be set in the environment and must MATCH the flags used to build
# the kernel archive (so directives + module ABI agree). Example:
#   CPU  : export FC=nvfortran FCFLAGS='-O3'
#   accel: export FC=nvfortran FCFLAGS='-O3 -acc -gpu=cc80'
#
# The kernel archive is built separately in ../../build, e.g.:
#   make -C ../../build librtekernels.a                    # CPU
#   RTE_KERNELS=accel make -C ../../build librtekernels.a   # accel (with accel FCFLAGS)
#
BENCH_ROOT = ../..
BUILD      = $(BENCH_ROOT)/build

FCINCLUDE += -I$(BUILD)

lw_solver_bench: lw_solver_bench.F90
	$(FC) $(FCFLAGS) $(FCINCLUDE) $< -o $@ -L$(BUILD) -lrtekernels

clean:
	rm -f lw_solver_bench *.o *.mod
