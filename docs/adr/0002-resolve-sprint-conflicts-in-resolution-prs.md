---
status: accepted
---

# Resolve Sprint conflicts in Resolution PRs, replayed with git rerere

When a Sprint candidate merges cleanly with `main` but conflicts with another candidate already in the Sprint branch (a Sprint conflict), the bot opens a throwaway Resolution PR. The PR runs from a copy of the candidate into a snapshot of the Sprint branch. The candidate's author resolves the conflict there, and anyone, the author included, approves it. The bot then records the resolution with `git rerere` and stores it as a Recorded resolution on a bot-only `sprint-resolutions` branch. Refresh, Rebuild and Rollover replay it whenever they hit the same conflict again.

The resolution only needs to live in the Sprint branch, because that is what ships through the Release PR (ADR-0001). It cannot simply be committed to the Sprint branch, though. Only the bot writes to that branch, and Rebuild and Rollover recreate it from scratch, so a fix made by hand would be lost. Adopted on 2026-10-15. Not built yet.

## Considered Options

- **Merge the other candidate (or `main`) into the conflicting PR.** This is what the Refresh comment suggests today. Rejected: each PR must carry only its own changes.
- **Leave the candidate out until the other one reaches `main`.** Rejected: the two features are never tested together on staging during the sprint. This still happens as a fallback whenever no Recorded resolution matches.
- **Stack the candidate on the other one's branch.** Rejected: it couples two PRs that should ship and review independently.
- **Have authors run rerere locally and push the cache themselves.** Rejected: every team member would need rerere enabled, a checkout of `sprint-resolutions`, and an exact copy of the bot's merge starting point. Moving all of that into the bot leaves authors with an ordinary GitHub conflict to resolve.

## Consequences

- rerere matches only identical conflicting lines. If either PR edits those lines, the Recorded resolution stops applying and a new Resolution PR is needed. Whoever fails to join the Sprint branch resolves it, even if the other PR caused the change.
- rerere captures only the conflicting hunks. The bot rejects a resolution whose replayed result differs from the approved merge, for example one with an extra edit in another file.
- A Resolution PR is checked only on approval. The bot records it against its own snapshot, then tries a Refresh. If the replay no longer applies, it opens a new Resolution PR.
- An approval during a Freeze stores the resolution but does not trigger a Refresh.
- Rollover keeps only the Recorded resolutions it actually replayed, which drops those for shipped PRs.
- If the candidates ship in different Release PRs, the later one conflicts with `main` and its author resolves the conflict again in their own branch. The Recorded resolution helps only the Sprint branch.
- Resolution PRs are opened by the bot, so their resolver can approve them. Requiring approval of the most recent push on `sprint-resolve/*` branches would break this.
