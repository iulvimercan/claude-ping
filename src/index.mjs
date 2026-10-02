import { execFile } from "node:child_process";
import { createReadStream, createWriteStream, existsSync } from "node:fs";
import { chmod, mkdir, readdir, rename, writeFile } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { createZstdDecompress, constants as zlib } from "node:zlib";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

const run = promisify(execFile);
const ssm = new SSMClient({});

// The CLI layers ship the zstd-compressed binary split into parts (see scripts/build.sh)
const CLI_PARTS_DIR = process.env.CLI_PARTS_DIR ?? "/opt/claude-cli";
const CLI_PATH = "/tmp/claude-cli/claude";
const TOKEN_PARAM = process.env.TOKEN_PARAM ?? "/claude-ping/oauth-token";
const PING_MODEL = process.env.PING_MODEL ?? "sonnet";
const PING_PROMPT = process.env.PING_PROMPT ?? "hi";

const log = (fields) => console.log(JSON.stringify({ event: "ping", ...fields }));

// Decompress once per execution environment; warm invocations reuse /tmp
async function ensureCli() {
  if (existsSync(CLI_PATH)) return;

  const parts = (await readdir(CLI_PARTS_DIR)).filter((f) => f.startsWith("claude.zst.part")).sort();
  if (parts.length === 0) throw new Error(`No CLI parts found in ${CLI_PARTS_DIR}`);

  await mkdir("/tmp/claude-cli", { recursive: true });
  const tmpPath = `${CLI_PATH}.partial`;

  async function* concatParts() {
    for (const part of parts) yield* createReadStream(`${CLI_PARTS_DIR}/${part}`);
  }
  await pipeline(
    concatParts(),
    createZstdDecompress({ params: { [zlib.ZSTD_d_windowLogMax]: 27 } }),
    createWriteStream(tmpPath),
  );
  await chmod(tmpPath, 0o755);
  await rename(tmpPath, CLI_PATH);
}

async function prepareHome() {
  // Lambda only allows writes to /tmp
  await mkdir("/tmp/.claude", { recursive: true });
  await writeFile("/tmp/.claude.json", JSON.stringify({ hasCompletedOnboarding: true }));
}

async function readToken() {
  const { Parameter } = await ssm.send(
    new GetParameterCommand({ Name: TOKEN_PARAM, WithDecryption: true }),
  );
  if (!Parameter?.Value) throw new Error(`SSM parameter ${TOKEN_PARAM} is empty`);
  return Parameter.Value;
}

function cliEnv(token) {
  return {
    ...process.env,
    HOME: "/tmp",
    CLAUDE_CODE_OAUTH_TOKEN: token,
    DISABLE_AUTOUPDATER: "1",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  };
}

async function dryRun() {
  const token = await readToken();
  const { stdout } = await run(CLI_PATH, ["--version"], { env: cliEnv(token), timeout: 30_000 });
  const version = stdout.trim();
  log({ ok: true, dryRun: true, version });
  return { ok: true, dryRun: true, version };
}

async function ping() {
  const token = await readToken();
  const started = Date.now();
  const args = ["-p", PING_PROMPT, "--model", PING_MODEL, "--effort", "low", "--max-turns", "1", "--output-format", "json"];

  let stdout;
  try {
    ({ stdout } = await run(CLI_PATH, args, { env: cliEnv(token), timeout: 100_000 }));
  } catch (err) {
    log({ ok: false, model: PING_MODEL, durationMs: Date.now() - started, exitCode: err.code, stderr: err.stderr?.slice(0, 2000) });
    throw new Error(`claude exited with ${err.code}`);
  }

  const result = JSON.parse(stdout);
  const fields = { model: PING_MODEL, durationMs: Date.now() - started, sessionId: result.session_id };
  if (result.is_error) {
    log({ ok: false, ...fields, subtype: result.subtype, result: String(result.result).slice(0, 500) });
    // e.g. "Not logged in · Please run /login" when the OAuth token expired
    throw new Error(`claude returned an error: ${String(result.result).slice(0, 200)}`);
  }
  log({ ok: true, ...fields });
  return { ok: true, ...fields };
}

export const handler = async (event = {}) => {
  await ensureCli();
  await prepareHome();
  return event.dryRun ? dryRun() : ping();
};
