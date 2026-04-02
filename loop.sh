#!/usr/bin/env bash

set -uo pipefail

REPO_PATH="${REPO_PATH:-/absolute/path/to/target-repo}"
GITHUB_REPO="${GITHUB_REPO:-owner/repo}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-900}"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
GH_BIN="${GH_BIN:-gh}"
TARGET_AGENT_FILE="${TARGET_AGENT_FILE:-$REPO_PATH/AGENT.md}"
VERIFY_COMMAND="${VERIFY_COMMAND:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_LOG="${RESULTS_LOG:-$SCRIPT_DIR/results.log}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

RUN_ID="${RUN_ID:-autosde-$(date -u '+%Y%m%dT%H%M%SZ')-$$}"

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

note() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

sanitize_single_line() {
  printf '%s' "$*" | tr '\t\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

ensure_runtime_files() {
  mkdir -p "$LOG_DIR"

  if [ ! -f "$RESULTS_LOG" ]; then
    printf 'timestamp\tissue\tbranch\tstatus\tdescription\n' >"$RESULTS_LOG"
  fi
}

log_result() {
  local issue="${1:--}"
  local branch="${2:--}"
  local status="${3:-crashed}"
  local description
  description="$(sanitize_single_line "${4:-}")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" \
    "$issue" \
    "$branch" \
    "$status" \
    "$description" >>"$RESULTS_LOG"
}

require_command() {
  local missing=0
  local cmd

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      note "Missing required command: $cmd"
      missing=1
    fi
  done

  return "$missing"
}

search_tool() {
  if command -v rg >/dev/null 2>&1; then
    printf 'rg'
  else
    printf 'grep'
  fi
}

default_branch() {
  local branch

  branch="$("$GH_BIN" repo view "$GITHUB_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"

  if [ -n "$branch" ] && [ "$branch" != "null" ]; then
    printf '%s' "$branch"
    return 0
  fi

  branch="$(git -C "$REPO_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"

  if [ -n "$branch" ]; then
    printf '%s' "$branch"
    return 0
  fi

  if git -C "$REPO_PATH" rev-parse --verify origin/main >/dev/null 2>&1; then
    printf 'main'
  else
    printf 'master'
  fi
}

agent_login() {
  "$GH_BIN" api user --jq '.login'
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g' |
    cut -c1-40
}

release_issue() {
  local issue_number="$1"
  local login="$2"

  "$GH_BIN" issue edit "$issue_number" --repo "$GITHUB_REPO" --remove-assignee "$login" >/dev/null 2>&1 || true
}

checkout_clean_default_branch() {
  local branch="$1"

  git -C "$REPO_PATH" fetch origin "$branch" --prune >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" checkout "$branch" >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" reset --hard "origin/$branch" >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" clean -fd >/dev/null 2>&1 || return 1
}

create_issue_branch() {
  local branch="$1"
  local base="$2"

  git -C "$REPO_PATH" checkout -B "$branch" "origin/$base" >/dev/null 2>&1
}

select_issue_number() {
  "$GH_BIN" issue list \
    --repo "$GITHUB_REPO" \
    --state open \
    --label agent \
    --limit 100 \
    --json number,labels,assignees \
    --jq '
      map(select((.assignees | length) == 0))
      | sort_by(
          (
            if any(.labels[].name; . == "bug") then 0
            elif any(.labels[].name; . == "feature") then 1
            elif any(.labels[].name; . == "refactor") then 2
            elif any(.labels[].name; . == "chore") then 3
            else 4
            end
          ),
          .number
        )
      | .[0].number // empty
    ' 2>/dev/null
}

issue_field() {
  local issue_number="$1"
  local field="$2"

  "$GH_BIN" issue view "$issue_number" --repo "$GITHUB_REPO" --json "$field" --jq ".$field"
}

claim_issue() {
  local issue_number="$1"
  local login="$2"

  "$GH_BIN" issue edit "$issue_number" --repo "$GITHUB_REPO" --add-assignee "$login" >/dev/null 2>&1 || return 1
  "$GH_BIN" issue comment "$issue_number" --repo "$GITHUB_REPO" --body "I'm picking this up." >/dev/null 2>&1 || return 1
}

build_prompt_file() {
  local prompt_file="$1"
  local issue_number="$2"
  local issue_title="$3"
  local issue_url="$4"
  local issue_body="$5"
  local branch="$6"
  local retry_feedback="${7:-}"

  {
    printf 'You are working inside the repository at %s.\n' "$REPO_PATH"
    printf 'Stay on branch %s.\n\n' "$branch"
    printf 'Follow the repository AGENT.md instructions below exactly.\n\n'
    printf '----- BEGIN AGENT.md -----\n'
    cat "$TARGET_AGENT_FILE"
    printf '\n----- END AGENT.md -----\n\n'
    printf 'Current issue:\n'
    printf '#%s: %s\n' "$issue_number" "$issue_title"
    printf '%s\n\n' "$issue_url"
    printf 'Issue body:\n%s\n\n' "$issue_body"
    printf 'Harness expectations:\n'
    printf -- '- Work only in this repository.\n'
    printf -- '- Use GitHub CLI if you need to comment on the issue or inspect metadata.\n'
    printf -- '- Leave the branch ready for verification by the harness when you finish.\n'

    if [ -n "$retry_feedback" ]; then
      printf '\nRetry context:\n%s\n' "$retry_feedback"
    fi
  } >"$prompt_file"
}

run_claude_prompt() {
  local prompt_file="$1"
  local task_log="$2"
  local prompt_text

  prompt_text="$(cat "$prompt_file")"

  {
    printf '=== %s Claude invocation started ===\n' "$(timestamp)"

    if "$CLAUDE_BIN" -p --dangerously-skip-permissions "$prompt_text"; then
      printf '\n=== %s Claude invocation finished successfully ===\n' "$(timestamp)"
      return 0
    fi

    printf '\n=== %s falling back to --print ===\n' "$(timestamp)"

    if "$CLAUDE_BIN" --print --dangerously-skip-permissions "$prompt_text"; then
      printf '\n=== %s Claude invocation finished successfully ===\n' "$(timestamp)"
      return 0
    fi

    printf '\n=== %s attempting stdin fallback ===\n' "$(timestamp)"

    if cat "$prompt_file" | "$CLAUDE_BIN" -p --dangerously-skip-permissions; then
      printf '\n=== %s Claude invocation finished successfully ===\n' "$(timestamp)"
      return 0
    fi

    printf '\n=== %s attempting stdin + --print fallback ===\n' "$(timestamp)"

    if cat "$prompt_file" | "$CLAUDE_BIN" --print --dangerously-skip-permissions; then
      printf '\n=== %s Claude invocation finished successfully ===\n' "$(timestamp)"
      return 0
    fi

    printf '\n=== %s Claude invocation failed ===\n' "$(timestamp)"
    return 1
  } >>"$task_log" 2>&1
}

detect_js_runner() {
  if [ -f "$REPO_PATH/bun.lockb" ] || [ -f "$REPO_PATH/bun.lock" ]; then
    printf 'bun'
    return 0
  fi

  if [ -f "$REPO_PATH/pnpm-lock.yaml" ]; then
    printf 'pnpm'
    return 0
  fi

  if [ -f "$REPO_PATH/yarn.lock" ]; then
    printf 'yarn'
    return 0
  fi

  printf 'npm'
}

detect_verify_command() {
  local runner

  if [ -n "$VERIFY_COMMAND" ]; then
    printf '%s' "$VERIFY_COMMAND"
    return 0
  fi

  if [ -f "$REPO_PATH/Makefile" ]; then
    if grep -Eq '^(ci):' "$REPO_PATH/Makefile"; then
      printf 'make ci'
      return 0
    fi

    if grep -Eq '^(test):' "$REPO_PATH/Makefile"; then
      printf 'make test'
      return 0
    fi
  fi

  if [ -f "$REPO_PATH/package.json" ]; then
    runner="$(detect_js_runner)"

    if grep -Eq '"ci"[[:space:]]*:' "$REPO_PATH/package.json"; then
      case "$runner" in
        yarn) printf 'yarn ci' ;;
        *) printf '%s run ci' "$runner" ;;
      esac
      return 0
    fi

    if grep -Eq '"test"[[:space:]]*:' "$REPO_PATH/package.json"; then
      case "$runner" in
        yarn) printf 'yarn test' ;;
        *) printf '%s run test' "$runner" ;;
      esac
      return 0
    fi
  fi

  if [ -f "$REPO_PATH/pytest.ini" ] || [ -f "$REPO_PATH/conftest.py" ]; then
    printf 'pytest'
    return 0
  fi

  if [ -f "$REPO_PATH/pyproject.toml" ] && grep -Eq 'pytest|tool\.poetry|project' "$REPO_PATH/pyproject.toml"; then
    printf 'pytest'
    return 0
  fi

  if [ -f "$REPO_PATH/Cargo.toml" ]; then
    printf 'cargo test'
    return 0
  fi

  if [ -f "$REPO_PATH/go.mod" ]; then
    printf 'go test ./...'
    return 0
  fi

  if [ -f "$REPO_PATH/bin/rails" ]; then
    printf 'bin/rails test'
    return 0
  fi

  if [ -f "$REPO_PATH/Gemfile" ] && [ -d "$REPO_PATH/spec" ]; then
    printf 'bundle exec rspec'
    return 0
  fi

  return 1
}

run_verification() {
  local verify_cmd="$1"
  local task_log="$2"

  {
    printf '\n=== %s Verification command ===\n%s\n' "$(timestamp)" "$verify_cmd"
    (
      cd "$REPO_PATH" &&
        bash -lc "$verify_cmd"
    )
    local status=$?
    printf '\n=== %s Verification exit code: %s ===\n' "$(timestamp)" "$status"
    return "$status"
  } >>"$task_log" 2>&1
}

branch_has_changes() {
  local base="$1"

  if git -C "$REPO_PATH" diff --quiet "origin/$base...HEAD" && [ -z "$(git -C "$REPO_PATH" status --porcelain)" ]; then
    return 1
  fi

  return 0
}

commit_changes_if_needed() {
  local issue_number="$1"
  local issue_title="$2"

  if [ -n "$(git -C "$REPO_PATH" status --porcelain)" ]; then
    git -C "$REPO_PATH" add -A
    git -C "$REPO_PATH" commit -m "[AutoSDE] #$issue_number ${issue_title}" >/dev/null 2>&1 || return 1
  fi

  return 0
}

push_branch() {
  local branch="$1"

  git -C "$REPO_PATH" push -u origin "$branch" --force-with-lease >/dev/null 2>&1
}

pr_summary() {
  local base="$1"
  local summary

  summary="$(git -C "$REPO_PATH" diff --stat --compact-summary "origin/$base...HEAD" 2>/dev/null || true)"

  if [ -z "$summary" ]; then
    summary="$(git -C "$REPO_PATH" log --oneline "origin/$base..HEAD" 2>/dev/null || true)"
  fi

  printf '%s' "$summary"
}

create_pr() {
  local branch="$1"
  local base="$2"
  local issue_number="$3"
  local issue_title="$4"
  local reviewer="$5"
  local body
  local summary
  local pr_url

  summary="$(pr_summary "$base")"

  body=$(
    cat <<EOF
Automated implementation for #$issue_number.

What changed:
$summary

Closes #$issue_number
EOF
  )

  pr_url="$("$GH_BIN" pr create \
    --repo "$GITHUB_REPO" \
    --base "$base" \
    --head "$branch" \
    --title "[AutoSDE] $issue_title" \
    --body "$body" 2>/dev/null)" || return 1

  "$GH_BIN" pr edit "$pr_url" --repo "$GITHUB_REPO" --add-reviewer "$reviewer" >/dev/null 2>&1 || true

  printf '%s' "$pr_url"
}

cleanup_local_branch() {
  local branch="$1"
  local base="$2"

  git -C "$REPO_PATH" checkout "$base" >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" reset --hard "origin/$base" >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" clean -fd >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" branch -D "$branch" >/dev/null 2>&1 || true
}

discard_branch() {
  local branch="$1"
  local base="$2"

  git -C "$REPO_PATH" checkout "$base" >/dev/null 2>&1 || true
  git -C "$REPO_PATH" reset --hard "origin/$base" >/dev/null 2>&1 || true
  git -C "$REPO_PATH" clean -fd >/dev/null 2>&1 || true
  git -C "$REPO_PATH" branch -D "$branch" >/dev/null 2>&1 || true
  git -C "$REPO_PATH" push origin --delete "$branch" >/dev/null 2>&1 || true
}

failure_excerpt() {
  local task_log="$1"

  tail -n 60 "$task_log" | tail -c 3500
}

comment_failure() {
  local issue_number="$1"
  local branch="$2"
  local excerpt="$3"

  "$GH_BIN" issue comment "$issue_number" --repo "$GITHUB_REPO" --body "$(cat <<EOF
I tried to address this on \`$branch\`, but verification failed twice, so I discarded the branch.

Latest log excerpt:
\`\`\`
$excerpt
\`\`\`
EOF
)" >/dev/null 2>&1 || true
}

comment_crash() {
  local issue_number="$1"
  local branch="$2"
  local reason="$3"

  "$GH_BIN" issue comment "$issue_number" --repo "$GITHUB_REPO" --body "$(cat <<EOF
I picked this up on \`$branch\`, but the harness crashed before it could finish.

Reason:
$reason
EOF
)" >/dev/null 2>&1 || true
}

comment_discarded() {
  local issue_number="$1"
  local branch="$2"
  local reason="$3"

  "$GH_BIN" issue comment "$issue_number" --repo "$GITHUB_REPO" --body "$(cat <<EOF
I picked this up on \`$branch\`, but I discarded the branch.

Reason:
$reason
EOF
)" >/dev/null 2>&1 || true
}

comment_success() {
  local issue_number="$1"
  local pr_url="$2"

  "$GH_BIN" issue comment "$issue_number" --repo "$GITHUB_REPO" --body "$(cat <<EOF
Implemented this and opened a PR for review:

$pr_url
EOF
)" >/dev/null 2>&1 || true
}

detect_benchmark_command() {
  local runner

  if [ -f "$REPO_PATH/Makefile" ]; then
    if grep -Eq '^(benchmark):' "$REPO_PATH/Makefile"; then
      printf 'make benchmark'
      return 0
    fi

    if grep -Eq '^(bench):' "$REPO_PATH/Makefile"; then
      printf 'make bench'
      return 0
    fi
  fi

  if [ -f "$REPO_PATH/package.json" ]; then
    runner="$(detect_js_runner)"

    if grep -Eq '"benchmark"[[:space:]]*:' "$REPO_PATH/package.json"; then
      case "$runner" in
        yarn) printf 'yarn benchmark' ;;
        *) printf '%s run benchmark' "$runner" ;;
      esac
      return 0
    fi

    if grep -Eq '"bench"[[:space:]]*:' "$REPO_PATH/package.json"; then
      case "$runner" in
        yarn) printf 'yarn bench' ;;
        *) printf '%s run bench' "$runner" ;;
      esac
      return 0
    fi
  fi

  return 1
}

run_audit_check() {
  local output_file="$1"

  if [ -f "$REPO_PATH/package.json" ]; then
    local runner
    runner="$(detect_js_runner)"

    case "$runner" in
      bun)
        if command -v bun >/dev/null 2>&1; then
          (cd "$REPO_PATH" && bun audit) >"$output_file" 2>&1 || true
          return 0
        fi
        ;;
      pnpm)
        if command -v pnpm >/dev/null 2>&1; then
          (cd "$REPO_PATH" && pnpm audit) >"$output_file" 2>&1 || true
          return 0
        fi
        ;;
      yarn)
        if command -v yarn >/dev/null 2>&1; then
          (cd "$REPO_PATH" && yarn audit) >"$output_file" 2>&1 || true
          return 0
        fi
        ;;
      *)
        if command -v npm >/dev/null 2>&1; then
          (cd "$REPO_PATH" && npm audit) >"$output_file" 2>&1 || true
          return 0
        fi
        ;;
    esac
  fi

  if [ -f "$REPO_PATH/Cargo.lock" ] && command -v cargo-audit >/dev/null 2>&1; then
    (cd "$REPO_PATH" && cargo audit) >"$output_file" 2>&1 || true
    return 0
  fi

  if [ -f "$REPO_PATH/Gemfile.lock" ] && command -v bundle-audit >/dev/null 2>&1; then
    (cd "$REPO_PATH" && bundle audit check) >"$output_file" 2>&1 || true
    return 0
  fi

  if { [ -f "$REPO_PATH/requirements.txt" ] || [ -f "$REPO_PATH/pyproject.toml" ]; } && command -v pip-audit >/dev/null 2>&1; then
    (cd "$REPO_PATH" && pip-audit) >"$output_file" 2>&1 || true
    return 0
  fi

  return 1
}

create_proposed_issue() {
  local title="$1"
  local body="$2"
  local priority="$3"

  "$GH_BIN" issue create \
    --repo "$GITHUB_REPO" \
    --title "$title" \
    --body "$body" \
    --label agent \
    --label agent-proposed \
    --label "$priority" >/dev/null 2>&1
}

research_mode() {
  local tool
  local todo_hits
  local smell_hits
  local benchmark_cmd
  local benchmark_log
  local audit_log

  note "No unclaimed agent issues found. Entering research mode."

  tool="$(search_tool)"

  audit_log="$(mktemp)"
  benchmark_log="$(mktemp)"

  if run_audit_check "$audit_log"; then
    if grep -Eiq 'vulnerab|advisories|severity|critical|high' "$audit_log"; then
      create_proposed_issue \
        "Investigate dependency vulnerabilities reported by automated audit" \
        "$(cat <<EOF
Research mode found dependency audit output that appears actionable.

Audit excerpt:
\`\`\`
$(tail -n 40 "$audit_log")
\`\`\`
EOF
)" \
        "bug"
      rm -f "$audit_log" "$benchmark_log"
      return 0
    fi
  fi

  if detect_benchmark_command >/dev/null 2>&1; then
    benchmark_cmd="$(detect_benchmark_command)"

    if ! (
      cd "$REPO_PATH" &&
        bash -lc "$benchmark_cmd"
    ) >"$benchmark_log" 2>&1; then
      create_proposed_issue \
        "Fix failing benchmark command discovered in research mode" \
        "$(cat <<EOF
Research mode found an existing benchmark command that does not complete successfully.

Command:
\`$benchmark_cmd\`

Output excerpt:
\`\`\`
$(tail -n 40 "$benchmark_log")
\`\`\`
EOF
)" \
        "bug"
      rm -f "$audit_log" "$benchmark_log"
      return 0
    fi

    if grep -Eiq 'regression|slower|degraded|failed benchmark' "$benchmark_log"; then
      create_proposed_issue \
        "Investigate benchmark regression surfaced in research mode" \
        "$(cat <<EOF
Research mode ran the repository benchmark command and found output that may indicate a regression.

Command:
\`$benchmark_cmd\`

Output excerpt:
\`\`\`
$(tail -n 40 "$benchmark_log")
\`\`\`
EOF
)" \
        "bug"
      rm -f "$audit_log" "$benchmark_log"
      return 0
    fi
  fi

  if [ "$tool" = "rg" ]; then
    todo_hits="$(cd "$REPO_PATH" && rg -n --glob '!.git' --glob '!node_modules' --glob '!vendor' 'TODO|FIXME' . 2>/dev/null | head -n 10)"
    smell_hits="$(cd "$REPO_PATH" && rg -n --glob '!.git' --glob '!node_modules' --glob '!vendor' 'console\.log|debugger|it\.skip|describe\.skip|skip\(' . 2>/dev/null | head -n 10)"
  else
    todo_hits="$(cd "$REPO_PATH" && grep -RInE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor 'TODO|FIXME' . 2>/dev/null | head -n 10)"
    smell_hits="$(cd "$REPO_PATH" && grep -RInE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor 'console\.log|debugger|it\.skip|describe\.skip|skip\(' . 2>/dev/null | head -n 10)"
  fi

  if [ -n "$todo_hits" ]; then
    create_proposed_issue \
      "Review TODO and FIXME markers discovered in research mode" \
      "$(cat <<EOF
Research mode found TODO/FIXME markers that may be worth turning into concrete work.

Matches:
\`\`\`
$todo_hits
\`\`\`
EOF
)" \
      "refactor"
    rm -f "$audit_log" "$benchmark_log"
    return 0
  fi

  if [ -n "$smell_hits" ]; then
    create_proposed_issue \
      "Clean up obvious code smells discovered in research mode" \
      "$(cat <<EOF
Research mode found code smells that look actionable.

Matches:
\`\`\`
$smell_hits
\`\`\`
EOF
)" \
      "refactor"
    rm -f "$audit_log" "$benchmark_log"
    return 0
  fi

  rm -f "$audit_log" "$benchmark_log"
  note "Research mode found nothing actionable. Sleeping for $SLEEP_INTERVAL seconds."
  sleep "$SLEEP_INTERVAL"
}

process_issue() {
  local issue_number="$1"
  local login="$2"
  local base_branch="$3"
  local reviewer="$4"
  local issue_title
  local issue_body
  local issue_url
  local issue_slug
  local branch
  local verify_cmd
  local task_log
  local prompt_file
  local retry_prompt_file
  local retry_context
  local pr_url
  local excerpt

  issue_title="$(issue_field "$issue_number" title 2>/dev/null || true)"
  issue_body="$(issue_field "$issue_number" body 2>/dev/null || true)"
  issue_url="$(issue_field "$issue_number" url 2>/dev/null || true)"

  if [ -z "$issue_title" ]; then
    log_result "$issue_number" "-" "crashed" "Unable to load issue details"
    return 1
  fi

  issue_slug="$(slugify "$issue_title")"
  [ -n "$issue_slug" ] || issue_slug="task"
  branch="autosde/${issue_number}-${issue_slug}"
  task_log="$LOG_DIR/issue-${issue_number}-$(date -u '+%Y%m%dT%H%M%SZ').log"

  if ! claim_issue "$issue_number" "$login"; then
    log_result "$issue_number" "$branch" "crashed" "Unable to claim issue"
    return 1
  fi

  if ! checkout_clean_default_branch "$base_branch"; then
    comment_crash "$issue_number" "$branch" "Unable to reset the target repository to origin/$base_branch."
    release_issue "$issue_number" "$login"
    log_result "$issue_number" "$branch" "crashed" "Unable to reset target repository"
    return 1
  fi

  if ! create_issue_branch "$branch" "$base_branch"; then
    comment_crash "$issue_number" "$branch" "Unable to create the working branch."
    release_issue "$issue_number" "$login"
    log_result "$issue_number" "$branch" "crashed" "Unable to create working branch"
    return 1
  fi

  if ! verify_cmd="$(detect_verify_command)"; then
    comment_discarded "$issue_number" "$branch" "No verification command was configured or auto-detected."
    release_issue "$issue_number" "$login"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "discarded" "No verification command configured or detected"
    return 0
  fi

  if [ ! -f "$TARGET_AGENT_FILE" ]; then
    comment_discarded "$issue_number" "$branch" "The target repository is missing AGENT.md, so the harness cannot run the agent safely."
    release_issue "$issue_number" "$login"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "discarded" "Target repository is missing AGENT.md"
    return 0
  fi

  prompt_file="$(mktemp)"
  build_prompt_file "$prompt_file" "$issue_number" "$issue_title" "$issue_url" "$issue_body" "$branch"

  if ! run_claude_prompt "$prompt_file" "$task_log"; then
    comment_crash "$issue_number" "$branch" "Claude Code failed before a verified change was produced."
    release_issue "$issue_number" "$login"
    rm -f "$prompt_file"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "crashed" "Claude invocation failed"
    return 1
  fi

  rm -f "$prompt_file"

  if ! branch_has_changes "$base_branch"; then
    comment_discarded "$issue_number" "$branch" "No code changes were produced, so there was nothing to verify or submit."
    release_issue "$issue_number" "$login"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "discarded" "No code changes were produced"
    return 0
  fi

  if ! run_verification "$verify_cmd" "$task_log"; then
    retry_context="$(cat <<EOF
The first verification attempt failed.

Verification command:
$verify_cmd

Failure excerpt:
$(failure_excerpt "$task_log")
EOF
)"

    retry_prompt_file="$(mktemp)"
    build_prompt_file "$retry_prompt_file" "$issue_number" "$issue_title" "$issue_url" "$issue_body" "$branch" "$retry_context"

    if ! run_claude_prompt "$retry_prompt_file" "$task_log"; then
      excerpt="$(failure_excerpt "$task_log")"
      comment_failure "$issue_number" "$branch" "$excerpt"
      release_issue "$issue_number" "$login"
      rm -f "$retry_prompt_file"
      discard_branch "$branch" "$base_branch"
      log_result "$issue_number" "$branch" "discarded" "Claude retry failed after initial verification failure"
      return 0
    fi

    rm -f "$retry_prompt_file"

    if ! run_verification "$verify_cmd" "$task_log"; then
      excerpt="$(failure_excerpt "$task_log")"
      comment_failure "$issue_number" "$branch" "$excerpt"
      release_issue "$issue_number" "$login"
      discard_branch "$branch" "$base_branch"
      log_result "$issue_number" "$branch" "discarded" "Verification failed twice"
      return 0
    fi
  fi

  if ! commit_changes_if_needed "$issue_number" "$issue_title"; then
    comment_crash "$issue_number" "$branch" "Verification passed, but the harness could not create a commit."
    release_issue "$issue_number" "$login"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "crashed" "Unable to commit changes"
    return 1
  fi

  if ! push_branch "$branch"; then
    comment_crash "$issue_number" "$branch" "Verification passed, but the harness could not push the branch."
    release_issue "$issue_number" "$login"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "crashed" "Unable to push branch"
    return 1
  fi

  if ! pr_url="$(create_pr "$branch" "$base_branch" "$issue_number" "$issue_title" "$reviewer")"; then
    comment_crash "$issue_number" "$branch" "The branch was pushed, but PR creation failed."
    log_result "$issue_number" "$branch" "crashed" "Unable to create PR after push"
    return 1
  fi

  comment_success "$issue_number" "$pr_url"
  cleanup_local_branch "$branch" "$base_branch" || true
  log_result "$issue_number" "$branch" "pr-created" "Created PR $pr_url"
  return 0
}

run_iteration() {
  local login
  local base_branch
  local reviewer
  local issue_number

  if ! require_command "$GH_BIN" git "$CLAUDE_BIN"; then
    log_result "-" "-" "crashed" "Missing required command(s)"
    sleep "$SLEEP_INTERVAL"
    return 1
  fi

  if [ ! -d "$REPO_PATH/.git" ]; then
    log_result "-" "-" "crashed" "REPO_PATH is not a git repository: $REPO_PATH"
    sleep "$SLEEP_INTERVAL"
    return 1
  fi

  login="$(agent_login 2>/dev/null || true)"
  base_branch="$(default_branch)"
  reviewer="${GITHUB_REPO%%/*}"

  if [ -z "$login" ] || [ -z "$base_branch" ]; then
    log_result "-" "-" "crashed" "Unable to determine GitHub login or default branch"
    sleep "$SLEEP_INTERVAL"
    return 1
  fi

  issue_number="$(select_issue_number)"

  if [ -z "$issue_number" ]; then
    research_mode
    return 0
  fi

  process_issue "$issue_number" "$login" "$base_branch" "$reviewer"
}

main() {
  ensure_runtime_files
  note "AutoSDE loop starting for $GITHUB_REPO using $REPO_PATH"

  while true; do
    run_iteration || true
  done
}

main "$@"
