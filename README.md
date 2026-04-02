# AutoSDE

AutoSDE is an always-on AI agent that works on a GitHub repository by picking up labeled issues, making changes on a branch, verifying the result, and opening PRs for review.

The project is directly inspired by Karpathy's `autoresearch`: one prompt file defines behavior, one loop drives execution, CI is the ground truth, and Git is the memory plus rollback layer.

## Files

```text
autosde/
├── loop.sh
├── AGENT.md
├── results.log
├── README.md
├── .gitignore
└── logs/
```

## How To Use It

1. Clone this repo.
2. Put `AGENT.md` in your target repo and adapt its scope and boundaries for that repo.
3. Configure `loop.sh` with your target repo path and GitHub repo name. Set `VERIFY_COMMAND` if auto-detection is not enough.
4. Run `./loop.sh` inside a `tmux` session.
5. Label issues with `agent` to give the loop work.
6. Review the PRs as they come in.

## Architecture

```text
GitHub Issues (labeled "agent")
     |
     v
loop.sh (picks task, creates branch)
     |
     v
Claude Code (reads AGENT.md, implements solution)
     |
     v
CI (green/red)
     |
     +-- green -> PR created, awaits human review
     |
     +-- red   -> retry once, then discard + explain
```

## Notes

- `results.log` is a local append-only TSV log.
- `logs/` stores per-task Claude and verification output.
- `REPO_PATH` should point at a dedicated clone because the loop resets the worktree between tasks.
