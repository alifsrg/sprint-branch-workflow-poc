# Shared fixture for the sprint branch script tests.
#
# Each test gets a throwaway world:
#   $ORIGIN        bare repo standing in for GitHub (branches + refs/pull/<n>/head)
#   $DEV           a developer's clone, used to create commits and PR branches
#   $GH_STATE_DIR  fake gh state (see test/fake-bin/gh)
#
# The script is run the way the workflow runs it: env vars in, from a fresh clone of origin.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/sprint-branch.sh"

setup_world() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com
  export GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
  export PATH="$REPO_ROOT/test/fake-bin:$PATH"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  DEV="$BATS_TEST_TMPDIR/dev"
  export GH_STATE_DIR="$BATS_TEST_TMPDIR/gh"

  mkdir -p "$GH_STATE_DIR"
  echo '[]' > "$GH_STATE_DIR/prs.json"
  echo '[]' > "$GH_STATE_DIR/comments.json"
  jq -n '[{name: "merge-to-sprint"}, {name: "sprint-frozen"}]' > "$GH_STATE_DIR/labels.json"
  : > "$GH_STATE_DIR/writes.jsonl"
  : > "$GH_STATE_DIR/calls.log"

  git init --quiet --bare --initial-branch=main "$ORIGIN"
  cp "$REPO_ROOT/test/fake-origin/post-receive" "$ORIGIN/hooks/post-receive"
  git clone --quiet "$ORIGIN" "$DEV" 2>/dev/null
  git -C "$DEV" symbolic-ref HEAD refs/heads/main
  echo hello > "$DEV/README.md"
  git -C "$DEV" add README.md
  git -C "$DEV" commit --quiet -m "Initial commit"
  git -C "$DEV" push --quiet origin main
}

# Commits <content> to <file> on <branch> (creating it from main if needed) and pushes the branch.
commit() { # <branch> <file> <content> [message]
  local branch="$1" file="$2" content="$3" message="${4:-Update $2 on $1}"
  if git -C "$DEV" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git -C "$DEV" checkout --quiet "$branch"
  else
    git -C "$DEV" checkout --quiet -b "$branch" main
  fi
  printf '%s\n' "$content" > "$DEV/$file"
  git -C "$DEV" add "$file"
  git -C "$DEV" commit --quiet -m "$message"
  git -C "$DEV" push --quiet --force origin "$branch"
}

# Creates sprint-<N> on origin from the current main.
create_sprint() { # <N>
  git -C "$DEV" push --quiet origin "main:refs/heads/sprint-$1"
}

# Checks out origin's sprint-<N> in the dev clone, so `commit sprint-<N> ...` adds to it.
checkout_sprint() { # <N>
  git -C "$DEV" fetch --quiet origin "sprint-$1"
  git -C "$DEV" checkout --quiet -B "sprint-$1" FETCH_HEAD
}

# Moves origin's <branch> on with a new commit, but leaves refs/pull/<n>/head where it was:
# an author push that lands while a run is in progress, after it fetched the PR head.
author_pushes_during_run() { # <branch> <file> <content>
  git -C "$DEV" checkout --quiet "$1"
  printf '%s\n' "$3" > "$DEV/$2"
  git -C "$DEV" add "$2"
  git -C "$DEV" commit --quiet -m "Author commit during run"
  git -C "$DEV" push --quiet origin "$1:refs/staging/$1"
  git --git-dir="$ORIGIN" update-ref "refs/heads/$1" "refs/staging/$1"
  git --git-dir="$ORIGIN" update-ref -d "refs/staging/$1"
}

# Resolves <branch>'s conflicts with main the way the Conflict warning says: merge main in, keeping
# the branch's side, and push.
resolve_by_merging_main() { # <branch>
  git -C "$DEV" checkout --quiet "$1"
  git -C "$DEV" merge --quiet -X ours -m "Merge main into $1" main >/dev/null
  git -C "$DEV" push --quiet origin "$1"
}

# Makes origin refuse every push with <message>, as GitHub does for a push it doesn't allow.
refuse_pushes() { # <message>
  printf '#!/usr/bin/env bash\necho %q >&2\nexit 1\n' "$1" > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
}

# Forgets the gh writes recorded so far, so a test can check only what the next run writes.
reset_gh_writes() {
  : > "$GH_STATE_DIR/writes.jsonl"
}

# Registers an open PR into main from <branch> and publishes refs/pull/<n>/head.
open_pr() { # <n> <branch> <title> [label...]
  local n="$1" branch="$2" title="$3"
  shift 3
  local labels
  labels="$(printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(. != "") | {name: .})')"
  jq --argjson n "$n" --arg branch "$branch" --arg title "$title" --argjson labels "$labels" \
    '. + [{number: $n, title: $title, headRefName: $branch, baseRefName: "main",
           state: "OPEN", isDraft: false, isCrossRepository: false, labels: $labels}]' \
    "$GH_STATE_DIR/prs.json" > "$GH_STATE_DIR/prs.json.tmp"
  mv "$GH_STATE_DIR/prs.json.tmp" "$GH_STATE_DIR/prs.json"
  push_pr_head "$n" "$branch"
}

# Points refs/pull/<n>/head at origin's <branch>, as GitHub does after every push to a PR.
push_pr_head() { # <n> <branch>
  git --git-dir="$ORIGIN" update-ref "refs/pull/$1/head" "refs/heads/$2"
}

# Adds a comment from the bot (as left by an earlier run) without recording it as a write.
seed_bot_comment() { # <n> <body>
  jq --argjson n "$1" --arg body "<!-- sprint-bot -->"$'\n'"$2" \
    '. + [{id: ((map(.id) | max // 1000) + 1), issue: $n, body: $body}]' \
    "$GH_STATE_DIR/comments.json" > "$GH_STATE_DIR/comments.json.tmp"
  mv "$GH_STATE_DIR/comments.json.tmp" "$GH_STATE_DIR/comments.json"
}

# Sets <field> of PR <n> to the JSON <value>, e.g. set_pr_field 1 isDraft true.
set_pr_field() { # <n> <field> <value>
  jq --argjson n "$1" --arg f "$2" --argjson v "$3" \
    'map(if .number == $n then .[$f] = $v else . end)' \
    "$GH_STATE_DIR/prs.json" > "$GH_STATE_DIR/prs.json.tmp"
  mv "$GH_STATE_DIR/prs.json.tmp" "$GH_STATE_DIR/prs.json"
}

# Removes <label> from PR <n>.
remove_label() { # <n> <label>
  jq --argjson n "$1" --arg l "$2" \
    'map(if .number == $n then .labels |= map(select(.name != $l)) else . end)' \
    "$GH_STATE_DIR/prs.json" > "$GH_STATE_DIR/prs.json.tmp"
  mv "$GH_STATE_DIR/prs.json.tmp" "$GH_STATE_DIR/prs.json"
}

# Runs the script from a fresh clone of origin. Pass env as NAME=value arguments.
# Defaults: an automatic refresh, as triggered by pull_request_target.
run_script() { # [NAME=value...]
  local checkout
  checkout="$(mktemp -d "$BATS_TEST_TMPDIR/checkout.XXXXXX")"
  git clone --quiet "$ORIGIN" "$checkout" 2>/dev/null
  run _run_in "$checkout" \
    MODE=refresh EVENT_NAME=pull_request_target GITHUB_REPOSITORY=acme/app \
    GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" \
    "$@" bash "$SCRIPT"
}

_run_in() { # <dir> [NAME=value...] <command...>
  cd "$1" && shift && env "$@"
}

# ---------- assertions ----------

# Fails the test unless <haystack> contains <needle>. Use this rather than a bare [[ ]]: with
# bash 3.2 (macOS) a failing [[ ]] mid-test does not fail it.
assert_contains() { # <haystack> <needle>
  if [[ "$1" != *"$2"* ]]; then
    printf 'expected to contain: %s\nactual: %s\n' "$2" "$1" >&2
    return 1
  fi
}

# ---------- observations ----------

remote_sha() { # <ref>
  git --git-dir="$ORIGIN" rev-parse "$1"
}

# Subject of the commit at <ref>.
remote_subject() { # <ref>
  git --git-dir="$ORIGIN" log -1 --format=%s "$1"
}

# Subjects of commits on <ref> that are not on main, oldest first.
remote_subjects() { # <ref>
  git --git-dir="$ORIGIN" log --reverse --format=%s "main..$1"
}

# Succeeds if <ancestor> is contained in <ref> on origin.
remote_contains() { # <ref> <ancestor>
  git --git-dir="$ORIGIN" merge-base --is-ancestor "$(remote_sha "$2")" "$(remote_sha "$1")"
}

# The run summary written to $GITHUB_STEP_SUMMARY.
summary() {
  cat "$BATS_TEST_TMPDIR/summary.md"
}

# Recorded gh writes as JSON lines, optionally only those on PR <n>.
gh_writes() { # [n]
  if [[ -n "${1:-}" ]]; then
    jq -c --argjson n "$1" 'select(.pr == $n)' "$GH_STATE_DIR/writes.jsonl"
  else
    cat "$GH_STATE_DIR/writes.jsonl"
  fi
}

# Number of comments currently on PR <n>.
comment_count() { # <n>
  jq --argjson n "$1" 'map(select(.issue == $n)) | length' "$GH_STATE_DIR/comments.json"
}

# Body of the last comment written on PR <n>.
last_comment() { # <n>
  gh_writes "$1" | jq -rs 'map(select(.op | startswith("comment."))) | last.body // empty'
}

# Succeeds if <branch> exists on origin.
remote_has_branch() { # <branch>
  git --git-dir="$ORIGIN" show-ref --verify --quiet "refs/heads/$1"
}
