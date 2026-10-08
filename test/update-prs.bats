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
  assert_contains "$(last_comment 1)" "Conflicts with \`main\`"
  assert_contains "$(last_comment 1)" '- `shared.txt`'
  assert_contains "$(last_comment 1)" "merge \`main\` into your branch"
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

@test "gives a clean, ready PR a Branch update merging main into its branch" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A"
  before="$(remote_sha feat-a)"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ -z "$(gh_writes)" ]
  [ "$(remote_subject feat-a)" = "Merge main into feat-a" ]
  [ "$(remote_sha feat-a^1)" = "$before" ]
  [ "$(remote_sha feat-a^2)" = "$(remote_sha main)" ]
}

@test "leaves a PR that already contains main alone" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A"
  before="$(remote_sha feat-a)"

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ -z "$(gh_writes)" ]
  [ "$(remote_sha feat-a)" = "$before" ]
}

@test "never pushes to draft or fork PRs" {
  commit feat-a a.txt "a" "Add a"
  commit feat-b b.txt "b" "Add b"
  open_pr 1 feat-a "Draft feature"
  open_pr 2 feat-b "Fork feature"
  set_pr_field 1 isDraft true
  set_pr_field 2 isCrossRepository true
  draft_before="$(remote_sha feat-a)"
  fork_before="$(remote_sha feat-b)"
  hotfix_main

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(remote_sha feat-a)" = "$draft_before" ]
  [ "$(remote_sha feat-b)" = "$fork_before" ]
  [ -z "$(gh_writes)" ]
  assert_contains "$(summary)" "| #1 | Draft feature | ✅ merges cleanly – draft, not updated |"
  assert_contains "$(summary)" "| #2 | Fork feature | ✅ merges cleanly – fork, not updated |"
}

@test "records a rejected push and still updates the remaining PRs" {
  commit feat-a a.txt "a" "Add a"
  commit feat-b b.txt "b" "Add b"
  open_pr 1 feat-a "Feature A"
  open_pr 2 feat-b "Feature B"
  hotfix_main
  author_pushes_during_run feat-a a.txt "a, during the run"
  author_head="$(remote_sha feat-a)"

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(remote_sha feat-a)" = "$author_head" ]
  [ "$(remote_subject feat-b)" = "Merge main into feat-b" ]
  assert_contains "$(summary)" "| #1 | Feature A | ⚠️ push rejected"
}

@test "reports a push refused for another reason as failed, not as retried" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A"
  hotfix_main
  refuse_pushes "refusing to allow a GitHub App to create or update workflow without workflows permission"

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  assert_contains "$(summary)" "| #1 | Feature A | ❌ push failed"
  assert_contains "$output" "workflows permission"
}

@test "a Sprint candidate's updated head is picked up by the next Refresh" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A" merge-to-sprint
  run_script
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs

  run_script

  [ "$status" -eq 0 ]
  [ "$(remote_subject feat-a)" = "Merge main into feat-a" ]
  remote_contains sprint-1 feat-a
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
  reset_gh_writes

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
  reset_gh_writes

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = comment.edit ]
  assert_contains "$(last_comment 1)" "$(git -C "$DEV" rev-parse --short=7 feat-a)"
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
  commit feat-c c.txt "c" "Add c"
  open_pr 3 feat-c "Feature C"

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  assert_contains "$(summary)" "| #1 | Feature A | ❌ conflict – warned |"
  assert_contains "$(summary)" "| #2 | Feature B | 🔀 updated |"
  assert_contains "$(summary)" "| #3 | Feature C | ✅ up to date |"
  assert_contains "$(summary)" "| #10 | Release sprint 1 | ⏭️ skipped – Release PR |"
}

@test "clears the Conflict warning once the PR merges cleanly again" {
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs
  resolve_by_merging_main feat-a
  reset_gh_writes

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = "$(printf 'label.remove\ncomment.edit')" ]
  assert_contains "$(last_comment 1)" "No longer conflicts with \`main\`"
  [ "$(comment_count 1)" -eq 1 ]
  assert_contains "$(summary)" "| #1 | Feature A | ✅ up to date, warning cleared |"
}

@test "a single-PR re-check clears that PR and touches no other" {
  commit feat-a shared.txt "from A" "A edits shared"
  commit feat-b shared.txt "from B" "B edits shared"
  open_pr 1 feat-a "Feature A"
  open_pr 2 feat-b "Feature B"
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs
  resolve_by_merging_main feat-a
  commit feat-b shared.txt "from B, again" "B edits shared again"
  feat_b_before="$(remote_sha feat-b)"
  reset_gh_writes

  run_script EVENT_NAME=pull_request_target MODE=update-prs PR_NUMBER=1

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = "$(printf 'label.remove\ncomment.edit')" ]
  [ -z "$(gh_writes 2)" ]
  [ "$(remote_sha feat-b)" = "$feat_b_before" ]
}

@test "a single-PR re-check updates the warning with the current conflicting files" {
  commit main other.txt "base" "Add other"
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  commit main other.txt "hotfix" "Hotfix other"
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs
  commit feat-a other.txt "from A" "A edits other"
  reset_gh_writes

  run_script EVENT_NAME=pull_request_target MODE=update-prs PR_NUMBER=1

  [ "$status" -eq 0 ]
  [ "$(gh_writes 1 | jq -r .op)" = comment.edit ]
  assert_contains "$(last_comment 1)" '- `other.txt`'
  assert_contains "$(last_comment 1)" '- `shared.txt`'
}

@test "gives a PR that merges cleanly again a Branch update and clears its warning" {
  commit feat-a shared.txt "from A" "A edits shared"
  open_pr 1 feat-a "Feature A"
  hotfix_main
  run_script EVENT_NAME=push MODE=update-prs
  commit feat-a shared.txt "base" "A reverts shared"
  commit feat-a a.txt "a" "Add a"
  reset_gh_writes

  run_script EVENT_NAME=push MODE=update-prs

  [ "$status" -eq 0 ]
  [ "$(remote_subject feat-a)" = "Merge main into feat-a" ]
  [ "$(gh_writes 1 | jq -r .op)" = "$(printf 'label.remove\ncomment.edit')" ]
  assert_contains "$(summary)" "| #1 | Feature A | 🔀 updated, warning cleared |"
}
