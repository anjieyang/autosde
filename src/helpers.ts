import { spawnSync, execSync, type SpawnSyncOptions } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

export const CLAUDE_SETUP_URL =
  "https://docs.anthropic.com/en/docs/claude-code/getting-started";
export const GH_SETUP_URL = "https://cli.github.com/";

export const AGENT_TEMPLATE = `# AutoSDE Agent Instructions

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
- Title: \`[AutoSDE] <concise description>\`
- Body: What was changed, why, and link to the issue (\`Closes #N\`)
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
- If you find something worth doing, create an issue labeled \`agent\` and \`agent-proposed\`.
- Do NOT make changes without creating an issue first.

## Boundaries (NEVER cross these)
- Never push directly to main.
- Never modify CI/CD configuration.
- Never delete or weaken tests.
- Never make changes outside your allowed scope directories.
- When in doubt, create an issue and ask instead of guessing.

## Logging
After each task, report what you tried, what the outcome was, and what you learned.
This goes both as an issue comment and into \`results.log\`.

## Adaptation Note
This file is a template. Before using AutoSDE on a real repository, replace the scope line with the exact directories and constraints for that codebase.
`;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

export interface Config {
  repoPath: string;
  githubRepo: string;
  verifyCommand: string;
  sleepInterval: number;
  claudeBin: string;
  ghBin: string;
  timeoutSeconds: number;
  autosdeHome: string;
  resultsLog: string;
  logDir: string;
  targetAgentFile: string;
  resolvedVerify: string;
  verifySource: string;
  claudePath: string;
  ghPath: string;
  ghLogin: string;
  cliGithub: string | null;
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

export function timestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function note(msg: string): void {
  process.stderr.write(`[${timestamp()}] ${msg}\n`);
}

export function die(msg: string): never {
  note(msg);
  process.exit(1);
}

export function stepOk(msg: string): void {
  process.stdout.write(`  \u2713 ${msg}\n`);
}

export function stepFail(msg: string): void {
  process.stdout.write(`  \u2717 ${msg}\n`);
}

// ---------------------------------------------------------------------------
// Interactive I/O (synchronous via /dev/tty)
// ---------------------------------------------------------------------------

function readLine(prompt: string): string {
  process.stdout.write(`${prompt} `);
  const buf = Buffer.alloc(1);
  let str = "";
  const fd = fs.openSync("/dev/tty", "rs");
  try {
    while (fs.readSync(fd, buf, 0, 1, null) > 0) {
      const ch = buf.toString("utf8", 0, 1);
      if (ch === "\n") break;
      if (ch !== "\r") str += ch;
    }
  } finally {
    fs.closeSync(fd);
  }
  return str.trim();
}

export function confirm(prompt: string): boolean {
  const reply = readLine(prompt).toLowerCase();
  return !reply || reply[0] !== "n";
}

export function promptInput(prompt: string): string {
  return readLine(prompt);
}

// ---------------------------------------------------------------------------
// Subprocess
// ---------------------------------------------------------------------------

export interface RunResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  status: number | null;
}

export function run(
  cmd: string,
  args: string[],
  opts?: SpawnSyncOptions,
): RunResult {
  const r = spawnSync(cmd, args, { encoding: "utf8", ...opts });
  return {
    ok: r.status === 0,
    stdout: (r.stdout as string) ?? "",
    stderr: (r.stderr as string) ?? "",
    status: r.status,
  };
}

export function git(repoPath: string, ...args: string[]): RunResult {
  return run("git", ["-C", repoPath, ...args]);
}

export function gh(ghBin: string, ...args: string[]): RunResult {
  return run(ghBin, args);
}

export function which(cmd: string): string | null {
  try {
    return execSync(`command -v ${cmd}`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return null;
  }
}

export function sleepSync(seconds: number): void {
  spawnSync("sleep", [String(seconds)]);
}

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    .slice(0, 40);
}

export function sanitize(text: string): string {
  return text.replace(/[\t\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

export function detectPlatform(): string {
  if (process.platform === "darwin") return "macos";
  if (process.platform === "linux") {
    try {
      const content = fs.readFileSync("/etc/os-release", "utf8").toLowerCase();
      if (/fedora|rhel|centos/.test(content)) return "fedora";
    } catch {}
    return "debian";
  }
  return "unknown";
}

function detectJsRunner(repo: string): string {
  const has = (f: string) => fs.existsSync(path.join(repo, f));
  if (has("bun.lockb") || has("bun.lock")) return "bun";
  if (has("pnpm-lock.yaml")) return "pnpm";
  if (has("yarn.lock")) return "yarn";
  return "npm";
}

export function detectVerifyCommand(repo: string): string | null {
  const has = (f: string) => fs.existsSync(path.join(repo, f));
  const read = (f: string) => {
    try {
      return fs.readFileSync(path.join(repo, f), "utf8");
    } catch {
      return "";
    }
  };

  const makefile = read("Makefile");
  if (makefile) {
    if (/^ci:/m.test(makefile)) return "make ci";
    if (/^test:/m.test(makefile)) return "make test";
  }

  if (has("package.json")) {
    const pkg = read("package.json");
    const runner = detectJsRunner(repo);
    for (const script of ["ci", "test"]) {
      if (new RegExp(`"${script}"\\s*:`).test(pkg)) {
        return runner === "yarn" ? `yarn ${script}` : `${runner} run ${script}`;
      }
    }
  }

  if (has("pytest.ini") || has("conftest.py")) return "pytest";
  if (has("pyproject.toml") && /pytest|tool\.poetry|project/.test(read("pyproject.toml")))
    return "pytest";
  if (has("Cargo.toml")) return "cargo test";
  if (has("go.mod")) return "go test ./...";
  if (has("bin/rails")) return "bin/rails test";
  if (has("Gemfile") && fs.existsSync(path.join(repo, "spec")))
    return "bundle exec rspec";

  return null;
}

export function parseGithubRemote(repo: string): string | null {
  const r = git(repo, "remote", "get-url", "origin");
  if (!r.ok) return null;
  const url = r.stdout
    .trim()
    .replace(/^git@github\.com:/, "")
    .replace(/^https:\/\/github\.com\//, "")
    .replace(/\.git$/, "");
  return url.includes("/") ? url : null;
}

export function checkClaudeAuth(): boolean {
  if (process.env.ANTHROPIC_API_KEY) return true;
  const claudeDir = path.join(os.homedir(), ".claude");
  try {
    const entries = fs.readdirSync(claudeDir);
    return entries.length > 0;
  } catch {
    return false;
  }
}
