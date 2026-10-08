# Sprint Branch Workflow

A shared branch that collects the changes planned for a sprint so they can be deployed to staging and tested together before they ship to `main`.

## Language

### Branches and PRs

**Sprint branch**:
The `sprint-<N>` branch containing `main` plus every Sprint candidate. Only the highest N is active. Only the bot writes to it.
_Avoid_: Integration branch, release branch, staging branch

**Sprint candidate**:
An open PR into `main` that carries the `merge-to-sprint` label and so belongs in the Sprint branch.
_Avoid_: Labelled PR, opted-in PR

**Release PR**:
The PR from the Sprint branch into `main`.

**Hotfix**:
A PR merged into `main` directly rather than through a Release PR. It is the only exception to shipping through a sprint.

**Stale PR**:
A PR whose changes are on the Sprint branch even though it is no longer a Sprint candidate and its changes are not in `main`.

### Keeping PRs current

**Branch update**:
The bot merging the latest `main` into an open PR's branch after `main` moves.
_Avoid_: Auto-update, sync, rebase

**Conflict warning**:
The bot's notice, a comment plus the `has-conflicts` label, on an open PR that no longer merges cleanly with `main`.

### States

**Freeze**:
The state of a Sprint branch whose Release PR carries the `sprint-frozen` label. While frozen, automatic Refreshes are paused.

### Modes

**Refresh**:
An append-only update that brings `main` and new Sprint candidate commits into the Sprint branch without rewriting it.

**Rebuild**:
Recreating the Sprint branch from `main` plus the current Sprint candidates, which drops Stale PRs.

**Rollover**:
Starting `sprint-<N+1>` from `main` plus the current Sprint candidates, and retiring `sprint-<N>`.
_Avoid_: New sprint
