#!/usr/bin/env bats
# Rollover (mode new-sprint): start sprint-<N+1> from main plus current Sprint candidates.

load helpers

setup() {
  setup_world
  create_sprint 1
  commit feat-a a.txt "a" "Add a"
  open_pr 1 feat-a "Feature A" merge-to-sprint
  run_script
}

@test "creates the next Sprint branch from main and current Sprint candidates and deletes the previous one" {
  run_script EVENT_NAME=workflow_dispatch MODE=new-sprint

  [ "$status" -eq 0 ]
  [ "$(remote_subjects sprint-2)" = "$(printf 'Add a\nMerge PR #1: Feature A')" ]
  run ! remote_has_branch sprint-1
}

@test "refuses and deletes nothing when the previous Sprint branch has commits that would be lost" {
  checkout_sprint 1
  commit sprint-1 direct.txt "direct" "Direct commit on sprint"
  before="$(remote_sha sprint-1)"

  run_script EVENT_NAME=workflow_dispatch MODE=new-sprint

  [ "$status" -eq 1 ]
  [ "$(remote_sha sprint-1)" = "$before" ]
  run ! remote_has_branch sprint-2
}

@test "proceeds with force_delete_previous when the previous Sprint branch has commits that would be lost" {
  checkout_sprint 1
  commit sprint-1 direct.txt "direct" "Direct commit on sprint"

  run_script EVENT_NAME=workflow_dispatch MODE=new-sprint FORCE_DELETE_PREVIOUS=true

  [ "$status" -eq 0 ]
  remote_contains sprint-2 refs/pull/1/head
  run ! remote_has_branch sprint-1
}

@test "fails when the target Sprint branch already exists" {
  before="$(remote_sha sprint-1)"

  run_script EVENT_NAME=workflow_dispatch MODE=new-sprint SPRINT_NUMBER_INPUT=1

  [ "$status" -eq 1 ]
  [[ "$output" == *"sprint-1 already exists"* ]]
  [ "$(remote_sha sprint-1)" = "$before" ]
}
