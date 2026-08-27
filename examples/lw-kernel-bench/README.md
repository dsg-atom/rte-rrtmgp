# Longwave solver GPU benchmark, and the notes around it

## What's here

`lw_solver_bench.F90` is a standalone benchmark for the longwave radiation
solver — the part of GEOS that works out how heat radiation moves up and down
through the atmosphere. It runs the same calculation on a regular processor and
on a GPU and compares both the speed and the answers. It needs no input files and
no netCDF library, so it can be built and run on its own. Build it with the
`Makefile` here.

Result: on an A100 GPU the solver runs 40 to 60 times faster than on a single
processor core, and both versions produce identical answers.

The notes below explain what that result is worth, and what would have to be
built to turn it into a faster GEOS.

## The notes, in reading order

Each one answers a single question and can be read on its own. In order, they run
from "is this worth doing" to "here is the work."

**1. [Is the speedup worth anything?](SPEEDUP_IN_CONTEXT.md)**
What a 40–60× faster solver does to a full GEOS run. Short answer: very little by
itself, because radiation is only part of the run and the cost of moving data to
the GPU eats most of the gain. Sets out the design rule the rest of the project
follows — keep the data on the GPU.

**2. [Where does the time actually go?](WHERE_THE_TIME_GOES.md)**
Measured timings for every part of the model, at a coarse grid and at the finer
grid used for production work. Confirms radiation is the right thing to port, and
explains why its share of the run drops at the finer grid without radiation
getting any cheaper.

**3. [Should we build on the ESM team's GPU code?](BUILD_ON_ESM_GPU_CODE.md)**
Reuse their existing GPU dynamics and moisture code, or write our own? Reuse — the
problem we need to solve is not in the math, and rewriting the math would leave us
with the same problem at the end. Includes what we found when we traced why the
missing piece was never built.

**4. [What would it take to keep the data on the GPU?](KEEPING_DATA_ON_GPU.md)**
The implementation plan: six steps from easiest to hardest, what already exists
versus what we would add, the two main risks, and the smallest first step worth
prototyping.

## If you only read one

Start with **1**. It frames the whole problem in a page. Read **4** if you are
going to build any of this.
