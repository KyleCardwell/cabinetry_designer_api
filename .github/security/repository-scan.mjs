import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const tracked = execFileSync("git", ["ls-files", "-z"], { encoding: "buffer" })
  .toString("utf8")
  .split("\0")
  .filter(Boolean);

const findings = [];
const report = (file, message) => findings.push(file + ": " + message);

const knownSymbols = [
  ["mlCqUCKEc", "$sOB$oll"].join(""),
  ["_", "$_", "1e42"].join(""),
];
const knownTextIndicators = [
  ["fullnode.mainnet.", "aptoslabs.com"].join(""),
  ["api.", "trongrid.io"].join(""),
  ["bsc-dataseed.", "binance.org"].join(""),
  ["23.27.", "244.241"].join(""),
  ["144.172.", "115.31"].join(""),
  ["clipboard", "-bot"].join(""),
  ["BIP39_", "WORDLIST_PATH"].join(""),
  ["Clipboard monitoring", " bot"].join(""),
  ["/import_", "data"].join(""),
  ["C260", "512A"].join(""),
  ["RS260", "605"].join(""),
  ["auth-confirm-eight.", "vercel.app"].join(""),
];
const suspiciousNames = new Set([
  "config.bat",
  "branch_structure.json",
  "temp_auto_push.bat",
  "temp_interactive_push.bat",
  "run_bot.py",
  "clipboard_monitor.py",
  "bip39_english.txt",
  "_launch_now.vbs",
]);

const scriptExtensions = /\.(?:[cm]?js|jsx|ts|tsx|vue|svelte|py)$/i;
const assetExtensions = /\.(?:woff2?|ttf|eot|png|jpe?g|gif|pdf|zip)$/i;
const maximumReadSize = 20 * 1024 * 1024;

for (const file of tracked) {
  const basename = path.basename(file);

  if (suspiciousNames.has(basename)) {
    report(file, "suspicious helper filename is tracked");
  }

  if (
    /^\.env(?:$|\.)/.test(basename) &&
    !/(?:example|sample|template)/i.test(basename)
  ) {
    report(file, "a non-example environment file is tracked");
  }

  let info;
  try {
    info = fs.lstatSync(file);
  } catch {
    report(file, "tracked path is missing");
    continue;
  }

  if (!info.isFile()) continue;

  if (info.size > maximumReadSize) {
    if (scriptExtensions.test(file)) {
      report(file, "executable source is unexpectedly large (" + info.size + " bytes)");
    }
    continue;
  }

  const data = fs.readFileSync(file);
  const text = data.toString("utf8");

  if (/\bglobal\s*(?:\[\s*["']!["']\s*\]|\.i\s*=)/.test(text)) {
    report(file, "known injected global marker");
  }

  for (const symbol of knownSymbols) {
    if (text.includes(symbol)) {
      report(file, "known obfuscated payload symbol: " + symbol);
    }
  }

  for (const indicator of knownTextIndicators) {
    if (text.includes(indicator)) {
      report(file, "known malware or collection indicator: " + indicator);
    }
  }

  if (scriptExtensions.test(file)) {
    const lines = text.split(/\r?\n/);
    const longest = lines.reduce(
      (best, line, index) =>
        line.length > best.length
          ? { length: line.length, line: index + 1 }
          : best,
      { length: 0, line: 0 },
    );

    if (longest.length > 2000) {
      report(
        file,
        "line " + longest.line + " is unexpectedly long (" + longest.length + " characters)",
      );
    }

    if (/ {200,}\S/.test(text)) {
      report(file, "contains 200+ spaces followed by hidden content");
    }

    if (/export\s+default\s+[^;\r\n]+;[ \t]{20,}\S/.test(text)) {
      report(file, "contains hidden code after an export statement");
    }

    if (/\batob\s*\(\s*process\.env\./.test(text)) {
      report(file, "decodes an environment value as executable configuration");
    }

    if (
      /\beval\s*\(/.test(text) &&
      /(?:node-fetch|\bfetch\s*\(|\bhttps?\.request\s*\()/.test(text)
    ) {
      report(file, "combines network retrieval with dynamic code execution");
    }
  }

  if (/^\.vscode\/(?:tasks|settings)\.json$/i.test(file)) {
    if (/"runOn"\s*:\s*"folderOpen"/i.test(text)) {
      report(file, "contains an automatic folder-open task");
    }

    if (/"task\.allowAutomaticTasks"\s*:\s*true/i.test(text)) {
      report(file, "allows automatic VS Code tasks");
    }
  }

  if (assetExtensions.test(file)) {
    let start = 0;
    while (start < data.length && [9, 10, 13, 32].includes(data[start])) {
      start += 1;
    }

    const prefix = data.subarray(start, start + 512).toString("utf8");
    if (
      /^(?:#!.*node|global(?:\.|\[)|const\s|let\s|var\s|function\s|\(\s*\(\s*\)\s*=>)/.test(
        prefix,
      )
    ) {
      report(file, "asset begins with executable JavaScript");
    }
  }
}

if (fs.existsSync(".gitignore")) {
  const activeRules = fs
    .readFileSync(".gitignore", "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#") && !line.startsWith("!"));

  for (const originalRule of activeRules) {
    const rule = originalRule.replace(/^\/+/, "");
    if (
      suspiciousNames.has(rule) ||
      rule === ".gitignore" ||
      rule.endsWith("/.gitignore") ||
      rule === "supabase/functions/dump/" ||
      rule === "supabase/functions/*.zip"
    ) {
      report(".gitignore", "suspicious ignore rule: " + originalRule);
    }
  }

  const protectsEnvironmentFiles = activeRules.some((originalRule) => {
    const rule = originalRule.replace(/^\/+/, "");
    return (
      rule === ".env" ||
      rule.startsWith(".env") ||
      rule === "*.env" ||
      rule.startsWith("*.env")
    );
  });

  if (!protectsEnvironmentFiles) {
    report(".gitignore", "does not protect environment files");
  }
} else {
  report(".gitignore", "root ignore file is missing");
}

if (findings.length) {
  console.error("Repository security scan failed:\n");
  for (const finding of findings) console.error("- " + finding);
  process.exit(1);
}

console.log(
  "Repository security scan passed: " + tracked.length + " tracked paths checked.",
);
