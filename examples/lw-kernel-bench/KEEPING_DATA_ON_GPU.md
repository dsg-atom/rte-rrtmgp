# What it takes to keep the data on the GPU

## The goal
Today each part of the model copies its data onto the GPU, runs, and copies it
back — every time it's called. We want the data to sit on the GPU and stay there
while dynamics, moisture, and radiation each take a turn. Then the copying
happens once at the start and once at the end, instead of over and over.

## What we found
- The parts that do the math already keep their working data on the GPU. The
  wasteful copying isn't in the math — it's in the hand-off code that passes data
  between the old Fortran model and the new GPU code.
- That hand-off code exists in **three separate copies** (dynamics has its own,
  moisture uses a shared one, a third piece has another). To fix the copying
  once, we first have to get them onto the same shared version.
- The model's data is owned by a bookkeeping layer that only knows about ordinary
  memory, not GPU memory. But it has a useful habit: when one part writes a field
  and the next part reads it, they already point at the *same single copy*. So if
  that copy lived on the GPU, both parts would share it there for free. (This only
  works for direct hand-offs. When the model has to reshape or resize data in
  between, it makes a second copy — those can't be shared without extra work.)

## The work, easiest to hardest
1. **Merge the three hand-off codes into one.** Low risk of surprises, but it
   touches dynamics, which already works — so we must be careful not to break it.
2. **Teach the hand-off code to accept data that's already on the GPU** instead of
   always copying. The hooks for this are half-built already.
3. **Let it keep the data across calls instead of re-copying every time.** The
   delicate part: it only works if the model doesn't move the data around behind
   our back, and we must track when a real copy back to the CPU is still needed
   (to save output, or for parts still running on the CPU). Get this wrong and
   results are silently corrupted.
4. **Wrap the whole dynamics → moisture → radiation sequence** so the copy happens
   once at the ends, not between each part.
5. **Connect the radiation code, which is a different kind of GPU code** than
   dynamics and moisture. Getting the two kinds to share the same GPU data is the
   newest and riskiest piece.
6. **(Optional) Make the bookkeeping layer itself hold data on the GPU.** The
   biggest change — it touches shared model infrastructure — but it's what makes
   the fix general instead of one-off.

## How step 6 relates to the first five
Steps 1–5 leave the model's data officially living on the CPU and manage a GPU
copy on the side — we track which copy is current and sync them at the right
moments. That gets the speedup, but it's a workaround we babysit field by field.

Step 6 removes the root cause: put the model's data on the GPU in the first
place, so there's no second copy to track. The sharing-between-neighbors habit
then hands out GPU data on its own. So step 6 is the clean, general version of
what steps 1–5 do by hand — it makes step 3 much safer and much of step 2
unnecessary.

Two things to keep in mind. Steps 1–5 don't need step 6 — that's why it's
optional; we can prove the whole idea without it. And step 6 changes shared
infrastructure that all of GEOS depends on, so unlike steps 1–5 it can't go in
without the maintainers' permission.

## Two things that could bite us
- The whole plan assumes the model keeps each field in one fixed place while we
  use it. That holds for direct hand-offs, not for the ones where the model
  reshapes data in between.
- If we use the "shared" memory type and any leftover CPU code touches a field
  mid-sequence, the data quietly shuffles back and forth and we lose the speedup.
  We have to know which fields that applies to.

## Smallest first step
Prove it on one hand-off: **dynamics → moisture.** Both already use the same GPU
framework and both already keep their data on the GPU. If we can get moisture to
read dynamics' GPU data directly, instead of bouncing it through the CPU, that
tests the whole idea on real data — without touching the model's core or the
radiation code yet.

## Bottom line
Most of this is plumbing in the hand-off layer, and the model already helps by
sharing data between neighbors. The two hard, new parts are keeping data across
calls safely, and getting the radiation code (a different GPU framework) to share
the same GPU data. Start with the dynamics → moisture hand-off to prove it cheaply.
