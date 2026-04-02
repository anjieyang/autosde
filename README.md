# AutoSDE

Label an issue, go to sleep, wake up to a PR.

AutoSDE is an always-on shell loop inspired by Karpathy's `autoresearch`: one prompt file defines agent behavior, one loop drives execution, CI is the ground truth, and Git is memory plus rollback.

## Quick Start

1. Install AutoSDE:

```bash
curl -fsSL https://raw.githubusercontent.com/anjieyang/autosde/main/install.sh | bash
```

2. Move into the repo you want AutoSDE to work on:

```bash
cd ~/my-project
```

3. Start the loop:

```bash
autosde --github owner/repo
```

If AutoSDE cannot auto-detect your test command, pass one explicitly:

```bash
autosde --github owner/repo --verify "npm test"
```

## Prerequisites

- `claude` CLI installed and logged in. AutoSDE links to Anthropic's setup guide if it is missing.
- `gh` CLI installed and logged in with access to the target repository.
- A git repository with a working test or CI command.
- On macOS, install GNU coreutils so `gtimeout` is available for Claude timeouts.

## How It Works

```text
GitHub Issues (labeled "agent")
     |
     v
autosde / loop.sh (picks task, creates branch)
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
- `--github OWNER/REPO`: GitHub repository name. Required unless `GITHUB_REPO` is already set.
- `--verify "COMMAND"`: verification command. If omitted, AutoSDE auto-detects one.
- `--sleep SECONDS`: idle polling interval. Defaults to `900`.
- `--claude-bin PATH`: Claude CLI binary. Defaults to `claude`.
- `--gh-bin PATH`: GitHub CLI binary. Defaults to `gh`.
- `--timeout SECONDS`: Claude execution timeout. Defaults to `600`.
- Command-line flags override environment variables, and environment variables override defaults.

## AGENT.md Customization

On first run, AutoSDE checks the target repo for `AGENT.md`. If it is missing, AutoSDE writes a default template to `REPO_PATH/AGENT.md` and prints:

```text
Generated default AGENT.md at PATH, review and customize the scope section
```

Before leaving the loop unattended, review that file and tighten the `You CAN modify` scope line to match the real boundaries of your repo.

## Notes

- AutoSDE keeps `results.log` and per-task logs under `AUTOSDE_HOME`, which defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/autosde`.
- The target repo should be a dedicated clone. AutoSDE hard-resets it between tasks.
