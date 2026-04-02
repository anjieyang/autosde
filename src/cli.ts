import { parseArgs } from "node:util";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  AGENT_TEMPLATE,
  CLAUDE_SETUP_URL,
  GH_SETUP_URL,
  type Config,
  checkClaudeAuth,
  confirm,
  detectPlatform,
  detectVerifyCommand,
  die,
  gh,
  note,
  parseGithubRemote,
  promptInput,
  run,
  stepFail,
  stepOk,
  which,
} from "./helpers";
import { runLoop } from "./loop";

// ---------------------------------------------------------------------------
// Version (injected by tsup define or read from package.json)
// ---------------------------------------------------------------------------

const VERSION = "0.2.0";

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

function printHelp(): void {
  process.stdout.write(`autosde ${VERSION} — Label an issue, go to sleep, wake up to a PR.

Usage: autosde [options]

Options:
  --repo PATH          Target repository path (default: cwd)
  --github OWNER/REPO  GitHub repo. Detected interactively if omitted.
  --verify COMMAND      Verification command. Auto-detected if omitted.
  --sleep SECONDS       Poll interval (default: 900)
  --claude-bin PATH     Claude CLI binary (default: claude)
  --gh-bin PATH         gh CLI binary (default: gh)
  --timeout SECONDS     Claude timeout (default: 600)
  -h, --help            Show this help message
  -v, --version         Show version
`);
}

interface CliArgs {
  repo?: string;
  github?: string;
  verify?: string;
  sleep?: string;
  claudeBin?: string;
  ghBin?: string;
  timeout?: string;
  help: boolean;
  version: boolean;
}

function parseCliArgs(): CliArgs {
  const { values } = parseArgs({
    options: {
      repo: { type: "string" },
      github: { type: "string" },
      verify: { type: "string" },
      sleep: { type: "string" },
      "claude-bin": { type: "string" },
      "gh-bin": { type: "string" },
      timeout: { type: "string" },
      help: { type: "boolean", short: "h", default: false },
      version: { type: "boolean", short: "v", default: false },
    },
    strict: true,
  });
  return {
    repo: values.repo as string | undefined,
    github: values.github as string | undefined,
    verify: values.verify as string | undefined,
    sleep: values.sleep as string | undefined,
    claudeBin: values["claude-bin"] as string | undefined,
    ghBin: values["gh-bin"] as string | undefined,
    timeout: values.timeout as string | undefined,
    help: values.help as boolean,
    version: values.version as boolean,
  };
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

function buildConfig(args: CliArgs): Config {
  const env = process.env;
  const xdg = env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state");
  const home = env.AUTOSDE_HOME ?? path.join(xdg, "autosde");
  const repoPath = fs.realpathSync(args.repo ?? env.REPO_PATH ?? process.cwd());

  const agent = env.TARGET_AGENT_FILE ?? "AGENT.md";
  const targetAgent = path.isAbsolute(agent) ? agent : path.join(repoPath, agent);

  return {
    repoPath,
    githubRepo: args.github ?? env.GITHUB_REPO ?? "",
    verifyCommand: args.verify ?? env.VERIFY_COMMAND ?? "",
    sleepInterval: Number(args.sleep ?? env.SLEEP_INTERVAL ?? "900"),
    claudeBin: args.claudeBin ?? env.CLAUDE_BIN ?? "claude",
    ghBin: args.ghBin ?? env.GH_BIN ?? "gh",
    timeoutSeconds: Number(args.timeout ?? env.TIMEOUT_SECONDS ?? "600"),
    autosdeHome: home,
    resultsLog: env.RESULTS_LOG ?? path.join(home, "results.log"),
    logDir: env.LOG_DIR ?? path.join(home, "logs"),
    targetAgentFile: targetAgent,
    resolvedVerify: "",
    verifySource: "",
    claudePath: "",
    ghPath: "",
    ghLogin: "",
    cliGithub: args.github ?? null,
  };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function ghAuthLogin(cfg: Config): string {
  const r = gh(cfg.ghBin, "api", "user", "--jq", ".login");
  return r.stdout.trim();
}

function tryInstall(label: string, cmd: string, installCmd: string[]): boolean {
  if (which(cmd)) return true;
  if (confirm(`  Install ${label}? [Y/n]`)) {
    process.stdout.write(`  Running: ${installCmd.join(" ")}\n`);
    if (spawnSync(installCmd[0], installCmd.slice(1), { stdio: "inherit" }).status === 0) {
      return true;
    }
    stepFail(`${label} installation failed`);
  }
  return false;
}

export function generateAgentFile(cfg: Config): void {
  fs.mkdirSync(path.dirname(cfg.targetAgentFile), { recursive: true });
  const bundled = path.join(__dirname, "..", "AGENT.md");
  if (fs.existsSync(bundled) && fs.realpathSync(bundled) !== cfg.targetAgentFile) {
    fs.copyFileSync(bundled, cfg.targetAgentFile);
  } else {
    fs.writeFileSync(cfg.targetAgentFile, AGENT_TEMPLATE);
  }
}

function ensureRuntime(cfg: Config): void {
  fs.mkdirSync(cfg.logDir, { recursive: true });
  if (!fs.existsSync(cfg.resultsLog)) {
    fs.writeFileSync(cfg.resultsLog, "timestamp\tissue\tbranch\tstatus\tdescription\n");
  }
}

function printSummary(cfg: Config): void {
  const vl = cfg.verifySource === "auto-detected"
    ? `${cfg.resolvedVerify} (auto-detected)`
    : cfg.resolvedVerify;
  note("AutoSDE starting");
  note(`repo: ${cfg.repoPath}`);
  note(`github: ${cfg.githubRepo}`);
  note(`verify: ${vl}`);
  note(`claude: ${cfg.claudePath} \u2713`);
  note(`gh: ${cfg.ghPath} \u2713 (logged in as ${cfg.ghLogin})`);
  note("AGENT.md: found");
  note('waiting for issues labeled "agent"...');
}

// ---------------------------------------------------------------------------
// Interactive onboarding
// ---------------------------------------------------------------------------

function interactiveOnboarding(cfg: Config): void {
  process.stdout.write("AutoSDE setup\n\n");

  // 1. git
  if (!which("git")) {
    stepFail("git not found");
    process.stdout.write("  Install git: https://git-scm.com/downloads\n");
    process.exit(1);
  }
  stepOk("git");

  // 2. gh CLI
  cfg.ghPath = which(cfg.ghBin) ?? "";
  if (!cfg.ghPath) {
    stepFail("GitHub CLI not found");
    const plat = detectPlatform();
    if (plat === "macos" && which("brew")) {
      if (tryInstall("GitHub CLI", cfg.ghBin, ["brew", "install", "gh"])) {
        cfg.ghPath = which(cfg.ghBin) ?? "";
      }
    } else if (plat === "debian") {
      process.stdout.write("  Install it: sudo apt install gh\n");
    } else if (plat === "fedora") {
      process.stdout.write("  Install it: sudo dnf install gh\n");
    } else {
      process.stdout.write(`  Install it: ${GH_SETUP_URL}\n`);
    }
    if (!cfg.ghPath) process.exit(1);
  }
  stepOk("GitHub CLI");

  // 3. gh auth
  if (!gh(cfg.ghBin, "auth", "status").ok) {
    stepFail("GitHub CLI not logged in");
    process.stdout.write("  Running: gh auth login\n\n");
    if (spawnSync(cfg.ghBin, ["auth", "login"], { stdio: "inherit" }).status !== 0) {
      process.stdout.write("\n");
      stepFail("GitHub authentication failed");
      process.exit(1);
    }
    process.stdout.write("\n");
  }
  cfg.ghLogin = ghAuthLogin(cfg);
  if (!cfg.ghLogin) {
    stepFail("Could not determine GitHub user");
    process.exit(1);
  }
  stepOk(`GitHub authenticated as ${cfg.ghLogin}`);

  // 4. claude CLI
  cfg.claudePath = which(cfg.claudeBin) ?? "";
  if (!cfg.claudePath) {
    stepFail("Claude CLI not found");
    if (which("npm")) {
      if (tryInstall("Claude CLI", cfg.claudeBin, ["npm", "install", "-g", "@anthropic-ai/claude-code"])) {
        cfg.claudePath = which(cfg.claudeBin) ?? "";
      }
    }
    if (!cfg.claudePath) {
      process.stdout.write("  Install it: npm install -g @anthropic-ai/claude-code\n");
      process.exit(1);
    }
  }
  stepOk("Claude CLI");

  // 5. claude auth
  if (!checkClaudeAuth()) {
    stepFail("Claude CLI not authenticated");
    process.stdout.write("  Run: claude login\n");
    process.exit(1);
  }
  stepOk("Claude authenticated");

  // 6. git repo + GitHub remote
  if (!fs.existsSync(cfg.repoPath) || !run("git", ["-C", cfg.repoPath, "rev-parse", "--is-inside-work-tree"]).ok) {
    stepFail(`Not a git repository: ${cfg.repoPath}`);
    process.stdout.write("  Run autosde from inside a git repository, or pass --repo PATH\n");
    process.exit(1);
  }
  stepOk("git repository");

  if (!cfg.githubRepo) {
    const detected = parseGithubRemote(cfg.repoPath);
    if (detected && confirm(`  Detected remote: ${detected}. Use this? [Y/n]`)) {
      cfg.githubRepo = detected;
    } else {
      cfg.githubRepo = promptInput("  Enter GitHub repo (owner/repo):");
    }
    if (!cfg.githubRepo) {
      stepFail("No GitHub repository specified");
      process.exit(1);
    }
  }
  stepOk(`repo: ${cfg.githubRepo}`);

  // 7. verify command
  if (cfg.verifyCommand) {
    cfg.resolvedVerify = cfg.verifyCommand;
    cfg.verifySource = "configured";
  } else {
    const detected = detectVerifyCommand(cfg.repoPath);
    if (detected && confirm(`  Detected: ${detected}. Use this? [Y/n]`)) {
      cfg.resolvedVerify = detected;
      cfg.verifySource = "auto-detected";
    } else {
      cfg.resolvedVerify = promptInput("  Enter verify command:");
      cfg.verifySource = "configured";
    }
    if (!cfg.resolvedVerify) {
      stepFail("No verify command specified");
      process.exit(1);
    }
  }
  stepOk(`verify: ${cfg.resolvedVerify}`);

  // 8. AGENT.md
  if (!fs.existsSync(cfg.targetAgentFile)) {
    generateAgentFile(cfg);
    if (!confirm(`  Generated AGENT.md at ${cfg.targetAgentFile}. Continue? [Y/n]`)) {
      process.stdout.write("  Edit AGENT.md and re-run autosde.\n");
      process.exit(0);
    }
  }
  stepOk("AGENT.md");

  ensureRuntime(cfg);
  process.stdout.write("\n");
  printSummary(cfg);
}

// ---------------------------------------------------------------------------
// Headless preflight
// ---------------------------------------------------------------------------

function preflight(cfg: Config): void {
  if (!cfg.githubRepo) die("--github OWNER/REPO is required");
  if (!fs.existsSync(cfg.repoPath)) die(`--repo path does not exist: ${cfg.repoPath}`);
  if (!run("git", ["-C", cfg.repoPath, "rev-parse", "--is-inside-work-tree"]).ok)
    die(`--repo must point to a git repository: ${cfg.repoPath}`);

  cfg.claudePath = which(cfg.claudeBin) ?? "";
  if (!cfg.claudePath) die(`Claude CLI not found at '${cfg.claudeBin}'. Install from ${CLAUDE_SETUP_URL}`);

  cfg.ghPath = which(cfg.ghBin) ?? "";
  if (!cfg.ghPath) die(`GitHub CLI not found at '${cfg.ghBin}'. Install from ${GH_SETUP_URL}`);
  if (!gh(cfg.ghBin, "auth", "status").ok) die("GitHub CLI is not logged in. Run 'gh auth login'.");
  cfg.ghLogin = ghAuthLogin(cfg);
  if (!cfg.ghLogin) die("Could not determine the logged-in GitHub user.");

  if (cfg.verifyCommand) {
    cfg.resolvedVerify = cfg.verifyCommand;
    cfg.verifySource = "configured";
  } else {
    const detected = detectVerifyCommand(cfg.repoPath);
    if (!detected) die('Could not auto-detect a verification command. Pass --verify "COMMAND".');
    cfg.resolvedVerify = detected;
    cfg.verifySource = "auto-detected";
  }

  if (!fs.existsSync(cfg.targetAgentFile)) generateAgentFile(cfg);

  ensureRuntime(cfg);
  printSummary(cfg);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function main(): void {
  const args = parseCliArgs();

  if (args.help) {
    printHelp();
    process.exit(0);
  }
  if (args.version) {
    process.stdout.write(`autosde ${VERSION}\n`);
    process.exit(0);
  }

  const cfg = buildConfig(args);

  if (process.stdin.isTTY && cfg.cliGithub === null) {
    interactiveOnboarding(cfg);
  } else {
    preflight(cfg);
  }

  runLoop(cfg);
}

main();
