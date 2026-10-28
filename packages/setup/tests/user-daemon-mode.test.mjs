import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { installDaemonService } = require('../install-daemon.js');

async function withFakeHome(fn) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sysknife-user-service-'));
  const oldEnv = Object.fromEntries(
    ['HOME', 'USERPROFILE', 'XDG_STATE_HOME'].map((name) => [name, process.env[name]]),
  );
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  process.env.XDG_STATE_HOME = path.join(home, 'state');
  try {
    return await fn(home);
  } finally {
    for (const [name, value] of Object.entries(oldEnv)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    fs.rmSync(home, { recursive: true, force: true });
  }
}

async function withQuietConsole(fn) {
  const realLog = console.log;
  console.log = () => {};
  try {
    return await fn();
  } finally {
    console.log = realLog;
  }
}

function successfulReloadThenFailedStart() {
  return (command, args) => {
    if (command === 'loginctl') return { status: 0 };
    assert.equal(command, 'systemctl');
    assert.deepEqual(args.slice(0, 1), ['--user']);
    return { status: args[1] === 'daemon-reload' ? 0 : 1 };
  };
}

test('user service start failure is returned as incomplete setup with a manual step', async () => {
  await withFakeHome(async (home) => {
    await withQuietConsole(async () => {
      const daemonBinPath = path.join(home, 'bin', 'sysknife-daemon');
      fs.mkdirSync(path.dirname(daemonBinPath), { recursive: true });
      fs.writeFileSync(daemonBinPath, '#!/bin/sh\nexit 0\n', { mode: 0o755 });

      const result = await installDaemonService({
        ask: async () => '1',
        daemonMode: 'user',
        daemonBinPath,
        hasSystemd: () => true,
        spawnSync: successfulReloadThenFailedStart(),
      });

      assert.equal(result.mode, 'user');
      assert.equal(result.daemonInstalled, false);
      assert.ok(result.manualSteps.length > 0);
      assert.ok(result.manualSteps.some((step) => step.includes('systemctl --user enable --now sysknife-daemon')));
    });
  });
});

for (const [name, makeBinary] of [
  ['missing', () => {}],
  ['not executable', (binaryPath) => {
    fs.mkdirSync(path.dirname(binaryPath), { recursive: true });
    fs.writeFileSync(binaryPath, '#!/bin/sh\nexit 0\n', { mode: 0o644 });
    fs.chmodSync(binaryPath, 0o644);
  }],
]) {
  test(`user mode refuses a ${name} daemon binary before writing a unit`, {
    skip: name === 'not executable' && process.platform === 'win32'
      ? 'Windows does not expose POSIX execute permission bits'
      : false,
  }, async () => {
    await withFakeHome(async (home) => {
      await withQuietConsole(async () => {
        const daemonBinPath = path.join(home, 'bin', 'sysknife-daemon');
        makeBinary(daemonBinPath);

        const result = await installDaemonService({
          ask: async () => '1',
          daemonMode: 'user',
          daemonBinPath,
          hasSystemd: () => true,
          spawnSync: () => {
            assert.fail('service commands must not run without an executable daemon binary');
          },
        });

        assert.equal(result.mode, 'user');
        assert.equal(result.daemonInstalled, false);
        assert.ok(result.manualSteps.some((step) => step.includes(daemonBinPath)));
        assert.equal(
          fs.existsSync(path.join(home, '.config', 'systemd', 'user', 'sysknife-daemon.service')),
          false,
        );
      });
    });
  });
}
