#!/usr/bin/env bats
# Rebuild: recreate the Sprint branch from main plus the current Sprint candidates.

load helpers

setup() {
  setup_world
  create_sprint 1
}

@test "drops a Stale PR and recreates the Sprint branch from main and current Sprint candidates" {
  commit feat-a a.txt "a" "Add a"
  commit feat-b b.txt "b" "Add b"
  open_pr 1 feat-a "Feature A" merge-to-sprint
  open_pr 2 feat-b "Feature B" merge-to-sprint
  run_script
  remove_label 1 merge-to-sprint
  run_script

  run_script EVENT_NAME=workflow_dispatch MODE=rebuild

  [ "$status" -eq 0 ]
  [ "$(remote_subjects sprint-1)" = "$(printf 'Add b\nMerge PR #2: Feature B')" ]
  [ "$(gh_writes 1 | tail -1 | jq -r .op)" = comment.edit ]
  [[ "$(last_comment 1)" == *"Removed from \`sprint-1\`"* ]]
}

@test "leaves the Sprint branch untouched when the rebuilt content is identical" {
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A" merge-to-sprint
  run_script
  before="$(remote_sha sprint-1)"

  # A different date makes any recreated commit get a new SHA.
  run_script EVENT_NAME=workflow_dispatch MODE=rebuild \
    GIT_AUTHOR_DATE=2001-01-01T00:00:00Z GIT_COMMITTER_DATE=2001-01-01T00:00:00Z

  [ "$status" -eq 0 ]
  [ "$(remote_sha sprint-1)" = "$before" ]
  [ -z "$(gh_writes)" ]
}
