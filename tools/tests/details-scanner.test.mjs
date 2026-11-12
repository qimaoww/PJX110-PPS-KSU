import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {parseKV} from '../../webroot/telemetry.js';
const script=fileURLToPath(new URL('../../bin/details.sh',import.meta.url)).replaceAll('\\','/');
const posix=p=>process.platform==='win32'?'/'+p[0].toLowerCase()+p.slice(2).replaceAll('\\','/'):p;
function fixture(files,run,{slow=false}={}) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pps-node-scan-'));
  try {
    for(const [name,value] of Object.entries(files)) {
      const f=path.join(dir,'class/power_supply/usb',name);
      fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,value);
    }
    const env={...process.env,PPS_SYSFS_ROOT:posix(dir)};
    let args=[script];
    if(slow) {
      const bin=path.join(dir,'mock-bin');fs.mkdirSync(bin);
      fs.writeFileSync(path.join(bin,'head'), '#!/bin/sh\ncase "$3" in *pps_slow) sleep 30 ;; *) exec /usr/bin/head "$@" ;; esac\n',{mode:0o755});
      args=['-c','PATH="$1:$PATH"; export PATH; exec sh "$2"','fixture',posix(bin),script];
    }
    const start=Date.now();
    const result=spawnSync('bash',args,{env,encoding:'utf8',timeout:20000});
    assert.ifError(result.error);assert.equal(result.status,0,result.stderr);
    run(parseKV(result.stdout),result,Date.now()-start);
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
}
test('node scan limits output, filters unrelated files and preserves literal values',()=>{
  fixture({usb_type:'PD\nPPS=1\n',voltage_max:'9'.repeat(900),unrelated:'never show'},data=>{
    assert.equal(data.scan_complete,'1');assert.equal(data.scan_count,'2');
    assert.match(data.detail_0,/usb_type \| PD PPS=1/);
    assert.match(data.detail_1,/voltage_max \| 9{384}$/);
    assert.equal(data.detail_0.includes('never show'),false);
  });
  fixture(Object.fromEntries(Array.from({length:40},(_,i)=>[`pps_${String(i).padStart(2,'0')}`,'0\n'])),data=>{
    assert.equal(data.scan_count,'32');assert.equal(data.scan_limited,'1');
    assert.equal(data.scan_complete,'1');assert.equal(data.detail_32,undefined);
  });
});
test('a hung diagnostic node is skipped within its own deadline',()=>{
  fixture({pps_slow:'blocked',pps_ok:'PD PPS\n'},(data,_result,elapsed)=>{
    assert.equal(data.scan_complete,'1');assert.equal(data.scan_skipped,'1');
    assert.equal(data.scan_count,'1');assert.match(data.detail_0,/pps_ok \| PD PPS/);
    assert.ok(elapsed<4000,`scan stalled for ${elapsed}ms`);
  },{slow:true});
});
