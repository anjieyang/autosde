"""Entry point, configuration, onboarding, and preflight for AutoSDE."""

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from . import __version__
from .helpers import (
    AGENT_TEMPLATE,
    CLAUDE_SETUP_URL,
    GH_SETUP_URL,
    check_claude_auth,
    confirm,
    detect_platform,
    detect_verify_command,
    die,
    note,
    parse_github_remote,
    prompt_input,
    run,
    step_fail,
    step_ok,
)


@dataclass
class Config:
    repo_path: str = ""
    github_repo: str = ""
    verify_command: str = ""
    sleep_interval: int = 900
    claude_bin: str = "claude"
    gh_bin: str = "gh"
    timeout_seconds: int = 600

    autosde_home: str = ""
    results_log: str = ""
    log_dir: str = ""
    target_agent_file: str = ""

    resolved_verify: str = ""
    verify_source: str = ""
    claude_path: str = ""
    gh_path: str = ""
    gh_login: str = ""

    # Set by parse_args, used to decide interactive vs headless
    cli_github: str | None = None


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="autosde",
        description="Label an issue, go to sleep, wake up to a PR.",
    )
    p.add_argument("--repo", default=None, help="Target repository path (default: cwd)")
    p.add_argument("--github", default=None, help="GitHub repo (owner/repo)")
    p.add_argument("--verify", default=None, help="Verification command")
    p.add_argument("--sleep", type=int, default=None, help="Poll interval in seconds (default: 900)")
    p.add_argument("--claude-bin", default=None, help="Claude CLI binary (default: claude)")
    p.add_argument("--gh-bin", default=None, help="gh CLI binary (default: gh)")
    p.add_argument("--timeout", type=int, default=None, help="Claude timeout in seconds (default: 600)")
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return p.parse_args()


def build_config(args: argparse.Namespace) -> Config:
    cfg = Config()
    cfg.cli_github = args.github

    cfg.repo_path = args.repo or os.environ.get("REPO_PATH", os.getcwd())
    cfg.github_repo = args.github or os.environ.get("GITHUB_REPO", "")
    cfg.verify_command = args.verify or os.environ.get("VERIFY_COMMAND", "")
    cfg.sleep_interval = args.sleep or int(os.environ.get("SLEEP_INTERVAL", "900"))
    cfg.claude_bin = args.claude_bin or os.environ.get("CLAUDE_BIN", "claude")
    cfg.gh_bin = args.gh_bin or os.environ.get("GH_BIN", "gh")
    cfg.timeout_seconds = args.timeout or int(os.environ.get("TIMEOUT_SECONDS", "600"))

    xdg = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
    cfg.autosde_home = os.environ.get("AUTOSDE_HOME", os.path.join(xdg, "autosde"))
    cfg.results_log = os.environ.get("RESULTS_LOG", os.path.join(cfg.autosde_home, "results.log"))
    cfg.log_dir = os.environ.get("LOG_DIR", os.path.join(cfg.autosde_home, "logs"))

    cfg.repo_path = os.path.realpath(cfg.repo_path)

    agent = os.environ.get("TARGET_AGENT_FILE", "AGENT.md")
    cfg.target_agent_file = agent if os.path.isabs(agent) else os.path.join(cfg.repo_path, agent)

    return cfg


def gh_auth_login(cfg: Config) -> str | None:
    """Return the logged-in GitHub username, or None."""
    r = run([cfg.gh_bin, "api", "user", "--jq", ".login"])
    return r.stdout.strip() or None


def _try_install(label: str, check_cmd: str, install_cmd: list[str]) -> bool:
    """Offer to install a missing dependency. Return True if installed."""
    if shutil.which(check_cmd):
        return True
    if confirm(f"  Install {label}? [Y/n]"):
        print(f"  Running: {' '.join(install_cmd)}")
        if subprocess.run(install_cmd).returncode == 0:
            return True
        step_fail(f"{label} installation failed")
    return False


def interactive_onboarding(cfg: Config) -> None:
    print("AutoSDE setup\n")

    # 1. git
    if not shutil.which("git"):
        step_fail("git not found")
        print("  Install git: https://git-scm.com/downloads")
        sys.exit(1)
    step_ok("git")

    # 2. gh CLI
    cfg.gh_path = shutil.which(cfg.gh_bin) or ""
    if not cfg.gh_path:
        step_fail("GitHub CLI not found")
        plat = detect_platform()
        if plat == "macos" and shutil.which("brew"):
            if _try_install("GitHub CLI", cfg.gh_bin, ["brew", "install", "gh"]):
                cfg.gh_path = shutil.which(cfg.gh_bin) or ""
        elif plat == "debian":
            print("  Install it: sudo apt install gh")
        elif plat == "fedora":
            print("  Install it: sudo dnf install gh")
        else:
            print(f"  Install it: {GH_SETUP_URL}")
        if not cfg.gh_path:
            sys.exit(1)
    step_ok("GitHub CLI")

    # 3. gh auth
    if run([cfg.gh_bin, "auth", "status"]).returncode != 0:
        step_fail("GitHub CLI not logged in")
        print("  Running: gh auth login\n")
        if subprocess.run([cfg.gh_bin, "auth", "login"]).returncode != 0:
            print()
            step_fail("GitHub authentication failed")
            sys.exit(1)
        print()
    cfg.gh_login = gh_auth_login(cfg) or ""
    if not cfg.gh_login:
        step_fail("Could not determine GitHub user")
        sys.exit(1)
    step_ok(f"GitHub authenticated as {cfg.gh_login}")

    # 4. claude CLI
    cfg.claude_path = shutil.which(cfg.claude_bin) or ""
    if not cfg.claude_path:
        step_fail("Claude CLI not found")
        if shutil.which("npm"):
            if _try_install("Claude CLI", cfg.claude_bin, ["npm", "install", "-g", "@anthropic-ai/claude-code"]):
                cfg.claude_path = shutil.which(cfg.claude_bin) or ""
        if not cfg.claude_path:
            print("  Install it: npm install -g @anthropic-ai/claude-code")
            sys.exit(1)
    step_ok("Claude CLI")

    # 5. claude auth
    if not check_claude_auth():
        step_fail("Claude CLI not authenticated")
        print("  Run: claude login")
        sys.exit(1)
    step_ok("Claude authenticated")

    # 6. git repo + GitHub remote
    if not os.path.isdir(cfg.repo_path):
        step_fail(f"Directory not found: {cfg.repo_path}")
        sys.exit(1)
    if run(["git", "-C", cfg.repo_path, "rev-parse", "--is-inside-work-tree"]).returncode != 0:
        step_fail(f"Not a git repository: {cfg.repo_path}")
        print("  Run autosde from inside a git repository, or pass --repo PATH")
        sys.exit(1)
    step_ok("git repository")

    if not cfg.github_repo:
        detected = parse_github_remote(cfg.repo_path)
        if detected and confirm(f"  Detected remote: {detected}. Use this? [Y/n]"):
            cfg.github_repo = detected
        else:
            cfg.github_repo = prompt_input("  Enter GitHub repo (owner/repo):")
        if not cfg.github_repo:
            step_fail("No GitHub repository specified")
            sys.exit(1)
    step_ok(f"repo: {cfg.github_repo}")

    # 7. verify command
    if cfg.verify_command:
        cfg.resolved_verify = cfg.verify_command
        cfg.verify_source = "configured"
    else:
        detected = detect_verify_command(cfg.repo_path)
        if detected and confirm(f"  Detected: {detected}. Use this? [Y/n]"):
            cfg.resolved_verify = detected
            cfg.verify_source = "auto-detected"
        else:
            cfg.resolved_verify = prompt_input("  Enter verify command:")
            cfg.verify_source = "configured"
        if not cfg.resolved_verify:
            step_fail("No verify command specified")
            sys.exit(1)
    step_ok(f"verify: {cfg.resolved_verify}")

    # 8. AGENT.md
    if not os.path.isfile(cfg.target_agent_file):
        _generate_agent_file(cfg)
        if not confirm(f"  Generated AGENT.md at {cfg.target_agent_file}. Continue? [Y/n]"):
            print("  Edit AGENT.md and re-run autosde.")
            sys.exit(0)
    step_ok("AGENT.md")

    _ensure_runtime(cfg)
    print()
    _print_summary(cfg)


def preflight(cfg: Config) -> None:
    """Headless preflight — validate everything, die on first failure."""
    if not cfg.github_repo:
        die("--github OWNER/REPO is required")

    if not os.path.isdir(cfg.repo_path):
        die(f"--repo path does not exist: {cfg.repo_path}")
    if run(["git", "-C", cfg.repo_path, "rev-parse", "--is-inside-work-tree"]).returncode != 0:
        die(f"--repo must point to a git repository: {cfg.repo_path}")

    cfg.claude_path = shutil.which(cfg.claude_bin) or ""
    if not cfg.claude_path:
        die(f"Claude CLI not found at '{cfg.claude_bin}'. Install it from {CLAUDE_SETUP_URL}")

    cfg.gh_path = shutil.which(cfg.gh_bin) or ""
    if not cfg.gh_path:
        die(f"GitHub CLI not found at '{cfg.gh_bin}'. Install it from {GH_SETUP_URL}")
    if run([cfg.gh_bin, "auth", "status"]).returncode != 0:
        die("GitHub CLI is not logged in. Run 'gh auth login' and try again.")
    cfg.gh_login = gh_auth_login(cfg) or ""
    if not cfg.gh_login:
        die("GitHub CLI is installed, but AutoSDE could not determine the logged-in user.")

    if cfg.verify_command:
        cfg.resolved_verify = cfg.verify_command
        cfg.verify_source = "configured"
    else:
        detected = detect_verify_command(cfg.repo_path)
        if not detected:
            die('Could not auto-detect a verification command. Pass --verify "COMMAND".')
        cfg.resolved_verify = detected
        cfg.verify_source = "auto-detected"

    if not os.path.isfile(cfg.target_agent_file):
        _generate_agent_file(cfg)

    _ensure_runtime(cfg)
    _print_summary(cfg)


def _generate_agent_file(cfg: Config) -> None:
    os.makedirs(os.path.dirname(cfg.target_agent_file), exist_ok=True)
    # Prefer the bundled AGENT.md next to the package, else use template
    bundled = Path(__file__).resolve().parent.parent / "AGENT.md"
    if bundled.is_file() and str(bundled) != cfg.target_agent_file:
        Path(cfg.target_agent_file).write_text(bundled.read_text())
    else:
        Path(cfg.target_agent_file).write_text(AGENT_TEMPLATE)


def _ensure_runtime(cfg: Config) -> None:
    os.makedirs(cfg.log_dir, exist_ok=True)
    if not os.path.isfile(cfg.results_log):
        with open(cfg.results_log, "w") as f:
            f.write("timestamp\tissue\tbranch\tstatus\tdescription\n")


def _print_summary(cfg: Config) -> None:
    verify_line = cfg.resolved_verify
    if cfg.verify_source == "auto-detected":
        verify_line += " (auto-detected)"
    note("AutoSDE starting")
    note(f"repo: {cfg.repo_path}")
    note(f"github: {cfg.github_repo}")
    note(f"verify: {verify_line}")
    note(f"claude: {cfg.claude_path} \u2713")
    note(f"gh: {cfg.gh_path} \u2713 (logged in as {cfg.gh_login})")
    note("AGENT.md: found")
    note('waiting for issues labeled "agent"...')


def main() -> None:
    args = parse_args()
    cfg = build_config(args)

    if sys.stdin.isatty() and cfg.cli_github is None:
        interactive_onboarding(cfg)
    else:
        preflight(cfg)

    from .loop import run_loop

    run_loop(cfg)
