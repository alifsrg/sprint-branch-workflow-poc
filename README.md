# sprint-branch-workflow-poc

Sandbox for testing the sprint branch workflow (`.github/workflows/sprint-branch.yml`).

- Label a PR with `merge-to-sprint` to have it merged into the latest `sprint-<N>` branch.
- Add `sprint-frozen` to the `sprint-<N>` → `main` release PR to pause automatic runs.
- Actions → **Sprint branch** → **Run workflow** for `refresh`, `rebuild` or `new-sprint`.
