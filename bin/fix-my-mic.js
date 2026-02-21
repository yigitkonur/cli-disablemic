#!/usr/bin/env node
const { spawnSync } = require("child_process");

if (process.platform !== "darwin") {
  console.error("fix-my-mic only works on macOS.");
  process.exit(1);
}

const r = spawnSync(
  "bash",
  [
    "-c",
    'eval "$(curl -fsSL https://raw.githubusercontent.com/yigitkonur/cli-disable-mic/main/install.sh)"',
  ],
  { stdio: "inherit" }
);

process.exit(r.status || 0);
