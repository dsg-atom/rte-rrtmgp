# Where the time goes, and whether it changes at production size

## Why we measured again
We had one measurement of how GEOS spends its time, taken at a coarse grid
(C180). It said radiation was the largest part, about a third of the run, which
is why radiation is the piece we are porting. The open question was whether that
still holds at the finer grid the model actually runs at for production work
(C360). If radiation shrank there, we would be porting the wrong thing.

We ran one model day at each size and read the model's own built-in timers.

To make the two runs comparable we gave each processor the same amount of
atmosphere to work on — 1,620 grid cells each, which meant 120 processors at
C180 and 480 at C360. That matters: the model's setup script would have used
5,400 processors at C360, and with that little work per processor the shares
shift for reasons that have nothing to do with the grid.

## What we found

| Part of the model | C180 | C360 |
|---|---|---|
| Radiation | 33% | **27%** |
| Dynamics | 17% | **23%** |
| Moisture | 18% | 18% |
| Everything else | 32% | 32% |

Radiation's share dropped by six points. Dynamics gained six. Everything else
held.

Three things follow.

**Radiation is still the right thing to port.** It is still the largest part with
no GPU version at all. Moisture is second at 18%, and it is already partly
ported. Dynamics is now nearly as large as radiation, but dynamics already runs
on the GPU, so it is not a target — it is a warning, which we come back to below.

**Radiation did not get cheaper.** Its share fell, but the actual time it takes
barely moved: 472 seconds at C180, 480 seconds at C360. The share fell because
the rest of the run got slower, not because radiation improved. The amount of
time we can win back by porting it is the same at both sizes.

**The reason the rest got slower is dynamics.** The finer grid takes more, shorter
steps — 384 a day instead of 288. Everything that runs every step got called a
third more often. On top of that, each individual dynamics step got 30% more
expensive, because at C360 the calculation spans four machines instead of fitting
inside one, and the machines have to exchange edge data over the network.

## What this changes for the plan

**The overall target is unchanged.** Radiation, dynamics and moisture together are
67% of the run at C180 and 67% at C360. The estimate in
`SPEEDUP_IN_CONTEXT.md` — two to three times faster if all three run on the GPU
with the data staying there — holds at production size.

**The ceiling for radiation alone is slightly lower.** At C180, making radiation
free would have made the whole run about 1.5 times faster. At C360 it is about
1.4 times. This does not change the argument, because radiation alone was never
the plan.

**The case for keeping data on the GPU gets stronger, not weaker.** Dynamics
copies its whole state onto the GPU and back every step. At C360 that happens 384
times a day instead of 288, and each step is more expensive. The finer the grid,
the more often we pay that cost, so the more there is to save by not paying it.

## One detail that affects the design

Radiation does not run every step. It runs once an hour — 24 times a day — while
dynamics and moisture run 384 times. So the sequence we want to wrap in
`KEEPING_DATA_ON_GPU.md` is really two sequences: dynamics and moisture together
on every step, and radiation joining them on one step in sixteen.

This is worth knowing before building the wrap. Holding radiation's data on the
GPU between hourly calls means keeping memory occupied for fifteen steps where
nothing reads it. Whether that is the right trade, or whether radiation's data
should be loaded when it is needed, is a design question we should settle rather
than discover.

## A second finding worth acting on

Moisture is unevenly loaded. Across the 480 processors at C360, the fastest spent
242 seconds on moisture and the slowest spent 424 — a difference of nearly a
factor of two. Longwave radiation shows the same pattern more mildly, 151 to 227
seconds.

The cause is straightforward: clouds and convection happen in some places and not
others, so some processors have far more to compute. It matters because every
processor waits for the slowest one. A GPU version of moisture would be judged
against its worst processor, not its average. And the imbalance is worth fixing
on its own, whether or not moisture moves to the GPU.

## What these numbers are not

- **Neither run used a GPU.** The model executable on the machine has no GPU code
  compiled into it. These are the speeds to beat, not GPU results.
- **They are one model day each,** in May, at one time of year. Cloud amount
  varies by season and location, so the moisture and radiation shares will move
  somewhat with the date.
- **The C180 column is a fresh run,** not the one from earlier in August. The two
  agree within half a percentage point on everything except writing output to
  disk, which varies with where in the month the day falls.
