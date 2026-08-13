# Should we build off of the ESM GPU code?

## The situation
The GEOS-ESM team has already moved two big parts of the model onto the GPU:
the atmospheric dynamics and the cloud-and-moisture physics. Both work and are
being tested. But neither keeps its data on the GPU between steps — each time
they run, they copy the data onto the GPU, compute, and copy it back. That
back-and-forth copying is the main thing that would erase the speed advantage
we're after. So the choice is:

- **(a)** Reuse their code and add the "keep the data on the GPU" part ourselves, or
- **(b)** Rewrite the whole thing ourselves from scratch.

## Recommendation: (a) reuse it, and add the missing piece

The reason is simple: **the copying problem is not in the math.** It lives in a
separate layer that hands data between the Fortran model and the GPU code. The
thousands of lines that actually compute the physics don't care whether their
data was freshly copied over or already sitting on the GPU.

That makes the decision one-sided:

- **If we reuse:** we fix the data-handling layer once, and every part we reuse —
  plus the radiation code we're going to write — automatically benefits. We keep
  tens of thousands of lines of already-tested code that the ESM team is still
  actively improving.
- **If we rewrite everything:** we'd redo all that tested code from scratch, drift
  away from the ESM team's ongoing work, and — this is the key point — **we'd still
  have to build the exact same data-handling fix at the end.** Rewriting the math
  buys us nothing on the actual problem.

Rewriting would only make sense if their design made keeping data on the GPU
impossible. It doesn't — the code already anticipates the idea (it has a name
for "Fortran memory that lives on the GPU"); that path was simply never built.

## Why it isn't built — we checked
We traced this through the actual code and the pull requests that added it, and
the picture is clean:

- **It was never turned off — it was never built.** The code has a placeholder
  that stops with "not implemented" if Fortran ever hands it data already on the
  GPU. It's a stub for future work, not a feature someone disabled.
- **No one argued against it.** The pull request that brought this code in (and
  the later one that merged it to the main line) say nothing about keeping data
  on the GPU — no discussion, no objection, no review comment. It simply wasn't
  part of the job at the time.
- **There is one related note in the code (a correction to what I said before).**
  The team left a comment saying they'd like to add a mode that re-checks where
  the data lives on every call, rather than assume the Fortran side keeps it in
  one place. It's a wish, not built yet. It's also the *opposite* of what we
  want: keeping data on the GPU means counting on it staying put. So it isn't a
  barrier they raised against us — it's the same question, and our answer (for
  the direct hand-offs) is "yes, it stays put." I earlier called this note
  unfounded; that was wrong — the note is real, I'd just misread what it meant.
- **The job at the time was correctness, not speed.** That work was about proving
  the new GPU physics produces the *same numbers* as the old code, with an on/off
  switch to fall back. For checking numbers, copying to the GPU and back is the
  simplest, safest choice. Keeping data resident is a *speed* concern, and speed
  wasn't the milestone.
- **The real reason is structural.** The data-handling layer only accepts data
  that lives on the regular processor, because that is the only kind of data the
  Fortran model ever hands it. Making data stay on the GPU requires a change on
  the *Fortran side* (so it owns and passes GPU memory) — which is exactly the
  shared piece we'd be adding, for every component at once.

The takeaway: there's no hidden landmine here. Nobody decided keeping data on the
GPU was a bad idea; it just wasn't needed yet. Turning it on is new work we add on
top, not a decision of theirs we have to fight.

## Bottom line
Reuse. The data-handling fix is unavoidable and identical either way, so we
should do it once — not duplicate a mountain of working code to get to the same
place. And since keeping data on the GPU was never a deliberate "no," building it
is added work in a shared layer, not a reversal of anyone's decision.
