import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const script=fileURLToPath(new URL('../../bin/web_read.sh',import.meta.url));
test('bounded WebUI reader rejects mutations, arbitrary targets and extra arguments',()=>{
  for(const args of [[],['toggle.sh','pps55'],['../common.sh'],['/etc/passwd'],
    ['ufcs_control.sh','set','1','1'],['status.sh','extra'],['ufcs_control.sh','boot']]) {
    const result=spawnSync('bash',[script,...args],{encoding:'utf8'});
    assert.equal(result.status,2,JSON.stringify(args)+result.stderr);
  }
});
test('native read deadline stops hung work and reader propagates successful output',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pps-web-read-'));
  try {
    const reader=path.join(dir,'web_read.sh');
    fs.copyFileSync(script,reader);
    fs.writeFileSync(path.join(dir,'status.sh'),'#!/bin/sh\nsleep 30\necho stale\n');
    const start=Date.now();
    const hung=spawnSync('bash',[reader.replaceAll('\\','/'),'status.sh'],{encoding:'utf8',timeout:8000});
    assert.ifError(hung.error);
    assert.notEqual(hung.status,0);
    assert.ok(Date.now()-start<7000);
    assert.equal(hung.stdout.includes('stale'),false);
    fs.writeFileSync(path.join(dir,'status.sh'),'#!/bin/sh\necho schema=2\n');
    const ok=spawnSync('bash',[reader.replaceAll('\\','/'),'status.sh'],{encoding:'utf8'});
    assert.equal(ok.status,0,ok.stderr);assert.equal(ok.stdout.trim(),'schema=2');
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});
