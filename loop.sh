#!/usr/bin/env bash

set -uo pipefail

_source="${BASH_SOURCE[0]}"
while [ -L "$_source" ]; do
  _dir="$(cd "$(dirname "$_source")" && pwd)"
  _source="$(readlink "$_source")"
  case "$_source" in /*) ;; *) _source="$_dir/$_source" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$_source")" && pwd)"
AUTOSDE_HOME="${AUTOSDE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/autosde}"

CLI_REPO_PATH=""
CLI_GITHUB_REPO=""
CLI_VERIFY_COMMAND=""
CLI_SLEEP_INTERVAL=""
CLI_CLAUDE_BIN=""
CLI_GH_BIN=""
CLI_TIMEOUT_SECONDS=""

REPO_PATH=""
GITHUB_REPO=""
VERIFY_COMMAND=""
SLEEP_INTERVAL=""
CLAUDE_BIN=""
GH_BIN=""
TIMEOUT_SECONDS=""
TARGET_AGENT_FILE=""

RESULTS_LOG="${RESULTS_LOG:-$AUTOSDE_HOME/results.log}"
LOG_DIR="${LOG_DIR:-$AUTOSDE_HOME/logs}"

RESOLVED_VERIFY_COMMAND=""
VERIFY_COMMAND_SOURCE=""
CLAUDE_PATH=""
GH_PATH=""
GH_LOGIN=""
TIMEOUT_BIN=""

CLAUDE_SETUP_URL="https://docs.anthropic.com/en/docs/claude-code/getting-started"
GH_SETUP_URL="https://cli.github.com/"

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

note() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

die() {
  note "$*"
  exit 1
}

sanitize_single_line() {
  printf '%s' "$*" | tr '\t\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --repo PATH          Target repository path. Defaults to current directory.
  --github OWNER/REPO  GitHub repository. Detected interactively if omitted.
  --verify COMMAND     Verification command. If omitted, AutoSDE auto-detects one.
  --sleep SECONDS      Poll interval when idle. Defaults to 900.
  --claude-bin PATH    Claude CLI binary. Defaults to claude.
  --gh-bin PATH        GitHub CLI binary. Defaults to gh.
  --timeout SECONDS    Claude execution timeout. Defaults to 600.
  -h, --help           Show this help message.

Precedence:
  command line > environment variables > defaults

Environment variable fallbacks:
  REPO_PATH, GITHUB_REPO, VERIFY_COMMAND, SLEEP_INTERVAL,
  CLAUDE_BIN, GH_BIN, TIMEOUT_SECONDS, TARGET_AGENT_FILE,
  AUTOSDE_HOME, RESULTS_LOG, LOG_DIR
EOF
}

require_value() {
  local flag="$1"
  local value="${2:-}"

  if [ -z "$value" ]; then
    die "Missing value for $flag"
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        require_value "$1" "${2:-}"
        CLI_REPO_PATH="$2"
        shift 2
        ;;
      --repo=*)
        CLI_REPO_PATH="${1#*=}"
        shift
        ;;
      --github)
        require_value "$1" "${2:-}"
        CLI_GITHUB_REPO="$2"
        shift 2
        ;;
      --github=*)
        CLI_GITHUB_REPO="${1#*=}"
        shift
        ;;
      --verify)
        require_value "$1" "${2:-}"
        CLI_VERIFY_COMMAND="$2"
        shift 2
        ;;
      --verify=*)
        CLI_VERIFY_COMMAND="${1#*=}"
        shift
        ;;
      --sleep)
        require_value "$1" "${2:-}"
        CLI_SLEEP_INTERVAL="$2"
        shift 2
        ;;
      --sleep=*)
        CLI_SLEEP_INTERVAL="${1#*=}"
        shift
        ;;
      --claude-bin)
        require_value "$1" "${2:-}"
        CLI_CLAUDE_BIN="$2"
        shift 2
        ;;
      --claude-bin=*)
        CLI_CLAUDE_BIN="${1#*=}"
        shift
        ;;
      --gh-bin)
        require_value "$1" "${2:-}"
        CLI_GH_BIN="$2"
        shift 2
        ;;
      --gh-bin=*)
        CLI_GH_BIN="${1#*=}"
        shift
        ;;
      --timeout)
        require_value "$1" "${2:-}"
        CLI_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --timeout=*)
        CLI_TIMEOUT_SECONDS="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

apply_config() {
  REPO_PATH="${CLI_REPO_PATH:-${REPO_PATH:-$PWD}}"
  GITHUB_REPO="${CLI_GITHUB_REPO:-${GITHUB_REPO:-}}"
  VERIFY_COMMAND="${CLI_VERIFY_COMMAND:-${VERIFY_COMMAND:-}}"
  SLEEP_INTERVAL="${CLI_SLEEP_INTERVAL:-${SLEEP_INTERVAL:-900}}"
  CLAUDE_BIN="${CLI_CLAUDE_BIN:-${CLAUDE_BIN:-claude}}"
  GH_BIN="${CLI_GH_BIN:-${GH_BIN:-gh}}"
  TIMEOUT_SECONDS="${CLI_TIMEOUT_SECONDS:-${TIMEOUT_SECONDS:-600}}"
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

validate_positive_integer() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    0)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

resolve_repo_path() {
  if [ ! -d "$REPO_PATH" ]; then
    die "--repo path does not exist: $REPO_PATH"
  fi

  REPO_PATH="$(cd "$REPO_PATH" && pwd)"
}

resolve_target_agent_file() {
  local configured_target="${TARGET_AGENT_FILE:-AGENT.md}"

  if [ "${configured_target#/}" != "$configured_target" ]; then
    TARGET_AGENT_FILE="$configured_target"
  else
    TARGET_AGENT_FILE="$REPO_PATH/$configured_target"
  fi
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
  "$GH_BIN" api user --jq '.login' 2>/dev/null || true
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g' |
    cut -c1-40
}

write_default_agent_template() {
  cat <<'EOF'
# AutoSDE Agent Instructions

## Identity
You are an autonomous software development agent working on this repository.
You pick up tasks from GitHub Issues, implement solutions, and submit PRs.
You never stop. You never ask if you should continue.

## Scope
- You CAN modify: replace this with the real allowed directories for the target repo
- You CANNOT modify: .github/workflows/, AGENT.md, and any config that affects CI itself
- You CANNOT: delete tests, disable linting, bypass CI checks, auto-merge anything

## Task Execution
1. Read the issue carefully. Understand what's being asked.
2. If the issue is ambiguous, comment asking for clarification and STOP.
3. If clear, plan your approach briefly and write that plan as an issue comment.
4. Implement the change on your branch.
5. Write or update tests for your change.
6. Run the test suite locally before finishing.
7. If tests pass, leave the branch ready for the harness to push and create a PR.
8. If tests fail, debug. You get ONE retry. If still failing, stop and explain why in the issue.

## PR Format
- Title: `[AutoSDE] <concise description>`
- Body: What was changed, why, and link to the issue (`Closes #N`)
- Keep PRs small and focused. One issue = one PR.

## Quality Standards
- All existing tests must still pass.
- New functionality must have test coverage.
- No commented-out code, no TODOs in new code.
- Follow the existing code style and conventions of this repo.

## Research Mode
When no tasks are available:
- Scan for TODOs/FIXMEs and assess if they're worth addressing.
- Look for obvious performance improvements or dead code.
- Check if dependencies have known security vulnerabilities.
- If you find something worth doing, create an issue labeled `agent` and `agent-proposed`.
- Do NOT make changes without creating an issue first.

## Boundaries (NEVER cross these)
- Never push directly to main.
- Never modify CI/CD configuration.
- Never delete or weaken tests.
- Never make changes outside your allowed scope directories.
- When in doubt, create an issue and ask instead of guessing.

## Logging
After each task, report what you tried, what the outcome was, and what you learned.
This goes both as an issue comment and into `results.log`.

## Adaptation Note
This file is a template. Before using AutoSDE on a real repository, replace the scope line with the exact directories and constraints for that codebase.
EOF
}

generate_default_agent_file() {
  mkdir -p "$(dirname "$TARGET_AGENT_FILE")"

  if [ -f "$SCRIPT_DIR/AGENT.md" ] && [ "$SCRIPT_DIR/AGENT.md" != "$TARGET_AGENT_FILE" ]; then
    cp "$SCRIPT_DIR/AGENT.md" "$TARGET_AGENT_FILE"
  else
    write_default_agent_template >"$TARGET_AGENT_FILE"
  fi

  note "Generated default AGENT.md at $TARGET_AGENT_FILE, review and customize the scope section"
}

preflight_claude() {
  CLAUDE_PATH="$(command_path "$CLAUDE_BIN")"

  if [ -z "$CLAUDE_PATH" ]; then
    die "Claude CLI not found at '$CLAUDE_BIN'. Install it from $CLAUDE_SETUP_URL"
  fi
}

preflight_gh() {
  GH_PATH="$(command_path "$GH_BIN")"

  if [ -z "$GH_PATH" ]; then
    die "GitHub CLI not found at '$GH_BIN'. Install it from $GH_SETUP_URL"
  fi

  if ! "$GH_BIN" auth status >/dev/null 2>&1; then
    die "GitHub CLI is not logged in. Run 'gh auth login' and try again."
  fi

  GH_LOGIN="$(agent_login)"

  if [ -z "$GH_LOGIN" ]; then
    die "GitHub CLI is installed, but AutoSDE could not determine the logged-in user."
  fi
}

preflight_repo() {
  if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "--repo must point to a git repository: $REPO_PATH"
  fi
}

preflight_github_repo() {
  if [ -z "$GITHUB_REPO" ]; then
    die "--github OWNER/REPO is required"
  fi
}

resolve_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
    return 0
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
    return 0
  fi

  return 1
}

preflight_timeout() {
  if ! validate_positive_integer "$TIMEOUT_SECONDS"; then
    die "--timeout must be a positive integer"
  fi

  TIMEOUT_BIN="$(resolve_timeout_bin)" || die "No timeout command found. Install GNU coreutils to get 'gtimeout' on macOS."
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

preflight_verify_command() {
  if validate_positive_integer "$SLEEP_INTERVAL"; then
    :
  else
    die "--sleep must be a positive integer"
  fi

  if [ -n "$VERIFY_COMMAND" ]; then
    RESOLVED_VERIFY_COMMAND="$VERIFY_COMMAND"
    VERIFY_COMMAND_SOURCE="configured"
    return 0
  fi

  RESOLVED_VERIFY_COMMAND="$(detect_verify_command)" || die "Could not auto-detect a verification command. Pass --verify \"COMMAND\"."
  VERIFY_COMMAND_SOURCE="auto-detected"
}

preflight_agent_file() {
  if [ ! -f "$TARGET_AGENT_FILE" ]; then
    generate_default_agent_file
  fi
}

print_startup_summary() {
  local verify_line

  verify_line="$RESOLVED_VERIFY_COMMAND"
  if [ "$VERIFY_COMMAND_SOURCE" = "auto-detected" ]; then
    verify_line="$verify_line (auto-detected)"
  fi

  note "AutoSDE starting"
  note "repo: $REPO_PATH"
  note "github: $GITHUB_REPO"
  note "verify: $verify_line"
  note "claude: $CLAUDE_PATH ✓"
  note "gh: $GH_PATH ✓ (logged in as $GH_LOGIN)"
  note "AGENT.md: found"
  note "waiting for issues labeled \"agent\"..."
}

preflight() {
  preflight_github_repo
  resolve_repo_path
  resolve_target_agent_file
  preflight_claude
  preflight_gh
  preflight_repo
  preflight_timeout
  preflight_verify_command
  preflight_agent_file
  ensure_runtime_files
  print_startup_summary
}

# --- Interactive onboarding ---

step_ok() {
  printf '  ✓ %s\n' "$*"
}

step_fail() {
  printf '  ✗ %s\n' "$*"
}

confirm_default_yes() {
  local prompt="$1"
  local reply

  printf '%s ' "$prompt" >/dev/tty
  read -r reply </dev/tty || reply=""

  case "$reply" in
    [Nn]*) return 1 ;;
    *) return 0 ;;
  esac
}

prompt_input() {
  local prompt="$1"
  local reply

  printf '%s ' "$prompt" >/dev/tty
  read -r reply </dev/tty || reply=""

  printf '%s' "$reply"
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux)
      if [ -f /etc/os-release ] && grep -qi 'fedora\|rhel\|centos' /etc/os-release; then
        printf 'fedora'
      else
        printf 'debian'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

parse_github_remote() {
  local url
  url="$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null)" || return 1

  printf '%s' "$url" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s/\.git$//'
}

check_claude_auth() {
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    return 0
  fi

  if [ -d "${HOME}/.claude" ] && [ "$(ls -A "${HOME}/.claude" 2>/dev/null)" ]; then
    return 0
  fi

  return 1
}

interactive_onboarding() {
  printf 'AutoSDE setup\n\n'

  # 1. git
  if ! command -v git >/dev/null 2>&1; then
    step_fail "git not found"
    printf '  Install git: https://git-scm.com/downloads\n'
    exit 1
  fi
  step_ok "git"

  # 2. gh CLI
  GH_PATH="$(command_path "$GH_BIN")"
  if [ -z "$GH_PATH" ]; then
    step_fail "GitHub CLI not found"
    case "$(detect_platform)" in
      macos)
        if command -v brew >/dev/null 2>&1 && confirm_default_yes "  Install with Homebrew? [Y/n]"; then
          brew install gh || { step_fail "brew install gh failed"; exit 1; }
          GH_PATH="$(command_path "$GH_BIN")"
        fi
        ;;
      debian) printf '  Install it: sudo apt install gh\n' ;;
      fedora) printf '  Install it: sudo dnf install gh\n' ;;
      *)      printf '  Install it: %s\n' "$GH_SETUP_URL" ;;
    esac
    if [ -z "$GH_PATH" ]; then exit 1; fi
  fi
  step_ok "GitHub CLI"

  # 3. gh auth — let gh handle the interactive login flow
  if ! "$GH_BIN" auth status >/dev/null 2>&1; then
    step_fail "GitHub CLI not logged in"
    printf '  Running: gh auth login\n\n'
    if ! "$GH_BIN" auth login </dev/tty; then
      printf '\n'
      step_fail "GitHub authentication failed"
      exit 1
    fi
    printf '\n'
  fi
  GH_LOGIN="$(agent_login)"
  if [ -z "$GH_LOGIN" ]; then
    step_fail "Could not determine GitHub user"
    exit 1
  fi
  step_ok "GitHub authenticated as $GH_LOGIN"

  # 4. claude CLI
  CLAUDE_PATH="$(command_path "$CLAUDE_BIN")"
  if [ -z "$CLAUDE_PATH" ]; then
    step_fail "Claude CLI not found"
    if command -v npm >/dev/null 2>&1 && confirm_default_yes "  Install with npm? [Y/n]"; then
      npm install -g @anthropic-ai/claude-code || { step_fail "npm install failed"; exit 1; }
      CLAUDE_PATH="$(command_path "$CLAUDE_BIN")"
    fi
    if [ -z "$CLAUDE_PATH" ]; then
      printf '  Install it: npm install -g @anthropic-ai/claude-code\n'
      exit 1
    fi
  fi
  step_ok "Claude CLI"

  # 5. claude auth — only hint, never run login for the user
  if ! check_claude_auth; then
    step_fail "Claude CLI not authenticated"
    printf '  Run: claude login\n'
    exit 1
  fi
  step_ok "Claude authenticated"

  # 6. git repo + GitHub remote
  resolve_repo_path

  if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    step_fail "Not a git repository: $REPO_PATH"
    printf '  Run autosde from inside a git repository, or pass --repo PATH\n'
    exit 1
  fi
  step_ok "git repository"

  if [ -z "$GITHUB_REPO" ]; then
    local detected_repo
    detected_repo="$(parse_github_remote)" || detected_repo=""

    if [ -n "$detected_repo" ]; then
      if confirm_default_yes "  Detected remote: $detected_repo. Use this? [Y/n]"; then
        GITHUB_REPO="$detected_repo"
      else
        GITHUB_REPO="$(prompt_input "  Enter GitHub repo (owner/repo):")"
      fi
    else
      GITHUB_REPO="$(prompt_input "  Enter GitHub repo (owner/repo):")"
    fi

    if [ -z "$GITHUB_REPO" ]; then
      step_fail "No GitHub repository specified"
      exit 1
    fi
  fi
  step_ok "repo: $GITHUB_REPO"

  # 7. verify command
  resolve_target_agent_file

  if [ -n "$VERIFY_COMMAND" ]; then
    RESOLVED_VERIFY_COMMAND="$VERIFY_COMMAND"
    VERIFY_COMMAND_SOURCE="configured"
  else
    local detected_verify
    detected_verify="$(detect_verify_command 2>/dev/null)" || detected_verify=""

    if [ -n "$detected_verify" ]; then
      if confirm_default_yes "  Detected: $detected_verify. Use this? [Y/n]"; then
        RESOLVED_VERIFY_COMMAND="$detected_verify"
        VERIFY_COMMAND_SOURCE="auto-detected"
      else
        RESOLVED_VERIFY_COMMAND="$(prompt_input "  Enter verify command:")"
        VERIFY_COMMAND_SOURCE="configured"
      fi
    else
      RESOLVED_VERIFY_COMMAND="$(prompt_input "  Enter verify command:")"
      VERIFY_COMMAND_SOURCE="configured"
    fi

    if [ -z "$RESOLVED_VERIFY_COMMAND" ]; then
      step_fail "No verify command specified"
      exit 1
    fi
  fi
  step_ok "verify: $RESOLVED_VERIFY_COMMAND"

  # 8. AGENT.md
  if [ ! -f "$TARGET_AGENT_FILE" ]; then
    mkdir -p "$(dirname "$TARGET_AGENT_FILE")"
    if [ -f "$SCRIPT_DIR/AGENT.md" ] && [ "$SCRIPT_DIR/AGENT.md" != "$TARGET_AGENT_FILE" ]; then
      cp "$SCRIPT_DIR/AGENT.md" "$TARGET_AGENT_FILE"
    else
      write_default_agent_template >"$TARGET_AGENT_FILE"
    fi
    if ! confirm_default_yes "  Generated AGENT.md at $TARGET_AGENT_FILE. Continue? [Y/n]"; then
      printf '  Edit AGENT.md and re-run autosde.\n'
      exit 0
    fi
  fi
  step_ok "AGENT.md"

  # 9. timeout command
  if ! validate_positive_integer "$TIMEOUT_SECONDS"; then
    step_fail "Invalid timeout value: $TIMEOUT_SECONDS"
    exit 1
  fi

  TIMEOUT_BIN="$(resolve_timeout_bin 2>/dev/null)" || TIMEOUT_BIN=""
  if [ -z "$TIMEOUT_BIN" ]; then
    step_fail "No timeout command found"
    case "$(detect_platform)" in
      macos)
        if command -v brew >/dev/null 2>&1 && confirm_default_yes "  Install coreutils with Homebrew? [Y/n]"; then
          brew install coreutils || { step_fail "brew install coreutils failed"; exit 1; }
          TIMEOUT_BIN="$(resolve_timeout_bin 2>/dev/null)" || TIMEOUT_BIN=""
        fi
        ;;
      *) printf '  Install GNU coreutils for the timeout command\n' ;;
    esac
    if [ -z "$TIMEOUT_BIN" ]; then exit 1; fi
  fi
  step_ok "timeout: $TIMEOUT_BIN"

  if ! validate_positive_integer "$SLEEP_INTERVAL"; then
    step_fail "Invalid sleep interval: $SLEEP_INTERVAL"
    exit 1
  fi

  ensure_runtime_files

  # 9. Startup summary
  printf '\n'
  print_startup_summary
}

release_issue() {
  local issue_number="$1"
  local login="$2"

  "$GH_BIN" issue edit "$issue_number" --repo "$GITHUB_REPO" --remove-assignee "$login" >/dev/null 2>&1 || true
}

target_agent_git_clean_exclusion() {
  case "$TARGET_AGENT_FILE" in
    "$REPO_PATH"/*)
      printf '%s' "${TARGET_AGENT_FILE#$REPO_PATH/}"
      ;;
    *)
      return 1
      ;;
  esac
}

clean_repo_worktree() {
  local agent_exclusion

  agent_exclusion="$(target_agent_git_clean_exclusion 2>/dev/null || true)"

  if [ -n "$agent_exclusion" ]; then
    git -C "$REPO_PATH" clean -fd -e "$agent_exclusion" >/dev/null 2>&1
  else
    git -C "$REPO_PATH" clean -fd >/dev/null 2>&1
  fi
}

checkout_clean_default_branch() {
  local branch="$1"

  git -C "$REPO_PATH" fetch origin "$branch" --prune >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" checkout "$branch" >/dev/null 2>&1 || \
    git -C "$REPO_PATH" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" reset --hard "origin/$branch" >/dev/null 2>&1 || return 1
  clean_repo_worktree || return 1
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
    printf '%s\n' '----- BEGIN AGENT.md -----'
    cat "$TARGET_AGENT_FILE"
    printf '\n----- END AGENT.md -----\n\n'
    printf 'Current issue:\n'
    printf '#%s: %s\n' "$issue_number" "$issue_title"
    printf '%s\n\n' "$issue_url"
    printf 'Issue body:\n%s\n\n' "$issue_body"
    printf 'Harness expectations:\n'
    printf '%s\n' '- Work only in this repository.'
    printf '%s\n' '- Use GitHub CLI if you need to comment on the issue or inspect metadata.'
    printf '%s\n' '- Leave the branch ready for verification by the harness when you finish.'

    if [ -n "$retry_feedback" ]; then
      printf '\nRetry context:\n%s\n' "$retry_feedback"
    fi
  } >"$prompt_file"
}

create_claude_runner() {
  local runner_file="$1"

  cat <<'EOF' >"$runner_file"
#!/usr/bin/env bash

set -uo pipefail

prompt_file="$1"
claude_bin="$2"
prompt_text="$(cat "$prompt_file")"

if "$claude_bin" -p --dangerously-skip-permissions "$prompt_text"; then
  exit 0
fi

if "$claude_bin" --print --dangerously-skip-permissions "$prompt_text"; then
  exit 0
fi

if cat "$prompt_file" | "$claude_bin" -p --dangerously-skip-permissions; then
  exit 0
fi

if cat "$prompt_file" | "$claude_bin" --print --dangerously-skip-permissions; then
  exit 0
fi

exit 1
EOF

  chmod +x "$runner_file"
}

run_claude_prompt() {
  local prompt_file="$1"
  local task_log="$2"
  local runner_file
  local exit_code

  runner_file="$(mktemp)"
  create_claude_runner "$runner_file"

  {
    printf '=== %s Claude invocation started ===\n' "$(timestamp)"
    printf 'timeout: %s seconds via %s\n' "$TIMEOUT_SECONDS" "$TIMEOUT_BIN"
  } >>"$task_log" 2>&1

  "$TIMEOUT_BIN" "$TIMEOUT_SECONDS" "$runner_file" "$prompt_file" "$CLAUDE_BIN" >>"$task_log" 2>&1
  exit_code=$?

  if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
    printf '\n=== %s Claude invocation timed out after %s seconds ===\n' "$(timestamp)" "$TIMEOUT_SECONDS" >>"$task_log" 2>&1
  elif [ "$exit_code" -eq 0 ]; then
    printf '\n=== %s Claude invocation finished successfully ===\n' "$(timestamp)" >>"$task_log" 2>&1
  else
    printf '\n=== %s Claude invocation failed with exit code %s ===\n' "$(timestamp)" "$exit_code" >>"$task_log" 2>&1
  fi

  rm -f "$runner_file"
  return "$exit_code"
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

  git -C "$REPO_PATH" checkout "$base" >/dev/null 2>&1 || \
    git -C "$REPO_PATH" checkout -B "$base" "origin/$base" >/dev/null 2>&1 || return 1
  git -C "$REPO_PATH" reset --hard "origin/$base" >/dev/null 2>&1 || return 1
  clean_repo_worktree || return 1
  git -C "$REPO_PATH" branch -D "$branch" >/dev/null 2>&1 || true
}

discard_branch() {
  local branch="$1"
  local base="$2"

  git -C "$REPO_PATH" checkout "$base" >/dev/null 2>&1 || \
    git -C "$REPO_PATH" checkout -B "$base" "origin/$base" >/dev/null 2>&1 || true
  git -C "$REPO_PATH" reset --hard "origin/$base" >/dev/null 2>&1 || true
  clean_repo_worktree || true
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
  local runner

  if [ -f "$REPO_PATH/package.json" ]; then
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
  local existing

  existing="$("$GH_BIN" issue list \
    --repo "$GITHUB_REPO" \
    --state open \
    --label agent-proposed \
    --limit 100 \
    --json title \
    --jq '.[].title' 2>/dev/null)" || existing=""

  if printf '%s\n' "$existing" | grep -qxF "$title"; then
    note "Skipping proposed issue (duplicate): $title"
    return 0
  fi

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
  note "Research mode found nothing actionable."
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

  if [ ! -f "$TARGET_AGENT_FILE" ]; then
    generate_default_agent_file
  fi

  if ! create_issue_branch "$branch" "$base_branch"; then
    comment_crash "$issue_number" "$branch" "Unable to create the working branch."
    release_issue "$issue_number" "$login"
    log_result "$issue_number" "$branch" "crashed" "Unable to create working branch"
    return 1
  fi

  prompt_file="$(mktemp)"
  build_prompt_file "$prompt_file" "$issue_number" "$issue_title" "$issue_url" "$issue_body" "$branch"

  if ! run_claude_prompt "$prompt_file" "$task_log"; then
    comment_crash "$issue_number" "$branch" "Claude Code failed or timed out before a verified change was produced."
    release_issue "$issue_number" "$login"
    rm -f "$prompt_file"
    discard_branch "$branch" "$base_branch"
    log_result "$issue_number" "$branch" "crashed" "Claude invocation failed or timed out"
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

  if ! run_verification "$RESOLVED_VERIFY_COMMAND" "$task_log"; then
    retry_context="$(cat <<EOF
The first verification attempt failed.

Verification command:
$RESOLVED_VERIFY_COMMAND

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

    if ! run_verification "$RESOLVED_VERIFY_COMMAND" "$task_log"; then
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

  login="$GH_LOGIN"
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
    note "Sleeping for $SLEEP_INTERVAL seconds."
    sleep "$SLEEP_INTERVAL"
    return 0
  fi

  process_issue "$issue_number" "$login" "$base_branch" "$reviewer"
}

main() {
  parse_args "$@"
  apply_config

  if [ -t 0 ] && [ -z "$CLI_GITHUB_REPO" ]; then
    interactive_onboarding
  else
    preflight
  fi

  while true; do
    run_iteration || true
  done
}

main "$@"
