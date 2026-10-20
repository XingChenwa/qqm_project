import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";

const bash = process.env.QQM_BASH || (process.platform === "win32"
  ? "C:/Program Files/Git/bin/bash.exe" : "bash");
const installer = await readFile(resolve("server/install.sh"), "utf8");
const validator = installer.match(/^validate_archive\(\) \{[\s\S]*?^\}/m)?.[0];
assert.ok(validator);
const name = "qqbotmanager-linux-v9.9.9-beta.1-build999-web-x64.tar.gz";

// Minimal USTAR fixtures: this also tests hostile paths/links on Windows without
// granting symlink privileges or ever extracting the malicious test archives.
function archive(entry, type = "0") {
  const header = Buffer.alloc(512);
  header.write(entry, 0, 100);
  header.write("0000644\0", 100, 8);
  header.write("0000000\0", 108, 8);
  header.write("0000000\0", 116, 8);
  const content = type === "0" ? Buffer.from("offline fixture") : Buffer.alloc(0);
  header.write(content.length.toString(8).padStart(11, "0") + "\0", 124, 12);
  header.write("00000000000\0", 136, 12);
  header.fill(32, 148, 156);
  header.write(type, 156, 1);
  if (type !== "0") header.write("../../outside-private-file", 157, 100);
  header.write("ustar\0", 257, 6);
  header.write("00", 263, 2);
  const sum = header.reduce((total, value) => total + value, 0);
  header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8);
  return gzipSync(Buffer.concat([
    header, content, Buffer.alloc((512 - content.length % 512) % 512), Buffer.alloc(1024),
  ]));
}

async function validate(content, checksum = undefined) {
  const base = resolve("build");
  await mkdir(base, { recursive: true });
  const temp = await mkdtemp(join(base, "installer-security-"));
  try {
    await mkdir(join(temp, "work"));
    await writeFile(join(temp, name), content);
    await writeFile(join(temp, name + ".sha256"), checksum ??
      `${createHash("sha256").update(content).digest("hex")}  ${name}\n`);
    const result = spawnSync(bash, ["-s", "--", name, "work"], {
      cwd: temp,
      input: `set -euo pipefail\ndie() { printf '%s\\n' "$*" >&2; exit 1; }\n${validator}\nvalidate_archive "$1" "$2"\n`,
      encoding: "utf8", windowsHide: true,
    });
    assert.ifError(result.error);
    return result;
  } finally {
    assert.ok(temp.startsWith(join(base, "installer-security-")));
    await rm(temp, { recursive: true, force: true });
  }
}

test("installer, launcher and distribution tests have valid Bash syntax", () => {
  for (const path of ["server/install.sh", "server/start.sh", "scripts/build_linux_server.sh", "scripts/test_linux_distros.sh", "scripts/test_linux_installer.sh", "tool/support/systemctl_fixture.sh", "tool/support/linux_installer_fixture.sh"]) {
    const result = spawnSync(bash, ["-n", path], { encoding: "utf8", windowsHide: true });
    assert.equal(result.status, 0, result.stderr);
  }
  const help = spawnSync(bash, ["server/install.sh", "--help"], { encoding: "utf8", windowsHide: true });
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /--print-link/);
  assert.match(help.stdout, /--channel stable\|beta/);
  assert.match(help.stdout, /glibc >= 2\.31/);
});
test("a matching official-style SHA-256 archive is accepted automatically", async () => {
  const result = await validate(archive("qqbotmanager/server/web/index.html"));
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /SHA-256 自动校验通过/);
});
test("wrong digest, checksum filename injection and extra lines fail closed", async () => {
  const content = archive("qqbotmanager/server/web/index.html");
  const digest = createHash("sha256").update(content).digest("hex");
  for (const checksum of ["0".repeat(64) + `  ${name}\n`, `${digest}  ../../private\n`,
    `${digest}  ${name}\n${digest}  other-file\n`]) {
    const result = await validate(content, checksum);
    assert.notEqual(result.status, 0);
  }
});
test("absolute paths, traversal, unexpected roots and links are never extracted", async () => {
  for (const [path, type] of [["/qqbotmanager/root-owned", "0"],
    ["qqbotmanager/../../private", "0"], ["other-root/file", "0"],
    ["qqbotmanager/link", "2"], ["qqbotmanager/hardlink", "1"]]) {
    const result = await validate(archive(path, type));
    assert.notEqual(result.status, 0, path + " " + type);
  }
});
test("installer never evaluates saved environment config or changes firewall rules", () => {
  assert.doesNotMatch(installer, /\b(?:eval|source)\s+["$]/);
  assert.doesNotMatch(installer, /\b(?:ufw|firewall-cmd|iptables)\b/);
  assert.match(installer, /--no-same-owner --no-same-permissions/);
  assert.match(installer, /trap rollback ERR/);
  assert.match(installer, /private-data\.tar\.gz/);
});
test("displayed access origins allow IPv4/IPv6 but reject paths, credentials and shell text", () => {
  const patternLine = installer.match(/^access_pattern=.*$/m)?.[0];
  assert.ok(patternLine);
  for (const [url, allowed] of [["http://192.0.2.10:23336", true],
    ["https://bots.example.com", true], ["http://[::1]:23336/", true],
    ["http://user@host", false], ["https://host/admin", false],
    ["https://host/?code=private", false], ["http://host;id", false]]) {
    const result = spawnSync(bash, ["-s", "--", url], {
      input: `${patternLine}\n[[ "$1" =~ $access_pattern ]]\n`,
      encoding: "utf8", windowsHide: true,
    });
    assert.equal(result.status === 0, allowed, url + " " + result.stderr);
  }
});
