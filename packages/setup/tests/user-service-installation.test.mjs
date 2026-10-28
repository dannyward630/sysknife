import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const childProcess = require('node:child_process');
const installerPath = require.resolve('../install-daemon.js');

async function withInstaller({ commandStatus }, fn) {
  const originalSpawnSync = childProcess.spawnSync;
  const originalLog = console.log;
  const originalHome = process.env.HOME;
  const originalUserProfile = process.env.USERPROFILE;
  const originalRuntimeDir = process.env.XDG_RUNTIME_DIR;
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sysknife-user-service-'));
  const commands = [];
  const lines = [];
  childProcess.spawnSync = (command, args, options) => {
    commands.push({ command, args, options });
    return { status: commandStatus(command, args) };
  };
  console.log = (...parts) => lines.push(parts.join(' '));

  try {
    delete require.cache[installerPath];
    const { installDaemonService } = require(installerPath);
    process.env.HOME = home;
    process.env.USERPROFILE = home;
    process.env.XDG_RUNTIME_DIR = path.join(home, 'runtime');
    return await fn({ commands, home, installDaemonService, lines });
  } finally {
    childProcess.spawnSync = originalSpawnSync;
    console.log = originalLog;
    delete require.cache[installerPath];
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    if (originalUserProfile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = originalUserProfile;
    if (originalRuntimeDir === undefined) delete process.env.XDG_RUNTIME_DIR;
    else process.env.XDG_RUNTIME_DIR = originalRuntimeDir;
    fs.rmSync(home, { recursive: true, force: true });
  }
}

test('user mode reports success only after the service starts', async () => {
  await withInstaller({ commandStatus: () => 0 }, async ({ installDaemonService }) => {
    const result = await installDaemonService({
      ask: async () => '1',
      daemonBinPath: process.execPath,
      daemonMode: 'user',
      hasSystemd: () => true,
    });

    assert.equal(result.daemonInstalled, true);
    assert.deepEqual(result.manualSteps, []);
  });
});

test('user mode reports a failed enable/start and returns the printed manual step', async () => {
  await withInstaller({
    commandStatus: (_command, args) => args.includes('enable') ? 1 : 0,
  }, async ({ commands, installDaemonService }) => {
    const result = await installDaemonService({
      ask: async () => '1',
      daemonBinPath: process.execPath,
      daemonMode: 'user',
      hasSystemd: () => true,
    });

    assert.equal(result.daemonInstalled, false);
    assert.ok(result.manualSteps.includes('Run:  systemctl --user enable --now sysknife-daemon'));
    assert.ok(commands.some(({ command, args }) => (
      command === 'systemctl' && args.join(' ') === '--user enable --now sysknife-daemon'
    )));
  });
});

test('user mode reports a failed daemon reload and returns both manual commands', async () => {
  await withInstaller({
    commandStatus: (_command, args) => args.includes('daemon-reload') ? 1 : 0,
  }, async ({ commands, installDaemonService }) => {
    const result = await installDaemonService({
      ask: async () => '1',
      daemonBinPath: process.execPath,
      daemonMode: 'user',
      hasSystemd: () => true,
    });

    assert.equal(result.daemonInstalled, false);
    assert.ok(result.manualSteps.includes('Run:  systemctl --user daemon-reload'));
    assert.ok(result.manualSteps.includes('Run:  systemctl --user enable --now sysknife-daemon'));
    assert.equal(commands.filter(({ command }) => command === 'systemctl').length, 1);
  });
});

test('user mode refuses a missing daemon binary before writing a unit', async () => {
  await withInstaller({ commandStatus: () => 0 }, async ({ commands, home, installDaemonService, lines }) => {
    const daemonBinPath = path.join(home, 'missing', 'sysknife-daemon');
    const result = await installDaemonService({
      ask: async () => '1',
      daemonBinPath,
      daemonMode: 'user',
      hasSystemd: () => true,
    });

    const unitPath = path.join(home, '.config', 'systemd', 'user', 'sysknife-daemon.service');
    assert.equal(result.daemonInstalled, false);
    assert.ok(result.manualSteps.length > 0);
    assert.ok(lines.join('\n').includes(daemonBinPath), 'the refusal names the missing binary');
    assert.equal(fs.existsSync(unitPath), false, 'do not write a unit with a broken ExecStart');
    assert.equal(commands.length, 0, 'do not call systemd when the binary cannot run');
  });
});

test('user mode refuses a daemon binary without execute permission', { skip: process.platform === 'win32' }, async () => {
  await withInstaller({ commandStatus: () => 0 }, async ({ commands, home, installDaemonService }) => {
    const daemonBinPath = path.join(home, 'sysknife-daemon');
    fs.writeFileSync(daemonBinPath, 'not an executable');
    fs.chmodSync(daemonBinPath, 0o644);

    const result = await installDaemonService({
      ask: async () => '1',
      daemonBinPath,
      daemonMode: 'user',
      hasSystemd: () => true,
    });

    const unitPath = path.join(home, '.config', 'systemd', 'user', 'sysknife-daemon.service');
    assert.equal(result.daemonInstalled, false);
    assert.ok(result.manualSteps.length > 0);
    assert.equal(fs.existsSync(unitPath), false, 'do not write a unit with a non-executable ExecStart');
    assert.equal(commands.length, 0, 'do not call systemd when the binary cannot run');
  });
});
