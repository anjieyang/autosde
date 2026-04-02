# AutoSDE

Label an issue, go to sleep, wake up to a PR.

AutoSDE is an always-on loop inspired by Karpathy's `autoresearch`: one prompt file defines agent behavior, one loop drives execution, CI is the ground truth, and Git is memory plus rollback.

## Quick Start

```bash
pip install autosde
cd ~/my-project
autosde
```

AutoSDE walks you through setup on first run — installing missing dependencies, detecting your GitHub remote, and picking a test command. Or pass arguments directly for headless use:

```bash
autosde --github owner/repo --verify "pytest"
```

## Prerequisites

- Python 3.10+.
- `claude` CLI installed and logged in.
- `gh` CLI installed and logged in with access to the target repository.
- A git repository with a working test or CI command.

Missing `gh` or `claude`? AutoSDE offers to install them during interactive setup.

## How It Works

```text
GitHub Issues (labeled "agent")
     |
     v
autosde (picks task, creates branch)
     |
     v
Claude Code (reads AGENT.md, implements solution)
     |
     v
CI / test command (green/red)
     |
     +-- green -> PR created, awaits human review
     |
     +-- red   -> retry once, then discard + explain
```

## Configuration

- `--repo PATH`: target repository path. Defaults to the current directory.
- `--github OWNER/REPO`: GitHub repository. Detected interactively if omitted.
- `--verify "COMMAND"`: verification command. If omitted, AutoSDE auto-detects one.
- `--sleep SECONDS`: idle polling interval. Defaults to `900`.
- `--claude-bin PATH`: Claude CLI binary. Defaults to `claude`.
- `--gh-bin PATH`: GitHub CLI binary. Defaults to `gh`.
- `--timeout SECONDS`: Claude execution timeout. Defaults to `600`.
- Command-line flags override environment variables, and environment variables override defaults.

## AGENT.md Customization

On first run, AutoSDE checks the target repo for `AGENT.md`. If it is missing, AutoSDE writes a default template and asks for confirmation before continuing.

Before leaving the loop unattended, review that file and tighten the `You CAN modify` scope line to match the real boundaries of your repo.

## Notes

- AutoSDE keeps `results.log` and per-task logs under `AUTOSDE_HOME`, which defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/autosde`.
- The target repo should be a dedicated clone. AutoSDE hard-resets it between tasks.
