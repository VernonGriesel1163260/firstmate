import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

const [runner, ...args] = process.argv.slice(2);
// Windows: a .sh runner cannot be spawned directly by CreateProcess, and a
// bare "bash" would resolve to WSL's System32 bash; resolve Git for Windows
// bash explicitly.
let command = runner;
if (process.platform === "win32" && runner.endsWith(".sh")) {
  const candidates = [
    process.env.FM_BASH,
    "C:/Program Files/Git/usr/bin/bash.exe",
    "C:/Program Files/Git/bin/bash.exe",
    "C:/Program Files (x86)/Git/usr/bin/bash.exe",
  ].filter((p) => p && existsSync(p));
  command = candidates[0] || "bash";
  args.unshift(runner.replace(/\\/g, "/"));
}
let runnerCode;
let outputBytes = 0;
let pendingWrites = 0;
let resultSent = false;

const sendResult = () => {
  if (resultSent || runnerCode === undefined || pendingWrites !== 0) return;
  resultSent = true;
  process.send?.({ type: "result", code: runnerCode, bytes: outputBytes });
};

process.on("SIGTERM", () => {});
process.on("disconnect", () => {
  try {
    process.kill(-process.pid, "SIGKILL");
  } catch {
    process.exit(1);
  }
});

const child = spawn(command, args, {
  env: { ...process.env, FM_SESSIONSTART_SUPERVISOR_PID: String(process.pid) },
  stdio: ["ignore", "pipe", "ignore"],
});
child.stdout.on("data", (chunk) => {
  outputBytes += chunk.length;
  pendingWrites += 1;
  process.stdout.write(chunk, () => {
    pendingWrites -= 1;
    sendResult();
  });
});
child.on("error", () => {
  runnerCode = null;
  sendResult();
});
child.on("close", (code) => {
  runnerCode = code;
  sendResult();
});
