# What the LW-solver GPU speedup means for a full GEOS run

We took one specific piece of GEOS — the part that calculates how heat
radiation moves through the atmosphere — and got it running on a GPU. On the
GPU that piece runs 40 to 60 times faster than it did on a single regular
processor core. This is a measured result, and we confirmed the GPU produces
the same answers as before, so it is fast without being wrong.

But that speedup applies only to that one piece, and that piece is a small
part of the whole program. The radiation calculation is about a third of the
total time GEOS spends running at the coarser grid we first measured, and about
a quarter at the finer grid used for production work. So even if we made
radiation take no time at all, the whole program could only get about one and a
half times faster — nearer 1.4 times at the finer grid. That limit is fixed by
arithmetic: the rest of the run that isn't radiation still has to happen at its
normal speed. (`WHERE_THE_TIME_GOES.md` has both measurements, and explains why
radiation's share fell without radiation getting any cheaper.)

There's a second point that makes the raw number even less impressive on its
own. We reached almost all of that one-and-a-half-times ceiling just by making
radiation about 10 times faster. Pushing it all the way to 60 times barely
changes the overall run. So the 60x figure is real, but it is not the number
that determines how much faster the finished program becomes.

There is also a cost that the 60x figure leaves out. GPUs compute quickly, but
moving data between the main processor and the GPU is slow. If you send the GPU
one small task and wait for the result each time, the time spent moving data
back and forth swamps the time saved. We measured this cost directly, and it is
large: done that way, the 60x advantage drops to roughly 2x. The way to avoid
it is to move a large batch of data onto the GPU once and keep it there across
many calculations, instead of transferring it for every step.

The real benefit therefore does not come from this one piece by itself. The
plan is to move the three largest parts of GEOS onto the GPU together —
radiation, the atmospheric dynamics, and the cloud-and-moisture physics. The
last two are already being ported by the GEOS-ESM team using the GT4Py/NDSL
framework, which builds on earlier GT4Py work in the broader modeling community
(NOAA-GFDL, ETH Zurich's GridTools group, and Ai2, who did the original GT4Py
port of the FV3 dynamical core). Those three parts together are about
two-thirds of the total run — measured at both grid sizes, so this figure holds
at production size. If all three run on the GPU and the data stays
resident on the GPU throughout, so the transfer cost is paid rarely rather than
constantly, the whole program can realistically run two to three times faster.

This piece of work established two things. First, the radiation calculation
runs correctly and efficiently on a GPU with no hidden problems, so it belongs
in the larger effort. Second, it measured the data-transfer cost precisely,
which confirmed the central design rule for the whole project: keep the data on
the GPU rather than moving it back and forth.
