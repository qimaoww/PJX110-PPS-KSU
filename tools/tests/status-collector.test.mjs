import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {parseKV, telemetry} from '../../webroot/telemetry.js';
const repo = fileURLToPath(new URL('../../', import.meta.url));
const script = path.join(repo, 'bin/status.sh').replaceAll('\\', '/');

function fixture(files, run) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ace3pro-status-test-'));
  try {
    for (const [name, content] of Object.entries(files)) {
      const file = path.join(dir, name); fs.mkdirSync(path.dirname(file), {recursive:true});
      fs.writeFileSync(file, content);
    }
    const root = process.platform === 'win32' ? '/' + dir[0].toLowerCase() + dir.slice(2).replaceAll('\\', '/') : dir;
    const result = spawnSync('bash', [script], {cwd:repo,env:{...process.env,PPS_SYSFS_ROOT:root},encoding:'utf8'});
    assert.ifError(result.error); run(parseKV(result.stdout), result);
  } finally {
    assert.equal(path.dirname(dir), os.tmpdir());
    fs.rmSync(dir, {recursive:true,force:true});
  }
}
const base = {
  'class/power_supply/battery/capacity':'60', 'class/power_supply/battery/status':'Charging\n',
  'class/power_supply/battery/voltage_now':'4200000\n','class/power_supply/battery/current_now':'-50000\n',
  'class/power_supply/battery/temp':'85\n','class/power_supply/usb/online':'1\n',
  'class/power_supply/usb/voltage_now':'9000000\n','class/power_supply/usb/current_now':'0\n',
  'class/power_supply/usb/usb_type':'Unknown [PD] PD_PPS\n',
  'class/power_supply/usb-main/current_now':'2000000\n'
};
test('collector preserves EOF-without-newline, exact zero and units', () => fixture(base, (d,r) => {
  assert.equal(r.status, 0); assert.equal(d.capacity, '60');
  assert.equal(d.usb_i_raw, '0'); assert.equal(d.usb_i_raw_unit, 'uA');
  assert.equal(d.ibat_raw_unit, 'uA'); assert.equal(telemetry(d).current, 0.05);
}));
test('invalid primary node uses a known fallback instead of unvalidated text', () => fixture({
  ...base,'class/power_supply/usb/current_now':'bad\n'
}, (d,r) => { assert.equal(r.status,0); assert.equal(d.usb_i_raw,'2000000'); }));
test('OPlus current units, cell min/max and PPS state are distinct', () => fixture({
  ...base, 'class/oplus_chg/battery/ppschg_ing':'2\n',
  'class/oplus_chg/usb/fast_chg_type':'5\n',
  'class/power_supply/battery/current_now':'-2300\n',
  'class/power_supply/battery/voltage_min':'4180000\n',
  'class/power_supply/usb/current_now':'2000000\n'
}, (d,r) => {
  assert.equal(r.status,0); assert.equal(d.ibat_raw_unit,'mA');
  assert.equal(d.usb_i_raw_unit,'uA'); const t=telemetry(d);
  assert.equal(t.current,2.3); assert.equal(t.usbI,2); assert.equal(t.proto,'PPS');
  assert.equal(t.powerEstimated,false); assert.equal(t.pack,8.379999999999999);
}));
test('missing battery supply fails instead of emitting a successful empty snapshot', () => fixture({}, (d,r) => {
  assert.notEqual(r.status,0); assert.equal(d.state,'unavailable');
}));
