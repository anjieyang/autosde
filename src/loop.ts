import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

import {
  type Config,
  detectVerifyCommand,
  gh,
  git,
  note,
  run,
  sanitize,
  sleepSync,
  slugify,
  timestamp,
  which,
} from "./helpers";
import { generateAgentFile } from "./cli";

// ---------------------------------------------------------------------------
// Git operations
// ---------------------------------------------------------------------------

function defaultBranch(cfg: Config): string {
  const r = gh(cfg.ghBin, "repo", "view", cfg.githubRepo,
    "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name");
  if (r.ok && r.stdout.trim() && r.stdout.trim() !== "null") return r.stdout.trim();

  const sym = git(cfg.repoPath, "symbolic-ref", "refs/remotes/origin/HEAD");
  if (sym.ok && sym.stdout.trim())
    return sym.stdout.trim().replace("refs/remotes/origin/", "");

  return git(cfg.repoPath, "rev-parse", "--verify", "origin/main").ok ? "main" : "master";
}

function checkoutClean(cfg: Config, branch: string): boolean {
  if (!git(cfg.repoPath, "fetch", "origin", branch, "--prune").ok) return false;
  if (!git(cfg.repoPath, "checkout", branch).ok)
    if (!git(cfg.repoPath, "checkout", "-B", branch, `origin/${branch}`).ok) return false;
  if (!git(cfg.repoPath, "reset", "--hard", `origin/${branch}`).ok) return false;
  git(cfg.repoPath, "clean", "-fd");
  return true;
}

function createBranch(cfg: Config, branch: string, base: string): boolean {
  return git(cfg.repoPath, "checkout", "-B", branch, `origin/${base}`).ok;
}

function branchHasChanges(cfg: Config, base: string): boolean {
  const diff = git(cfg.repoPath, "diff", "--quiet", `origin/${base}...HEAD`);
  const status = git(cfg.repoPath, "status", "--porcelain");
  return !diff.ok || !!status.stdout.trim();
}

function commitIfNeeded(cfg: Config, issueNumber: string, title: string): boolean {
  if (!git(cfg.repoPath, "status", "--porcelain").stdout.trim()) return true;
  git(cfg.repoPath, "add", "-A");
  return git(cfg.repoPath, "commit", "-m", `[AutoSDE] #${issueNumber} ${title}`).ok;
}

function pushBranch(cfg: Config, branch: string): boolean {
  return git(cfg.repoPath, "push", "-u", "origin", branch, "--force-with-lease").ok;
}

function cleanupBranch(cfg: Config, branch: string, base: string): void {
  git(cfg.repoPath, "checkout", base);
  git(cfg.repoPath, "reset", "--hard", `origin/${base}`);
  git(cfg.repoPath, "clean", "-fd");
  git(cfg.repoPath, "branch", "-D", branch);
}

function discardBranch(cfg: Config, branch: string, base: string): void {
  git(cfg.repoPath, "checkout", base);
  git(cfg.repoPath, "reset", "--hard", `origin/${base}`);
  git(cfg.repoPath, "clean", "-fd");
  git(cfg.repoPath, "branch", "-D", branch);
  git(cfg.repoPath, "push", "origin", "--delete", branch);
}

// ---------------------------------------------------------------------------
// GitHub operations
// ---------------------------------------------------------------------------

function selectIssueNumber(cfg: Config): string | null {
  const r = gh(cfg.ghBin, "issue", "list",
    "--repo", cfg.githubRepo, "--state", "open", "--label", "agent",
    "--limit", "100", "--json", "number,labels,assignees");
  if (!r.ok) return null;

  let issues: any[];
  try { issues = JSON.parse(r.stdout); } catch { return null; }

  issues = issues.filter((i: any) => !i.assignees?.length);

  const prio = (i: any) => {
    const labels = new Set((i.labels ?? []).map((l: any) => l.name));
    if (labels.has("bug")) return 0;
    if (labels.has("feature")) return 1;
    if (labels.has("refactor")) return 2;
    if (labels.has("chore")) return 3;
    return 4;
  };
  issues.sort((a: any, b: any) => prio(a) - prio(b) || a.number - b.number);
  return issues.length ? String(issues[0].number) : null;
}

function issueField(cfg: Config, number: string, field: string): string {
  const r = gh(cfg.ghBin, "issue", "view", number,
    "--repo", cfg.githubRepo, "--json", field, "--jq", `.${field}`);
  return r.ok ? r.stdout.trim() : "";
}

function claimIssue(cfg: Config, number: string, login: string): boolean {
  const a = gh(cfg.ghBin, "issue", "edit", number, "--repo", cfg.githubRepo, "--add-assignee", login);
  const c = gh(cfg.ghBin, "issue", "comment", number, "--repo", cfg.githubRepo, "--body", "I'm picking this up.");
  return a.ok && c.ok;
}

function releaseIssue(cfg: Config, number: string, login: string): void {
  gh(cfg.ghBin, "issue", "edit", number, "--repo", cfg.githubRepo, "--remove-assignee", login);
}

function commentIssue(cfg: Config, number: string, body: string): void {
  gh(cfg.ghBin, "issue", "comment", number, "--repo", cfg.githubRepo, "--body", body);
}

function createPr(cfg: Config, branch: string, base: string,
  number: string, title: string, reviewer: string): string | null {
  const summary = git(cfg.repoPath, "diff", "--stat", "--compact-summary", `origin/${base}...HEAD`);
  const stats = summary.stdout.trim() ||
    git(cfg.repoPath, "log", "--oneline", `origin/${base}..HEAD`).stdout.trim();

  const body = `Automated implementation for #${number}.\n\nWhat changed:\n${stats}\n\nCloses #${number}`;
  const r = gh(cfg.ghBin, "pr", "create",
    "--repo", cfg.githubRepo, "--base", base, "--head", branch,
    "--title", `[AutoSDE] ${title}`, "--body", body);
  if (!r.ok) return null;

  const prUrl = r.stdout.trim();
  gh(cfg.ghBin, "pr", "edit", prUrl, "--repo", cfg.githubRepo, "--add-reviewer", reviewer);
  return prUrl;
}

function proposedIssueExists(cfg: Config, title: string): boolean {
  const r = gh(cfg.ghBin, "issue", "list",
    "--repo", cfg.githubRepo, "--state", "open", "--label", "agent-proposed",
    "--limit", "100", "--json", "title");
  if (!r.ok) return false;
  try {
    return (JSON.parse(r.stdout) as any[]).some((i) => i.title === title);
  } catch { return false; }
}

function createProposedIssue(cfg: Config, title: string, body: string, priority: string): void {
  if (proposedIssueExists(cfg, title)) {
    note(`Skipping proposed issue (duplicate): ${title}`);
    return;
  }
  gh(cfg.ghBin, "issue", "create",
    "--repo", cfg.githubRepo, "--title", title, "--body", body,
    "--label", "agent", "--label", "agent-proposed", "--label", priority);
}

// ---------------------------------------------------------------------------
// Claude runner
// ---------------------------------------------------------------------------

function buildPrompt(cfg: Config, number: string, title: string, url: string,
  body: string, branch: string, retryContext = ""): string {
  const agent = fs.readFileSync(cfg.targetAgentFile, "utf8");
  const lines = [
    `You are working inside the repository at ${cfg.repoPath}.`,
    `Stay on branch ${branch}.\n`,
    "Follow the repository AGENT.md instructions below exactly.\n",
    "----- BEGIN AGENT.md -----",
    agent,
    "----- END AGENT.md -----\n",
    "Current issue:",
    `#${number}: ${title}`,
    `${url}\n`,
    `Issue body:\n${body}\n`,
    "Harness expectations:",
    "- Work only in this repository.",
    "- Use GitHub CLI if you need to comment on the issue or inspect metadata.",
    "- Leave the branch ready for verification by the harness when you finish.",
  ];
  if (retryContext) lines.push(`\nRetry context:\n${retryContext}`);
  return lines.join("\n");
}

function runClaude(cfg: Config, prompt: string, logPath: string): boolean {
  const fd = fs.openSync(logPath, "a");
  fs.writeSync(fd, `=== ${timestamp()} Claude invocation started ===\ntimeout: ${cfg.timeoutSeconds}s\n`);

  const r = spawnSync(cfg.claudeBin, [
    "--bare", "-p", "--allowedTools", "Read,Edit,Write,Bash,Glob,Grep",
  ], {
    cwd: cfg.repoPath,
    timeout: cfg.timeoutSeconds * 1000,
    input: prompt,
    stdio: ["pipe", fd, fd],
  });

  if (r.error && (r.error as any).code === "ETIMEDOUT") {
    fs.writeSync(fd, `\n=== ${timestamp()} Claude timed out after ${cfg.timeoutSeconds}s ===\n`);
    fs.closeSync(fd);
    return false;
  }
  if (r.status === 0) {
    fs.writeSync(fd, `\n=== ${timestamp()} Claude finished successfully ===\n`);
    fs.closeSync(fd);
    return true;
  }

  fs.writeSync(fd, `\n=== ${timestamp()} Claude failed with exit code ${r.status} ===\n`);
  if (r.stderr) fs.writeSync(fd, `stderr: ${r.stderr}\n`);
  fs.closeSync(fd);
  return false;
}

function runVerification(cfg: Config, logPath: string): boolean {
  const fd = fs.openSync(logPath, "a");
  fs.writeSync(fd, `\n=== ${timestamp()} Verification: ${cfg.resolvedVerify} ===\n`);
  const r = spawnSync("bash", ["-lc", cfg.resolvedVerify], {
    cwd: cfg.repoPath, stdio: ["inherit", fd, fd],
  });
  fs.writeSync(fd, `\n=== ${timestamp()} Verification exit code: ${r.status} ===\n`);
  fs.closeSync(fd);
  return r.status === 0;
}

function failureExcerpt(logPath: string): string {
  try {
    const lines = fs.readFileSync(logPath, "utf8").split("\n");
    return lines.slice(-60).join("\n").slice(-3500);
  } catch { return "(no log available)"; }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function logResult(cfg: Config, issue = "-", branch = "-", status = "crashed", description = ""): void {
  const line = [timestamp(), issue, branch, status, sanitize(description)].join("\t");
  fs.appendFileSync(cfg.resultsLog, line + "\n");
}

// ---------------------------------------------------------------------------
// Research mode
// ---------------------------------------------------------------------------

function searchTool(): string {
  return which("rg") ? "rg" : "grep";
}

function runAudit(cfg: Config): string | null {
  const has = (f: string) => fs.existsSync(path.join(cfg.repoPath, f));
  const cmds: string[][] = [];

  if (has("package.json")) cmds.push(["npm", "audit"]);
  if (has("Cargo.lock") && which("cargo-audit")) cmds.push(["cargo", "audit"]);
  if (has("Gemfile.lock") && which("bundle-audit")) cmds.push(["bundle", "audit", "check"]);
  if ((has("requirements.txt") || has("pyproject.toml")) && which("pip-audit")) cmds.push(["pip-audit"]);

  for (const cmd of cmds) {
    if (!which(cmd[0])) continue;
    const r = run(cmd[0], cmd.slice(1), { cwd: cfg.repoPath });
    const out = r.stdout + r.stderr;
    if (/vulnerab|advisories|severity|critical|high/i.test(out)) return out;
  }
  return null;
}

function researchMode(cfg: Config): void {
  note("No unclaimed agent issues found. Entering research mode.");

  // 1. Dependency audit
  const audit = runAudit(cfg);
  if (audit) {
    const excerpt = audit.split("\n").slice(-40).join("\n");
    createProposedIssue(cfg,
      "Investigate dependency vulnerabilities reported by automated audit",
      `Research mode found dependency audit output that appears actionable.\n\nAudit excerpt:\n\`\`\`\n${excerpt}\n\`\`\``,
      "bug");
    return;
  }

  const tool = searchTool();

  // 2. TODO/FIXME scan
  const todoArgs = tool === "rg"
    ? ["rg", "-n", "--glob", "!.git", "--glob", "!node_modules", "--glob", "!vendor", "TODO|FIXME", "."]
    : ["grep", "-RInE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=vendor", "TODO|FIXME", "."];
  const todoR = run(todoArgs[0], todoArgs.slice(1), { cwd: cfg.repoPath });
  const todoHits = todoR.stdout.split("\n").slice(0, 10).join("\n").trim();
  if (todoHits) {
    createProposedIssue(cfg,
      "Review TODO and FIXME markers discovered in research mode",
      `Research mode found TODO/FIXME markers that may be worth turning into concrete work.\n\nMatches:\n\`\`\`\n${todoHits}\n\`\`\``,
      "refactor");
    return;
  }

  // 3. Code smells
  const pat = "console\\.log|debugger|it\\.skip|describe\\.skip|skip\\(";
  const smellArgs = tool === "rg"
    ? ["rg", "-n", "--glob", "!.git", "--glob", "!node_modules", "--glob", "!vendor", pat, "."]
    : ["grep", "-RInE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=vendor", pat, "."];
  const smellR = run(smellArgs[0], smellArgs.slice(1), { cwd: cfg.repoPath });
  const smellHits = smellR.stdout.split("\n").slice(0, 10).join("\n").trim();
  if (smellHits) {
    createProposedIssue(cfg,
      "Clean up obvious code smells discovered in research mode",
      `Research mode found code smells that look actionable.\n\nMatches:\n\`\`\`\n${smellHits}\n\`\`\``,
      "refactor");
    return;
  }

  note("Research mode found nothing actionable.");
}

// ---------------------------------------------------------------------------
// Issue processing
// ---------------------------------------------------------------------------

function processIssue(cfg: Config, number: string, login: string, base: string, reviewer: string): void {
  const title = issueField(cfg, number, "title");
  const body = issueField(cfg, number, "body");
  const url = issueField(cfg, number, "url");

  if (!title) { logResult(cfg, number, "-", "crashed", "Unable to load issue details"); return; }

  const branch = `autosde/${number}-${slugify(title) || "task"}`;
  const logPath = path.join(cfg.logDir, `issue-${number}-${timestamp().replace(/:/g, "")}.log`);

  if (!claimIssue(cfg, number, login)) {
    logResult(cfg, number, branch, "crashed", "Unable to claim issue"); return;
  }

  const crash = (reason: string, logMsg: string) => {
    commentIssue(cfg, number, `I picked this up on \`${branch}\`, but the harness crashed before it could finish.\n\nReason:\n${reason}`);
    releaseIssue(cfg, number, login);
    discardBranch(cfg, branch, base);
    logResult(cfg, number, branch, "crashed", logMsg);
  };

  if (!checkoutClean(cfg, base)) { crash(`Unable to reset to origin/${base}.`, "Unable to reset target repository"); return; }
  if (!fs.existsSync(cfg.targetAgentFile)) generateAgentFile(cfg);
  if (!createBranch(cfg, branch, base)) { crash("Unable to create the working branch.", "Unable to create working branch"); return; }

  const prompt = buildPrompt(cfg, number, title, url, body, branch);
  if (!runClaude(cfg, prompt, logPath)) {
    crash("Claude Code failed or timed out before a verified change was produced.", "Claude invocation failed or timed out");
    return;
  }

  if (!branchHasChanges(cfg, base)) {
    commentIssue(cfg, number, `I picked this up on \`${branch}\`, but I discarded the branch.\n\nReason:\nNo code changes were produced.`);
    releaseIssue(cfg, number, login);
    discardBranch(cfg, branch, base);
    logResult(cfg, number, branch, "discarded", "No code changes were produced");
    return;
  }

  if (!runVerification(cfg, logPath)) {
    const retryContext = `The first verification attempt failed.\n\nVerification command:\n${cfg.resolvedVerify}\n\nFailure excerpt:\n${failureExcerpt(logPath)}`;
    const retryPrompt = buildPrompt(cfg, number, title, url, body, branch, retryContext);

    if (!runClaude(cfg, retryPrompt, logPath) || !runVerification(cfg, logPath)) {
      const excerpt = failureExcerpt(logPath);
      commentIssue(cfg, number, `I tried to address this on \`${branch}\`, but verification failed twice, so I discarded the branch.\n\nLatest log excerpt:\n\`\`\`\n${excerpt}\n\`\`\``);
      releaseIssue(cfg, number, login);
      discardBranch(cfg, branch, base);
      logResult(cfg, number, branch, "discarded", "Verification failed twice");
      return;
    }
  }

  if (!commitIfNeeded(cfg, number, title)) { crash("Verification passed, but could not create a commit.", "Unable to commit"); return; }
  if (!pushBranch(cfg, branch)) { crash("Verification passed, but could not push the branch.", "Unable to push"); return; }

  const prUrl = createPr(cfg, branch, base, number, title, reviewer);
  if (!prUrl) {
    commentIssue(cfg, number, `I picked this up on \`${branch}\`, but PR creation failed after push.`);
    logResult(cfg, number, branch, "crashed", "Unable to create PR after push");
    return;
  }

  commentIssue(cfg, number, `Implemented this and opened a PR for review:\n\n${prUrl}`);
  cleanupBranch(cfg, branch, base);
  logResult(cfg, number, branch, "pr-created", `Created PR ${prUrl}`);
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

function runIteration(cfg: Config): void {
  const login = cfg.ghLogin;
  const base = defaultBranch(cfg);
  const reviewer = cfg.githubRepo.split("/")[0];

  if (!login || !base) {
    logResult(cfg, "-", "-", "crashed", "Unable to determine GitHub login or default branch");
    sleepSync(cfg.sleepInterval);
    return;
  }

  const number = selectIssueNumber(cfg);

  if (!number) {
    researchMode(cfg);
    note(`Sleeping for ${cfg.sleepInterval} seconds.`);
    sleepSync(cfg.sleepInterval);
    return;
  }

  processIssue(cfg, number, login, base, reviewer);
}

export function runLoop(cfg: Config): void {
  while (true) {
    try {
      runIteration(cfg);
    } catch (err) {
      note(`Iteration error: ${err}`);
      sleepSync(cfg.sleepInterval);
    }
  }
}
