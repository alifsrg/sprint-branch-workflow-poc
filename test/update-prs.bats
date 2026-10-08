#!/usr/bin/env bats
# Mode update-prs: after main moves, check every open PR into main and warn about conflicts.

load helpers

setup() {
  setup_world
  commit main shared.txt "base" "Add shared"
  create_sprint 1
}

# Moves main the way a Hotfix does, so PRs editing shared.txt conflict with it.
hotfix_main() {
  commit main shared.txt "hotfix" "Hotfix shared"
}

@test "gives a conflicting PR a Conflict warning listing its files" {
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = "$(printf 'comment.create\nlabel.add')" ]
  [[ "$(last_comment 1)" == *"Conflicts with \`main\`"* ]]
  [[ "$(last_comment 1)" == *'- `shared.txt`'* ]]
  [[ "$(last_comment 1)" == *"merge \`main\` into your branch"* ]]
  [ "$(gh_writes 1 | jq -r 'select(.op == "label.add").label')" = has-conflicts ]
}

@test "creates the has-conflicts label once when the repo lacks it" {
  commit feat-a shared.txt "from A" "A edits shared"
  commit feat-b shared.txt "from B" "B edits shared"
  open_pr 1 feat-a "Feature A"
  open_pr 2 feat-b "Feature B"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes | jq -r 'select(.op == "label.create").label')" = has-conflicts ]
}

@test "leaves a PR that merges cleanly with main untouched" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A"
  before="$(remote_sha feat-a)"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ -z "$(gh_writes)" ]
  [ "$(remote_sha feat-a)" = "$before" ]
}

@test "gives draft and fork PRs a Conflict warning too" {
  commit feat-a shared.txt "from A" "A edits shared"
  commit feat-b shared.txt "from B" "B edits shared"
  open_pr 1 feat-a "Draft feature"
  open_pr 2 feat-b "Fork feature"
  set_pr_field 1 isDraft true
  set_pr_field 2 isCrossRepository true
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = "$(printf 'comment.create\nlabel.add')" ]
  [ "$(gh_writes 2 | jq -r .op)" = "$(printf 'comment.create\nlabel.add')" ]
}

@test "skips the Release PR" {
  checkout_sprint 1
  commit sprint-1 shared.txt "from sprint" "Sprint edits shared"
  open_pr 10 sprint-1 "Release sprint 1"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ -z "$(gh_writes)" ]
}

@test "re-running edits nothing when the Conflict warning is unchanged" {
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs
  : > "$GH_STATE_DIR/writes.jsonl"

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ -z "$(gh_writes)" ]
}

@test "edits the Conflict warning in place when the PR gets a new conflicting commit" {
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs
  commit feat-a shared.txt "from A, again" "A edits shared again"
  push_pr_head 1 feat-a
  : > "$GH_STATE_DIR/writes.jsonl"

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = comment.edit ]
  [[ "$(last_comment 1)" == *"$(git -C "$DEV" rev-parse --short=7 feat-a)"* ]]
}

@test "keeps the Conflict warning and the Refresh comment on a Sprint candidate apart" {
  commit feat-a shared.txt "from A" "A edits shared"
  commit feat-b shared.txt "from B" "B edits shared"
  open_pr 1 feat-a "Feature A" merge-to-sprint
  open_pr 2 feat-b "Feature B" merge-to-sprint
  run_script
  refresh_comment="$(last_comment 2)"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 2 | jq -r .op)" = "$(printf 'comment.create\ncomment.create\nlabel.add')" ]
  [ "$(jq -r 'map(select(.issue == 2)) | first.body' "$GH_STATE_DIR/comments.json")" = "$refresh_comment" ]
}

@test "runs while the Sprint branch is frozen" {
  open_pr 10 sprint-1 "Release sprint 1" sprint-frozen
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = "$(printf 'comment.create\nlabel.add')" ]
}

@test "lists every open PR and its outcome in the run summary" {
  open_pr 10 sprint-1 "Release sprint 1"
  commit feat-a shared.txt "from A" "A edits shared"
  commit feat-b b.txt "b" "Add b"
  open_pr 1 feat-a "Feature A"
  open_pr 2 feat-b "Feature B"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [[ "$(summary)" == *"| #1 | Feature A | ❌ conflict – warned |"* ]]
  [[ "$(summary)" == *"| #2 | Feature B | ✅ merges cleanly |"* ]]
  [[ "$(summary)" == *"| #10 | Release sprint 1 | ⏭️ skipped – Release PR |"* ]]
}
