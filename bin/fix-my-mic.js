#!/usr/bin/env node
const { spawnSync } = require("child_process");
const path = require("path");

if (process.platform !== "darwin") {
  console.error("fix-my-mic only works on macOS.");
  process.exit(1);
}

const installScript = path.join(__dirname, "..", "install.sh");

const r = spawnSync("bash", [installScript], { stdio: "inherit" });

process.exit(r.status || 0);
