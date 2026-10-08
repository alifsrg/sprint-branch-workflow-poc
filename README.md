# sprint-branch-workflow-poc

Sandbox for testing the sprint branch workflow (`.github/workflows/sprint-branch.yml`).

- Label a PR with `merge-to-sprint` to have it merged into the latest `sprint-<N>` branch.
- Add `sprint-frozen` to the `sprint-<N>` → `main` release PR to pause automatic runs.
- Actions → **Sprint branch** → **Run workflow** for `refresh`, `rebuild` or `new-sprint`.
- After every push to `main`, the bot merges `main` into every open PR into `main` that merges cleanly (a Branch update; drafts and fork PRs are skipped). PRs that conflict with it get a Conflict warning instead: a bot comment listing the conflicting files, and the `has-conflicts` label.

## Tests

The sprint branch script has a [bats](https://github.com/bats-core/bats-core) suite in `test/`. It runs entirely locally, with no network or GitHub access:

```sh
brew install bats-core jq   # or: apt-get install bats jq
bats test/
```

Each test builds a throwaway world: a bare repo standing in for `origin` (with PR heads at `refs/pull/<n>/head`), and a fake `gh` (`test/fake-bin/gh`) that serves PRs and comments from fixtures and records every write. Tests run the script as the workflow does, with environment variables in, and assert only on remote refs and recorded `gh` writes. Fixture helpers live in `test/helpers.bash`.
