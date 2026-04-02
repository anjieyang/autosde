"""Shared utilities for AutoSDE."""

import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

CLAUDE_SETUP_URL = "https://docs.anthropic.com/en/docs/claude-code/getting-started"
GH_SETUP_URL = "https://cli.github.com/"

AGENT_TEMPLATE = """\
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
This file is a template. Before using AutoSDE on a real repository, replace the \
scope line with the exact directories and constraints for that codebase.
"""


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def note(msg: str) -> None:
    print(f"[{timestamp()}] {msg}", file=sys.stderr)


def die(msg: str):
    note(msg)
    sys.exit(1)


def step_ok(msg: str) -> None:
    print(f"  \u2713 {msg}")


def step_fail(msg: str) -> None:
    print(f"  \u2717 {msg}")


def confirm(prompt: str, default: bool = True) -> bool:
    try:
        reply = input(f"{prompt} ").strip().lower()
    except EOFError:
        return default
    return reply[0] != "n" if reply else default


def prompt_input(prompt: str) -> str:
    try:
        return input(f"{prompt} ").strip()
    except EOFError:
        return ""


def run(cmd: list, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return re.sub(r"-{2,}", "-", s)[:40]


def sanitize_single_line(text: str) -> str:
    return re.sub(r"\s+", " ", text.replace("\n", " ")).strip()


def detect_platform() -> str:
    system = platform.system()
    if system == "Darwin":
        return "macos"
    if system == "Linux":
        try:
            content = Path("/etc/os-release").read_text().lower()
            if any(d in content for d in ("fedora", "rhel", "centos")):
                return "fedora"
        except FileNotFoundError:
            pass
        return "debian"
    return "unknown"


def detect_js_runner(repo: str) -> str:
    p = Path(repo)
    if (p / "bun.lockb").exists() or (p / "bun.lock").exists():
        return "bun"
    if (p / "pnpm-lock.yaml").exists():
        return "pnpm"
    if (p / "yarn.lock").exists():
        return "yarn"
    return "npm"


def detect_verify_command(repo: str) -> str | None:
    p = Path(repo)

    makefile = p / "Makefile"
    if makefile.exists():
        content = makefile.read_text()
        if re.search(r"^ci:", content, re.MULTILINE):
            return "make ci"
        if re.search(r"^test:", content, re.MULTILINE):
            return "make test"

    pkg = p / "package.json"
    if pkg.exists():
        runner = detect_js_runner(repo)
        content = pkg.read_text()
        for script in ("ci", "test"):
            if re.search(rf'"{script}"\s*:', content):
                if runner == "yarn":
                    return f"yarn {script}"
                return f"{runner} run {script}"

    if (p / "pytest.ini").exists() or (p / "conftest.py").exists():
        return "pytest"
    pyproject = p / "pyproject.toml"
    if pyproject.exists() and re.search(
        r"pytest|tool\.poetry|project", pyproject.read_text()
    ):
        return "pytest"

    if (p / "Cargo.toml").exists():
        return "cargo test"
    if (p / "go.mod").exists():
        return "go test ./..."
    if (p / "bin" / "rails").exists():
        return "bin/rails test"
    if (p / "Gemfile").exists() and (p / "spec").is_dir():
        return "bundle exec rspec"

    return None


def parse_github_remote(repo: str) -> str | None:
    result = run(["git", "-C", repo, "remote", "get-url", "origin"])
    if result.returncode != 0:
        return None
    url = result.stdout.strip()
    url = re.sub(r"^git@github\.com:", "", url)
    url = re.sub(r"^https://github\.com/", "", url)
    url = re.sub(r"\.git$", "", url)
    return url if "/" in url else None


def check_claude_auth() -> bool:
    if os.environ.get("ANTHROPIC_API_KEY"):
        return True
    claude_dir = Path.home() / ".claude"
    if claude_dir.is_dir() and any(claude_dir.iterdir()):
        return True
    return False
