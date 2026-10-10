# Working rules for Codex

Specs live outside this repo, in `../specs/` (not in git). Each prompt names one step of one SPEC.

- Read the SPEC's **§1 Decisions** and **your step** only. Don't open other SPECs or `../specs/archive/`.
- Start with `git status`. If it isn't clean, stop and tell Kyle.
- The step names the files it expects to touch. Stay in those plus the tests you add. If another file really needs a change, make it and say so in the summary.
- **Searching:** use `rg` (not grep). Fine: `rg -n SYMBOL src` to find call sites of something the step names; `rg -n` inside a named file to find the spot. For a file over ~600 lines, rg to the spot and read that range instead of the whole file. No open-ended exploring.
- **Anchor cases** in the SPEC are hand-checked expected values: put each one in a test. Add any further tests the step's rules need (few, focused). If the code gives a different number than an anchor, re-check against §1; if it still differs, report what you got. Never change an anchor number to make a test pass.
- While iterating, run only the test files you touched. Run the full gate once, at the end.
- Move code between files by script (cut by line range), never retype it.
- A data-shape change (new field, rename) stays its own step if the SPEC splits it that way; don't fold behavior into it.
- Finish with at most 3 lines: what changed, anything surprising, anything left undone. Commit with the message the prompt gives.

## This repo (cabinetry_designer_api)
- Full gate: `npm test`.
- The API passes the drawing payload through to geometry; it doesn't reshape it unless the step says so.
