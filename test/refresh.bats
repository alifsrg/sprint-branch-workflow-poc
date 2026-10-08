#!/usr/bin/env bats
# Refresh: append-only update of the Sprint branch with main and new Sprint candidate commits.

load helpers

setup() {
  setup_world
  create_sprint 1
}

@test "merges a new Sprint candidate into the Sprint branch" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Add feature A" merge-to-sprint

  run_script

  [ "$status" -eq 0 ]
  [ "$(remote_subjects sprint-1)" = "$(printf 'Add a\nMerge PR #1: Add feature A')" ]
  remote_contains sprint-1 refs/pull/1/head
}

@test "leaves a Sprint candidate that is already included alone" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Add feature A" merge-to-sprint
  run_script
  before="$(remote_sha sprint-1)"

  run_script

  [ "$status" -eq 0 ]
  [ "$(remote_sha sprint-1)" = "$before" ]
  [ -z "$(gh_writes)" ]
}

@test "does not merge a conflicting Sprint candidate and comments with its files" {
  commit feat-a shared.txt "from A" "A edits shared"
  commit feat-b shared.txt "from B" "B edits shared"
  open_pr 1 feat-a "Feature A" merge-to-sprint
  open_pr 2 feat-b "Feature B" merge-to-sprint

  run_script

  [ "$status" -eq 0 ]
  remote_contains sprint-1 refs/pull/1/head
  run ! remote_contains sprint-1 refs/pull/2/head
  [ -z "$(gh_writes 1)" ]
  [ "$(gh_writes 2 | jq -r .op)" = comment.create ]
  [[ "$(last_comment 2)" == *"Merge conflict with \`sprint-1\`"* ]]
  [[ "$(last_comment 2)" == *'- `shared.txt`'* ]]
}

@test "reports a Sprint candidate rebased after joining as needing a rebuild" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Add feature A" merge-to-sprint
  run_script
  before="$(remote_sha sprint-1)"
  git -C "$DEV" checkout --quiet feat-a
  git -C "$DEV" commit --quiet --amend -m "Add a (reworded)"
  git -C "$DEV" push --quiet --force origin feat-a
  push_pr_head 1 feat-a

  run_script

  [ "$status" -eq 0 ]
  [ "$(remote_sha sprint-1)" = "$before" ]
  [ "$(gh_writes 1 | jq -r .op)" = comment.create ]
  [[ "$(last_comment 1)" == *"Not updated in \`sprint-1\`"* ]]
  [[ "$(last_comment 1)" == *"mode \`rebuild\`"* ]]
}

@test "reports a Stale PR with a comment" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Add feature A" merge-to-sprint
  run_script
  remove_label 1 merge-to-sprint

  run_script

  [ "$status" -eq 0 ]
  remote_contains sprint-1 refs/pull/1/head
  [ "$(gh_writes 1 | jq -r .op)" = comment.create ]
  [[ "$(last_comment 1)" == *"Still in \`sprint-1\`"* ]]
  [[ "$(last_comment 1)" == *"no longer has the \`merge-to-sprint\` label"* ]]
}

@test "an automatic run skips while the Release PR is frozen" {
  open_pr 10 sprint-1 "Release sprint 1" sprint-frozen
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Add feature A" merge-to-sprint
  before="$(remote_sha sprint-1)"

  run_script EVENT_NAME=pull_request_target

  [ "$status" -eq 0 ]
  [ "$(remote_sha sprint-1)" = "$before" ]
  [ -z "$(gh_writes)" ]
}

@test "a manual run proceeds while the Release PR is frozen" {
  open_pr 10 sprint-1 "Release sprint 1" sprint-frozen
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Add feature A" merge-to-sprint

  run_script EVENT_NAME=workflow_dispatch MODE=refresh

  [ "$status" -eq 0 ]
  remote_contains sprint-1 refs/pull/1/head
}
