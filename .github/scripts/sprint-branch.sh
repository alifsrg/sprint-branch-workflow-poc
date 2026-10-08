#!/usr/bin/env bash
# Maintains the sprint-<N> integration branch. Called by .github/workflows/sprint-branch.yml.
#
# Modes:
#   refresh    – append-only: merge main + any labelled PR not yet in sprint, plain push.
#   rebuild    – reset sprint to main, re-merge all labelled PRs, delete + recreate the branch
#                (force-push is blocked by the org ruleset).
#   new-sprint – create sprint-<N+1> from main with all labelled PRs, delete sprint-<N> if nothing
#                would be lost (i.e. everything on it is in main or in a still-labelled PR).
#   update-prs – after main moves: test-merge main into every open PR into main (except the
#                Release PR). Conflicting ones get a Conflict warning; clean, ready, same-repo
#                ones get a Branch update (merge commit, plain push). Ignores Freeze.
#
# Env: MODE, EVENT_NAME, LABEL, FREEZE_LABEL, CONFLICT_LABEL, SPRINT_NUMBER_INPUT,
#      FORCE_DELETE_PREVIOUS, GH_TOKEN, GITHUB_REPOSITORY, GITHUB_STEP_SUMMARY

set -euo pipefail

MODE="${MODE:-refresh}"
EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
LABEL="${LABEL:-merge-to-sprint}"
FREEZE_LABEL="${FREEZE_LABEL:-sprint-frozen}"
CONFLICT_LABEL="${CONFLICT_LABEL:-has-conflicts}"
SPRINT_NUMBER_INPUT="${SPRINT_NUMBER_INPUT:-}"
FORCE_DELETE_PREVIOUS="${FORCE_DELETE_PREVIOUS:-false}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
MARKER='<!-- sprint-bot -->'
CONFLICT_MARKER='<!-- sprint-bot:conflict -->' # Conflict warning, kept apart from the Refresh comment

AUTO=false
[[ "$EVENT_NAME" != "workflow_dispatch" ]] && AUTO=true

SPRINT=""        # e.g. sprint-12
ROWS=()          # summary table rows
LABELLED=()      # numbers of open labelled PRs
NEEDS_REBUILD=false

# ---------- helpers ----------

latest_sprint_number() {
  git ls-remote --heads origin 'sprint-*' \
    | sed 's#.*refs/heads/sprint-##' \
    | { grep -E '^[0-9]+$' || true; } \
    | sort -n | tail -1
}

add_row() { # <pr> <title> <status>
  local title="${2//|/\\|}"
  ROWS+=("| #$1 | $title | $3 |")
}

# Bot comment with <marker> on a PR as JSON {id, body}, empty if none.
find_comment() { # <pr> <marker>
  gh api "repos/$REPO/issues/$1/comments" --paginate \
    | jq -cs --arg m "$2" '[(add // [])[] | select(.body | startswith($m)) | {id, body}][0] // empty'
}

# Writes the bot comment with <marker>. Creates it unless <only_existing> is true; skips if unchanged.
write_comment() { # <pr> <body> <only_existing> <marker>
  local existing body="$4"$'\n'"$2"
  existing="$(find_comment "$1" "$4")"
  if [[ -z "$existing" ]]; then
    [[ "$3" == true ]] && return 0
    gh api -X POST "repos/$REPO/issues/$1/comments" -f body="$body" >/dev/null
  elif [[ "$(jq -r .body <<< "$existing")" != "$body" ]]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$(jq -r .id <<< "$existing")" -f body="$body" >/dev/null
  fi
}

upsert_comment() { write_comment "$1" "$2" false "$MARKER"; }
resolve_comment() { write_comment "$1" "$2" true "$MARKER"; } # only updates an existing bot comment
upsert_conflict_warning() { write_comment "$1" "$2" false "$CONFLICT_MARKER"; }

# Latest "Merge PR #<n>:" commit on sprint (not yet in main), empty if none.
sprint_merge_commit() { # <pr> <ref>
  git log --merges --format='%H' --grep="^Merge PR #$1:" "origin/main..$2" | head -1
}

# PR numbers merged into <ref> via the bot, unique.
merged_pr_numbers() { # <ref>
  git log --merges --format='%s' "origin/main..$1" \
    | sed -n 's/^Merge PR #\([0-9]*\):.*/\1/p' | sort -un
}

is_labelled() { # <pr>
  local n
  for n in ${LABELLED[@]+"${LABELLED[@]}"}; do [[ "$n" == "$1" ]] && return 0; done
  return 1
}

# PRs that are in sprint but no longer open + labelled (and not already shipped to main).
stale_prs() { # <ref>
  local n prev
  while read -r n; do
    [[ -z "$n" ]] && continue
    is_labelled "$n" && continue
    prev="$(sprint_merge_commit "$n" "$1")"
    # PR merged straight into main – its changes are already there, not stale.
    git merge-base --is-ancestor "$prev^2" origin/main && continue
    echo "$n"
  done < <(merged_pr_numbers "$1")
}

merge_pr() { # <pr> <title>
  local n="$1" title="$2" head prev files

  git fetch --quiet origin "pull/$n/head"
  head="$(git rev-parse FETCH_HEAD)"

  if git merge-base --is-ancestor "$head" HEAD; then
    echo "✅ #$n already up to date"
    add_row "$n" "$title" "✅ up-to-date"
    resolve_comment "$n" "### ✅ Included in \`$SPRINT\`
Latest commit \`${head:0:7}\` is merged into \`$SPRINT\`."
    return
  fi

  prev="$(sprint_merge_commit "$n" HEAD)"
  if [[ -n "$prev" ]] && ! git merge-base --is-ancestor "$prev^2" "$head"; then
    echo "⚠️ #$n was rebased/force-pushed after being merged into $SPRINT"
    add_row "$n" "$title" "⚠️ rebased – needs rebuild"
    NEEDS_REBUILD=true
    upsert_comment "$n" "### ⚠️ Not updated in \`$SPRINT\`
This PR was rebased or force-pushed after it was merged into \`$SPRINT\`, so its new commits can't be merged incrementally without duplicating history.

A maintainer needs to run the **Sprint branch** workflow manually with mode \`rebuild\`."
    return
  fi

  if git merge --no-ff -m "Merge PR #$n: $title" "$head" >/dev/null 2>&1; then
    echo "🔀 #$n merged into $SPRINT"
    add_row "$n" "$title" "🔀 merged"
    resolve_comment "$n" "### ✅ Included in \`$SPRINT\`
Latest commit \`${head:0:7}\` is merged into \`$SPRINT\`."
  else
    files="$(git diff --name-only --diff-filter=U | sed 's/^/- `/; s/$/`/')"
    git merge --abort || true
    echo "❌ #$n conflicts with $SPRINT"
    add_row "$n" "$title" "❌ conflict"
    upsert_comment "$n" "### ❌ Merge conflict with \`$SPRINT\`
Commit \`${head:0:7}\` could not be merged into \`$SPRINT\`. Conflicting files:
$files

Resolve the conflict in this PR (e.g. merge \`main\` or the conflicting PR into your branch) and push – the workflow will retry automatically."
  fi
}

load_labelled_prs() {
  LABELLED=()
  PR_LIST="$(gh pr list --repo "$REPO" --base main --state open --label "$LABEL" --limit 200 \
    --json number,title --jq 'sort_by(.number)[] | "\(.number)\t\(.title)"')"
  local n title
  while IFS=$'\t' read -r n title; do
    if [[ -n "$n" ]]; then LABELLED+=("$n"); fi
  done <<< "$PR_LIST"
}

merge_all_labelled() {
  local n title
  # fd 3 so gh/git inside the loop can't swallow the list
  while IFS=$'\t' read -r -u 3 n title; do
    if [[ -n "$n" ]]; then merge_pr "$n" "$title"; fi
  done 3<<< "$PR_LIST"
}

report_stale() { # <ref>
  local n
  for n in $(stale_prs "$1"); do
    echo "⚠️ #$n is in $SPRINT but no longer labelled/open"
    add_row "$n" "$(gh pr view "$n" --repo "$REPO" --json title --jq .title)" "⚠️ unlabelled – still in sprint"
    NEEDS_REBUILD=true
    upsert_comment "$n" "### ⚠️ Still in \`$SPRINT\`
This PR no longer has the \`$LABEL\` label (or was closed), but its changes are still in \`$SPRINT\`.

To remove them, a maintainer needs to run the **Sprint branch** workflow manually with mode \`rebuild\`."
  done
}

write_summary() { # <headline>
  {
    echo "## 🏃 Sprint branch – \`$MODE\`"
    echo
    echo "- Trigger: \`$EVENT_NAME\`"
    echo "- Branch: \`${SPRINT:-none}\`"
    echo "- $1"
    if [[ ${#ROWS[@]} -gt 0 ]]; then
      echo
      echo "| PR | Title | Status |"
      echo "|---|---|---|"
      printf '%s\n' "${ROWS[@]}"
    fi
    if [[ "$NEEDS_REBUILD" == true ]]; then
      echo
      echo "> ⚠️ Some PRs need a manual **rebuild** to bring \`$SPRINT\` back in sync with the labels."
    fi
  } >> "$SUMMARY_FILE"
}

# Commits on <ref> that new-sprint would NOT recreate: anything not in main and not part of a
# currently labelled PR (direct commits, unlabelled PRs, hand-made merges).
commits_lost_on_delete() { # <ref>
  local n heads=()
  for n in ${LABELLED[@]+"${LABELLED[@]}"}; do
    git fetch --quiet origin "+pull/$n/head:refs/remotes/pr/$n"
    heads+=("refs/remotes/pr/$n")
  done
  git rev-list --no-merges "$1" --not origin/main ${heads[@]+"${heads[@]}"}
  git log --merges --format='%H %s' "origin/main..$1" \
    | { grep -vE '^[0-9a-f]+ Merge (PR #[0-9]+:|main into sprint-)' || true; } \
    | cut -d' ' -f1
}

CONFLICT_LABEL_EXISTS=false

# Creates the Conflict warning label unless the repo already has it. Checks at most once per run.
ensure_conflict_label() {
  [[ "$CONFLICT_LABEL_EXISTS" == true ]] && return 0
  if [[ "$(gh label list --repo "$REPO" --limit 500 --json name \
        --jq "any(.[]; .name == \"$CONFLICT_LABEL\")")" != true ]]; then
    gh label create "$CONFLICT_LABEL" --repo "$REPO" --color B60205 \
      --description "Conflicts with main – merge main into the branch and resolve" >/dev/null
  fi
  CONFLICT_LABEL_EXISTS=true
}

# Test-merges main into PR <n>'s head. Gives it a Conflict warning if they conflict, otherwise a
# Branch update unless it already contains main, is a draft or comes from a fork.
check_pr() { # <pr> <title> <head branch> <is draft> <is fork> <labels, comma-separated>
  local n="$1" title="$2" branch="$3" draft="$4" fork="$5" labels="$6" head files

  git fetch --quiet origin "pull/$n/head"
  head="$(git rev-parse FETCH_HEAD)"

  if git merge-base --is-ancestor origin/main "$head"; then
    echo "✅ #$n already contains main"
    add_row "$n" "$title" "✅ up to date"
    return
  fi

  git checkout --quiet --detach "$head"
  if ! git merge --no-commit --no-ff origin/main >/dev/null 2>&1; then
    files="$(git diff --name-only --diff-filter=U | sed 's/^/- `/; s/$/`/')"
    git merge --abort || true
    echo "❌ #$n conflicts with main"
    add_row "$n" "$title" "❌ conflict – warned"
    upsert_conflict_warning "$n" "### ❌ Conflicts with \`main\`
Commit \`${head:0:7}\` no longer merges cleanly with \`main\`. Conflicting files:
$files

To resolve, merge \`main\` into your branch, fix the conflicts and push."
    if [[ ",$labels," != *",$CONFLICT_LABEL,"* ]]; then
      ensure_conflict_label
      gh pr edit "$n" --repo "$REPO" --add-label "$CONFLICT_LABEL" >/dev/null
    fi
    return
  fi

  if [[ "$draft" == true || "$fork" == true ]]; then
    git merge --abort
    echo "✅ #$n merges cleanly with main (not updated: $([[ "$draft" == true ]] && echo draft || echo fork))"
    add_row "$n" "$title" "✅ merges cleanly – $([[ "$draft" == true ]] && echo draft || echo fork), not updated"
    return
  fi

  git commit --quiet -m "Merge main into $branch"
  # Plain push: if the author pushed meanwhile it's rejected, and the next run catches up.
  if git push --quiet origin "HEAD:refs/heads/$branch" 2>/dev/null; then
    echo "🔀 #$n updated with main"
    add_row "$n" "$title" "🔀 updated"
  else
    echo "⚠️ #$n push rejected – $branch changed during the run"
    add_row "$n" "$title" "⚠️ push rejected – retried on the next run"
  fi
}

is_frozen() {
  local count
  count="$(gh pr list --repo "$REPO" --base main --head "$SPRINT" --state open --label "$FREEZE_LABEL" \
    --json number --jq 'length')"
  [[ "$count" -gt 0 ]]
}

# ---------- modes ----------

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git fetch --quiet --prune origin \
  '+refs/heads/main:refs/remotes/origin/main' \
  '+refs/heads/sprint-*:refs/remotes/origin/sprint-*'

LATEST="$(latest_sprint_number)"

if [[ "$MODE" == "refresh" || "$MODE" == "rebuild" ]]; then
  if [[ -z "$LATEST" ]]; then
    if [[ "$AUTO" == true ]]; then
      echo "ℹ️ No sprint branch exists yet – nothing to do."
      write_summary "ℹ️ No sprint branch exists yet – nothing to do."
      exit 0
    fi
    echo "❌ No sprint branch exists. Run this workflow with mode 'new-sprint' first."
    exit 1
  fi
  SPRINT="sprint-$LATEST"

  FREEZE_NOTE="Not frozen"
  if is_frozen; then
    if [[ "$AUTO" == true ]]; then
      echo "🧊 $SPRINT is frozen (release PR has '$FREEZE_LABEL') – skipping."
      write_summary "🧊 Frozen – release PR has \`$FREEZE_LABEL\`; no changes made."
      exit 0
    fi
    FREEZE_NOTE="⚠️ Frozen, but running anyway because this was triggered manually"
  fi
fi

case "$MODE" in
  refresh)
    git checkout --quiet -B "$SPRINT" "origin/$SPRINT"

    if ! git merge --no-edit -m "Merge main into $SPRINT" origin/main >/dev/null 2>&1; then
      git merge --abort || true
      echo "❌ main conflicts with $SPRINT – resolve manually or run 'rebuild'."
      write_summary "❌ \`main\` conflicts with \`$SPRINT\` – resolve manually or run \`rebuild\`."
      exit 1
    fi

    load_labelled_prs
    merge_all_labelled
    report_stale HEAD

    git push --quiet origin "HEAD:refs/heads/$SPRINT"
    echo "✅ $SPRINT refreshed"
    write_summary "$FREEZE_NOTE"
    ;;

  rebuild)
    OLD_SHA="$(git rev-parse "origin/$SPRINT")"
    load_labelled_prs
    STALE_BEFORE="$(stale_prs "origin/$SPRINT")"

    git checkout --quiet -B "$SPRINT" origin/main
    merge_all_labelled

    if git diff --quiet "$OLD_SHA" HEAD; then
      echo "✅ Rebuilt $SPRINT has the same content as the current one – leaving it untouched."
      write_summary "✅ Rebuild produced identical content – \`$SPRINT\` left untouched. $FREEZE_NOTE"
      exit 0
    fi

    RELEASE_PR="$(gh pr list --repo "$REPO" --base main --head "$SPRINT" --state open --json number --jq '.[0].number // empty')"

    # Force-push is blocked org-wide (ruleset "protect-all-branch"), so delete + recreate instead.
    # The lease makes the delete fail if someone pushed to the branch since this run started.
    git push --quiet --force-with-lease="refs/heads/$SPRINT:$OLD_SHA" origin --delete "$SPRINT"
    git push --quiet origin "HEAD:refs/heads/$SPRINT"

    for n in $STALE_BEFORE; do
      add_row "$n" "$(gh pr view "$n" --repo "$REPO" --json title --jq .title)" "🧹 removed"
      resolve_comment "$n" "### 🧹 Removed from \`$SPRINT\`
\`$SPRINT\` was rebuilt and this PR is no longer part of it."
    done

    HEADLINE="⚠️ \`$SPRINT\` was rebuilt from \`main\` (branch deleted and recreated)."
    if [[ -n "$RELEASE_PR" ]]; then
      HEADLINE="$HEADLINE Release PR #$RELEASE_PR was closed by GitHub when the branch was deleted – open a new one."
    fi
    echo "✅ $SPRINT rebuilt from main (deleted + recreated)"
    write_summary "$HEADLINE $FREEZE_NOTE"
    ;;

  new-sprint)
    TARGET="${SPRINT_NUMBER_INPUT:-$(( ${LATEST:-0} + 1 ))}"
    if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
      echo "❌ Invalid sprint number: $TARGET"
      exit 1
    fi
    SPRINT="sprint-$TARGET"

    if git ls-remote --exit-code --heads origin "$SPRINT" >/dev/null; then
      echo "❌ $SPRINT already exists."
      exit 1
    fi

    load_labelled_prs

    PREVIOUS=""
    if [[ -n "$LATEST" && "$LATEST" != "$TARGET" ]]; then
      PREVIOUS="sprint-$LATEST"
      LOST="$(commits_lost_on_delete "origin/$PREVIOUS")"
      if [[ -n "$LOST" && "$FORCE_DELETE_PREVIOUS" != "true" ]]; then
        echo "❌ Deleting $PREVIOUS would lose commits that are neither in main nor in a labelled PR:"
        git log --no-walk --oneline $LOST
        echo "   Release $PREVIOUS first, or re-run with force_delete_previous=true to discard them."
        write_summary "❌ \`$PREVIOUS\` has commits that are neither in \`main\` nor in a labelled PR – aborted. Release it first, or use \`force_delete_previous\` to discard them."
        exit 1
      fi
    fi

    git checkout --quiet -B "$SPRINT" origin/main
    merge_all_labelled

    git push --quiet origin "HEAD:refs/heads/$SPRINT"
    echo "✅ Created $SPRINT"

    HEADLINE="✅ Created \`$SPRINT\` from \`main\`."
    if [[ -n "$PREVIOUS" ]]; then
      git push --quiet origin --delete "$PREVIOUS"
      echo "🗑️ Deleted $PREVIOUS"
      HEADLINE="$HEADLINE 🗑️ Deleted \`$PREVIOUS\`."
    fi
    write_summary "$HEADLINE"
    ;;

  update-prs)
    PR_LIST="$(gh pr list --repo "$REPO" --base main --state open --limit 200 \
      --json number,title,headRefName,isDraft,isCrossRepository,labels \
      --jq 'sort_by(.number)[] | [.number, .title, .headRefName, .isDraft, .isCrossRepository,
              ([.labels[].name] | join(","))] | @tsv')"

    # fd 3 so gh/git inside the loop can't swallow the list
    while IFS=$'\t' read -r -u 3 n title head_ref draft cross_repo labels; do
      [[ -z "$n" ]] && continue
      if [[ "$head_ref" =~ ^sprint-[0-9]+$ && "$cross_repo" == false ]]; then
        echo "⏭️ #$n is the Release PR – skipping"
        add_row "$n" "$title" "⏭️ skipped – Release PR"
        continue
      fi
      check_pr "$n" "$title" "$head_ref" "$draft" "$cross_repo" "$labels"
    done 3<<< "$PR_LIST"

    write_summary "Merged \`main\` into every open PR into \`main\` that merges cleanly, and warned the ones that conflict."
    ;;

  *)
    echo "❌ Unknown mode: $MODE"
    exit 1
    ;;
esac
