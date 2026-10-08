---
status: accepted
---

# Ship a sprint to main by merging its Release PR

A sprint reaches `main` by merging its Release PR (`sprint-<N>` → `main`) as a merge commit, not by merging each Sprint candidate separately. The Sprint branch is what staging tests, so merging it is the only way to ship exactly that tree, with the same conflict resolutions and merge order. The workflow already assumes this: Freeze is a label on the Release PR, and Rollover expects the previous Sprint branch to be in `main` before deleting it. Adopted on 2026-10-06 for now, pending wider team agreement.

## Considered Options

- **Merge each Sprint candidate into `main` separately.** Rejected: allows shipping part of a sprint and keeps per-PR history, but the combination released is never the one staging tested. It also breaks the current script, which reports squash-merged PRs as Stale PRs, and leaves Freeze without a Release PR to live on.

## Consequences

- Hotfixes are the only exception: they may merge into `main` directly, which moves `main` mid-sprint. The next Refresh merges them into the Sprint branch.

- The Release PR must be merged with "Create a merge commit". A squash would leave the Sprint candidates open and confuse the script's checks of what is already in `main`. The repo currently allows all three merge methods, so for now this is enforced by team convention only.
- Dropping one feature means removing its label and running Rebuild, which deletes the Sprint branch and so closes the Release PR. A new one must be opened.
- `main` history includes the bot's merge commits (`Merge PR #n: …`, `Merge main into sprint-N`).
