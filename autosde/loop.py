"""Main loop: poll issues, run Claude, verify, create PRs."""

import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

from .helpers import (
    AGENT_TEMPLATE,
    note,
    run,
    sanitize_single_line,
    slugify,
    timestamp,
)


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

def git(cfg, *args):
    return run(["git", "-C", cfg.repo_path] + list(args))


def gh(cfg, *args):
    return run([cfg.gh_bin] + list(args))


def default_branch(cfg) -> str:
    r = gh(cfg, "repo", "view", cfg.github_repo,
           "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name")
    if r.returncode == 0 and r.stdout.strip() and r.stdout.strip() != "null":
        return r.stdout.strip()

    r = git(cfg, "symbolic-ref", "refs/remotes/origin/HEAD")
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip().replace("refs/remotes/origin/", "")

    r = git(cfg, "rev-parse", "--verify", "origin/main")
    return "main" if r.returncode == 0 else "master"


def checkout_clean(cfg, branch: str) -> bool:
    if git(cfg, "fetch", "origin", branch, "--prune").returncode != 0:
        return False
    if git(cfg, "checkout", branch).returncode != 0:
        if git(cfg, "checkout", "-B", branch, f"origin/{branch}").returncode != 0:
            return False
    if git(cfg, "reset", "--hard", f"origin/{branch}").returncode != 0:
        return False
    git(cfg, "clean", "-fd")
    return True


def create_branch(cfg, branch: str, base: str) -> bool:
    return git(cfg, "checkout", "-B", branch, f"origin/{base}").returncode == 0


def branch_has_changes(cfg, base: str) -> bool:
    diff = git(cfg, "diff", "--quiet", f"origin/{base}...HEAD")
    status = git(cfg, "status", "--porcelain")
    return diff.returncode != 0 or bool(status.stdout.strip())


def commit_if_needed(cfg, issue_number: str, title: str) -> bool:
    if not git(cfg, "status", "--porcelain").stdout.strip():
        return True
    git(cfg, "add", "-A")
    return git(cfg, "commit", "-m", f"[AutoSDE] #{issue_number} {title}").returncode == 0


def push_branch(cfg, branch: str) -> bool:
    return git(cfg, "push", "-u", "origin", branch, "--force-with-lease").returncode == 0


def cleanup_branch(cfg, branch: str, base: str) -> None:
    git(cfg, "checkout", base)
    git(cfg, "reset", "--hard", f"origin/{base}")
    git(cfg, "clean", "-fd")
    git(cfg, "branch", "-D", branch)


def discard_branch(cfg, branch: str, base: str) -> None:
    git(cfg, "checkout", base)
    git(cfg, "reset", "--hard", f"origin/{base}")
    git(cfg, "clean", "-fd")
    git(cfg, "branch", "-D", branch)
    git(cfg, "push", "origin", "--delete", branch)


# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------

def select_issue_number(cfg) -> str | None:
    r = gh(cfg, "issue", "list",
           "--repo", cfg.github_repo,
           "--state", "open",
           "--label", "agent",
           "--limit", "100",
           "--json", "number,labels,assignees")
    if r.returncode != 0:
        return None
    try:
        issues = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None

    # Filter unassigned
    issues = [i for i in issues if not i.get("assignees")]

    def priority(issue):
        labels = {l["name"] for l in issue.get("labels", [])}
        if "bug" in labels:
            return 0
        if "feature" in labels:
            return 1
        if "refactor" in labels:
            return 2
        if "chore" in labels:
            return 3
        return 4

    issues.sort(key=lambda i: (priority(i), i["number"]))
    return str(issues[0]["number"]) if issues else None


def issue_field(cfg, number: str, field: str) -> str:
    r = gh(cfg, "issue", "view", number,
           "--repo", cfg.github_repo, "--json", field, "--jq", f".{field}")
    return r.stdout.strip() if r.returncode == 0 else ""


def claim_issue(cfg, number: str, login: str) -> bool:
    a = gh(cfg, "issue", "edit", number,
           "--repo", cfg.github_repo, "--add-assignee", login)
    c = gh(cfg, "issue", "comment", number,
           "--repo", cfg.github_repo, "--body", "I'm picking this up.")
    return a.returncode == 0 and c.returncode == 0


def release_issue(cfg, number: str, login: str) -> None:
    gh(cfg, "issue", "edit", number,
       "--repo", cfg.github_repo, "--remove-assignee", login)


def comment_issue(cfg, number: str, body: str) -> None:
    gh(cfg, "issue", "comment", number, "--repo", cfg.github_repo, "--body", body)


def create_pr(cfg, branch: str, base: str, number: str, title: str, reviewer: str) -> str | None:
    summary = git(cfg, "diff", "--stat", "--compact-summary", f"origin/{base}...HEAD")
    if not summary.stdout.strip():
        summary = git(cfg, "log", "--oneline", f"origin/{base}..HEAD")
    body = (
        f"Automated implementation for #{number}.\n\n"
        f"What changed:\n{summary.stdout.strip()}\n\n"
        f"Closes #{number}"
    )
    r = gh(cfg, "pr", "create",
           "--repo", cfg.github_repo,
           "--base", base, "--head", branch,
           "--title", f"[AutoSDE] {title}",
           "--body", body)
    if r.returncode != 0:
        return None
    pr_url = r.stdout.strip()
    gh(cfg, "pr", "edit", pr_url, "--repo", cfg.github_repo, "--add-reviewer", reviewer)
    return pr_url


def proposed_issue_exists(cfg, title: str) -> bool:
    r = gh(cfg, "issue", "list",
           "--repo", cfg.github_repo,
           "--state", "open",
           "--label", "agent-proposed",
           "--limit", "100",
           "--json", "title")
    if r.returncode != 0:
        return False
    try:
        return any(i["title"] == title for i in json.loads(r.stdout))
    except (json.JSONDecodeError, KeyError):
        return False


def create_proposed_issue(cfg, title: str, body: str, priority: str) -> None:
    if proposed_issue_exists(cfg, title):
        note(f"Skipping proposed issue (duplicate): {title}")
        return
    gh(cfg, "issue", "create",
       "--repo", cfg.github_repo,
       "--title", title, "--body", body,
       "--label", "agent", "--label", "agent-proposed", "--label", priority)


# ---------------------------------------------------------------------------
# Claude runner
# ---------------------------------------------------------------------------

def build_prompt(cfg, number: str, title: str, url: str, body: str,
                 branch: str, retry_context: str = "") -> str:
    agent_text = Path(cfg.target_agent_file).read_text()
    lines = [
        f"You are working inside the repository at {cfg.repo_path}.",
        f"Stay on branch {branch}.\n",
        "Follow the repository AGENT.md instructions below exactly.\n",
        "----- BEGIN AGENT.md -----",
        agent_text,
        "----- END AGENT.md -----\n",
        "Current issue:",
        f"#{number}: {title}",
        f"{url}\n",
        f"Issue body:\n{body}\n",
        "Harness expectations:",
        "- Work only in this repository.",
        "- Use GitHub CLI if you need to comment on the issue or inspect metadata.",
        "- Leave the branch ready for verification by the harness when you finish.",
    ]
    if retry_context:
        lines.append(f"\nRetry context:\n{retry_context}")
    return "\n".join(lines)


def run_claude(cfg, prompt_text: str, log_path: str) -> bool:
    with open(log_path, "a") as log:
        log.write(f"=== {timestamp()} Claude invocation started ===\n")
        log.write(f"timeout: {cfg.timeout_seconds} seconds\n")

        methods = [
            {"args": [cfg.claude_bin, "-p", "--dangerously-skip-permissions", prompt_text]},
            {"args": [cfg.claude_bin, "--print", "--dangerously-skip-permissions", prompt_text]},
            {"args": [cfg.claude_bin, "-p", "--dangerously-skip-permissions"], "input": prompt_text},
            {"args": [cfg.claude_bin, "--print", "--dangerously-skip-permissions"], "input": prompt_text},
        ]

        for method in methods:
            try:
                proc = subprocess.run(
                    method["args"],
                    input=method.get("input"),
                    cwd=cfg.repo_path,
                    timeout=cfg.timeout_seconds,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                if proc.returncode == 0:
                    log.write(f"\n=== {timestamp()} Claude finished successfully ===\n")
                    return True
            except subprocess.TimeoutExpired:
                log.write(f"\n=== {timestamp()} Claude timed out after {cfg.timeout_seconds}s ===\n")
                return False

        log.write(f"\n=== {timestamp()} All Claude invocations failed ===\n")
    return False


def run_verification(cfg, log_path: str) -> bool:
    with open(log_path, "a") as log:
        log.write(f"\n=== {timestamp()} Verification: {cfg.resolved_verify} ===\n")
        proc = subprocess.run(
            ["bash", "-lc", cfg.resolved_verify],
            cwd=cfg.repo_path,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        log.write(f"\n=== {timestamp()} Verification exit code: {proc.returncode} ===\n")
    return proc.returncode == 0


def failure_excerpt(log_path: str) -> str:
    try:
        lines = Path(log_path).read_text().splitlines()
        return "\n".join(lines[-60:])[-3500:]
    except FileNotFoundError:
        return "(no log available)"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log_result(cfg, issue: str = "-", branch: str = "-",
               status: str = "crashed", description: str = "") -> None:
    line = "\t".join([
        timestamp(), issue, branch, status, sanitize_single_line(description),
    ])
    with open(cfg.results_log, "a") as f:
        f.write(line + "\n")


# ---------------------------------------------------------------------------
# Research mode
# ---------------------------------------------------------------------------

def _search_tool():
    import shutil
    return "rg" if shutil.which("rg") else "grep"


def _run_audit(cfg) -> str | None:
    """Run dependency audit, return output or None."""
    p = Path(cfg.repo_path)
    cmds = []
    if (p / "package.json").exists():
        from .helpers import detect_js_runner
        runner = detect_js_runner(cfg.repo_path)
        cmds.append([runner, "audit"])
    if (p / "Cargo.lock").exists() and shutil.which("cargo-audit"):
        cmds.append(["cargo", "audit"])
    if (p / "Gemfile.lock").exists() and shutil.which("bundle-audit"):
        cmds.append(["bundle", "audit", "check"])
    if ((p / "requirements.txt").exists() or (p / "pyproject.toml").exists()) and shutil.which("pip-audit"):
        cmds.append(["pip-audit"])

    for cmd in cmds:
        import shutil as sh
        if not sh.which(cmd[0]):
            continue
        r = subprocess.run(cmd, cwd=cfg.repo_path, capture_output=True, text=True)
        output = r.stdout + r.stderr
        if re.search(r"vulnerab|advisories|severity|critical|high", output, re.IGNORECASE):
            return output
    return None


def research_mode(cfg) -> None:
    note("No unclaimed agent issues found. Entering research mode.")

    # 1. Dependency audit
    audit = _run_audit(cfg)
    if audit:
        excerpt = "\n".join(audit.splitlines()[-40:])
        create_proposed_issue(
            cfg,
            "Investigate dependency vulnerabilities reported by automated audit",
            f"Research mode found dependency audit output that appears actionable.\n\n"
            f"Audit excerpt:\n```\n{excerpt}\n```",
            "bug",
        )
        return

    # 2. TODO/FIXME scan
    tool = _search_tool()
    if tool == "rg":
        r = subprocess.run(
            ["rg", "-n", "--glob", "!.git", "--glob", "!node_modules", "--glob", "!vendor",
             "TODO|FIXME", "."],
            cwd=cfg.repo_path, capture_output=True, text=True,
        )
    else:
        r = subprocess.run(
            ["grep", "-RInE", "--exclude-dir=.git", "--exclude-dir=node_modules",
             "--exclude-dir=vendor", "TODO|FIXME", "."],
            cwd=cfg.repo_path, capture_output=True, text=True,
        )
    todo_hits = "\n".join(r.stdout.splitlines()[:10])
    if todo_hits:
        create_proposed_issue(
            cfg,
            "Review TODO and FIXME markers discovered in research mode",
            f"Research mode found TODO/FIXME markers that may be worth turning into concrete work.\n\n"
            f"Matches:\n```\n{todo_hits}\n```",
            "refactor",
        )
        return

    # 3. Code smells
    pattern = r"console\.log|debugger|it\.skip|describe\.skip|skip\("
    if tool == "rg":
        r = subprocess.run(
            ["rg", "-n", "--glob", "!.git", "--glob", "!node_modules", "--glob", "!vendor",
             pattern, "."],
            cwd=cfg.repo_path, capture_output=True, text=True,
        )
    else:
        r = subprocess.run(
            ["grep", "-RInE", "--exclude-dir=.git", "--exclude-dir=node_modules",
             "--exclude-dir=vendor", pattern, "."],
            cwd=cfg.repo_path, capture_output=True, text=True,
        )
    smell_hits = "\n".join(r.stdout.splitlines()[:10])
    if smell_hits:
        create_proposed_issue(
            cfg,
            "Clean up obvious code smells discovered in research mode",
            f"Research mode found code smells that look actionable.\n\n"
            f"Matches:\n```\n{smell_hits}\n```",
            "refactor",
        )
        return

    note("Research mode found nothing actionable.")


# ---------------------------------------------------------------------------
# Issue processing
# ---------------------------------------------------------------------------

def process_issue(cfg, number: str, login: str, base: str, reviewer: str) -> None:
    title = issue_field(cfg, number, "title")
    body = issue_field(cfg, number, "body")
    url = issue_field(cfg, number, "url")

    if not title:
        log_result(cfg, number, "-", "crashed", "Unable to load issue details")
        return

    issue_slug = slugify(title) or "task"
    branch = f"autosde/{number}-{issue_slug}"
    log_path = os.path.join(
        cfg.log_dir,
        f"issue-{number}-{timestamp().replace(':', '')}.log",
    )

    if not claim_issue(cfg, number, login):
        log_result(cfg, number, branch, "crashed", "Unable to claim issue")
        return

    if not checkout_clean(cfg, base):
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but the harness crashed before it could finish.\n\nReason:\nUnable to reset the target repository to origin/{base}.")
        release_issue(cfg, number, login)
        log_result(cfg, number, branch, "crashed", "Unable to reset target repository")
        return

    if not os.path.isfile(cfg.target_agent_file):
        from .cli import _generate_agent_file
        _generate_agent_file(cfg)

    if not create_branch(cfg, branch, base):
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but the harness crashed before it could finish.\n\nReason:\nUnable to create the working branch.")
        release_issue(cfg, number, login)
        log_result(cfg, number, branch, "crashed", "Unable to create working branch")
        return

    prompt = build_prompt(cfg, number, title, url, body, branch)

    if not run_claude(cfg, prompt, log_path):
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but the harness crashed before it could finish.\n\nReason:\nClaude Code failed or timed out before a verified change was produced.")
        release_issue(cfg, number, login)
        discard_branch(cfg, branch, base)
        log_result(cfg, number, branch, "crashed", "Claude invocation failed or timed out")
        return

    if not branch_has_changes(cfg, base):
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but I discarded the branch.\n\nReason:\nNo code changes were produced, so there was nothing to verify or submit.")
        release_issue(cfg, number, login)
        discard_branch(cfg, branch, base)
        log_result(cfg, number, branch, "discarded", "No code changes were produced")
        return

    if not run_verification(cfg, log_path):
        # Retry once
        excerpt = failure_excerpt(log_path)
        retry_context = (
            f"The first verification attempt failed.\n\n"
            f"Verification command:\n{cfg.resolved_verify}\n\n"
            f"Failure excerpt:\n{excerpt}"
        )
        retry_prompt = build_prompt(cfg, number, title, url, body, branch, retry_context)

        if not run_claude(cfg, retry_prompt, log_path) or not run_verification(cfg, log_path):
            excerpt = failure_excerpt(log_path)
            comment_issue(cfg, number, f"I tried to address this on `{branch}`, but verification failed twice, so I discarded the branch.\n\nLatest log excerpt:\n```\n{excerpt}\n```")
            release_issue(cfg, number, login)
            discard_branch(cfg, branch, base)
            log_result(cfg, number, branch, "discarded", "Verification failed twice")
            return

    if not commit_if_needed(cfg, number, title):
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but the harness crashed before it could finish.\n\nReason:\nVerification passed, but the harness could not create a commit.")
        release_issue(cfg, number, login)
        discard_branch(cfg, branch, base)
        log_result(cfg, number, branch, "crashed", "Unable to commit changes")
        return

    if not push_branch(cfg, branch):
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but the harness crashed before it could finish.\n\nReason:\nVerification passed, but the harness could not push the branch.")
        release_issue(cfg, number, login)
        discard_branch(cfg, branch, base)
        log_result(cfg, number, branch, "crashed", "Unable to push branch")
        return

    pr_url = create_pr(cfg, branch, base, number, title, reviewer)
    if not pr_url:
        comment_issue(cfg, number, f"I picked this up on `{branch}`, but the harness crashed before it could finish.\n\nReason:\nThe branch was pushed, but PR creation failed.")
        log_result(cfg, number, branch, "crashed", "Unable to create PR after push")
        return

    comment_issue(cfg, number, f"Implemented this and opened a PR for review:\n\n{pr_url}")
    cleanup_branch(cfg, branch, base)
    log_result(cfg, number, branch, "pr-created", f"Created PR {pr_url}")


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run_loop(cfg) -> None:
    while True:
        try:
            _run_iteration(cfg)
        except Exception as exc:
            note(f"Iteration error: {exc}")
            time.sleep(cfg.sleep_interval)


def _run_iteration(cfg) -> None:
    login = cfg.gh_login
    base = default_branch(cfg)
    reviewer = cfg.github_repo.split("/")[0]

    if not login or not base:
        log_result(cfg, description="Unable to determine GitHub login or default branch")
        time.sleep(cfg.sleep_interval)
        return

    number = select_issue_number(cfg)

    if not number:
        research_mode(cfg)
        note(f"Sleeping for {cfg.sleep_interval} seconds.")
        time.sleep(cfg.sleep_interval)
        return

    process_issue(cfg, number, login, base, reviewer)
