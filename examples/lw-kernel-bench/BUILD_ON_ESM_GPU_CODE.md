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
impossible. It doesn't — the necessary hooks are already in place; the feature
was simply switched off.

## The one thing to check first
The ESM team deliberately turned off "keep data on the GPU," with a note about
not trusting that the Fortran side keeps its data in the same place between
steps. So before we build on it, we need to understand *why* they turned it off —
that tells us how hard turning it back on will be. That's the next question, not
a reason to start over.

## Bottom line
Reuse. The data-handling fix is unavoidable and identical either way, so we
should do it once — not duplicate a mountain of working code to get to the same
place.
