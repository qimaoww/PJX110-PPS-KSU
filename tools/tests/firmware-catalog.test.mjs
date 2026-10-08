import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
const catalog=JSON.parse(fs.readFileSync(path.join(root,'FIRMWARES.json'),'utf8'));
test('19 firmware triplets have unique hashes, intact AVB and correct file identities',()=>{
  assert.equal(catalog.length,19);
  const hashes=new Set(),versions=new Set(),families=new Set();
  for(const rom of catalog){
    assert.match(rom.family,/^\d+(?:_\d+)?$/);assert.match(rom.firmware,/^PJX110_(15|16)\.\d+\.\d+\.\d+$/);
    assert.equal(versions.has(rom.firmware),false);versions.add(rom.firmware);
    assert.equal(families.has(rom.family),false);families.add(rom.family);
    assert.equal(path.isAbsolute(rom.source_zip),false);assert.equal(rom.source_zip.includes('..'),false);
    for(const profile of ['stock','pps33','pps55']){
      const bytes=fs.readFileSync(path.join(root,`images/dtbo_${rom.family}_${profile}.img`));
      const hash=crypto.createHash('sha256').update(bytes).digest('hex');
      assert.equal(hash,rom[`${profile}_sha`]);assert.equal(hashes.has(hash),false);hashes.add(hash);
      assert.equal(bytes.toString('ascii',bytes.length-64,bytes.length-60),'AVBf');
      assert.equal(bytes.length,25165824);
    }
    assert.equal(rom.hardware_tested,rom.family==='400');
  }
  assert.equal(hashes.size,57);
  assert.equal(catalog.find(r=>r.family==='15_500').firmware,'PJX110_15.0.0.500');
  assert.equal(catalog.find(r=>r.family==='16_500').firmware,'PJX110_16.0.3.500');
  assert.equal(catalog.find(r=>r.family==='15_701').firmware,'PJX110_15.0.0.701');
  assert.equal(catalog.find(r=>r.family==='701').firmware,'PJX110_16.0.5.701');
});
test('all backend whitelist lookups agree with the firmware catalog',()=>{
  let code='PPS_STATE_READ_ONLY=1\nMODDIR="$(pwd)"\n. ./common.sh\n';
  for(const rom of catalog){
    code+=`[ "$(dtbo_family_label '${rom.family}')" = '${rom.firmware}' ] || exit 2\n`;
    for(const profile of ['stock','pps33','pps55']){
      const hash=rom[`${profile}_sha`];
      code+=`[ "$(dtbo_family_for_hash '${hash}')" = '${rom.family}' ] || exit 3\n`;
      code+=`[ "$(detect_profile_for_hash '${hash}')" = '${profile}' ] || exit 4\n`;
      code+=`[ "$(profile_sha_for_family '${rom.family}' '${profile}')" = '${hash}' ] || exit 5\n`;
      code+=`[ "$(profile_image_for_family '${rom.family}' '${profile}')" = "$MODDIR/images/dtbo_${rom.family}_${profile}.img" ] || exit 6\n`;
    }
  }
  code+='[ "$(dtbo_family_for_hash unknown)" = unknown ] || exit 7\n';
  const result=spawnSync('bash',['-s'],{cwd:root,input:code,encoding:'utf8'});
  assert.ifError(result.error);assert.equal(result.status,0,result.stdout+'\n'+result.stderr);
});
