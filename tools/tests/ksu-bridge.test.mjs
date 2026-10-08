import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const source = fs.readFileSync(new URL('../../webroot/ksu.js',import.meta.url),'utf8');

async function mock(fn) {
  const saved={window:globalThis.window,ksu:globalThis.ksu,setTimeout:globalThis.setTimeout,clearTimeout:globalThis.clearTimeout};
  const timers=new Map(); let id=0, call;
  globalThis.window={}; globalThis.ksu={exec:(command,options,callback)=>{call={command,options,callback};}};
  globalThis.setTimeout=(cb,ms)=>{timers.set(++id,{cb,ms});return id;};
  globalThis.clearTimeout=key=>timers.delete(key);
  try {
    const bridge=await import('data:text/javascript;base64,'+Buffer.from(source+`\n// ${Math.random()}`).toString('base64'));
    await fn(bridge,()=>call,timers);
  } finally { for(const [key,value] of Object.entries(saved)) {if(value===undefined) delete globalThis[key];else globalThis[key]=value;} }
}
test('read timeout rejects and delayed completion cannot re-resolve the request', () => mock(async(b,call,timers)=>{
  const promise=b.execRead('read',5); const error=assert.rejects(promise,/超时/);
  assert.equal(timers.size,1); [...timers.values()][0].cb(); await error;
  globalThis.window[call().callback](0,'late','');
  assert.equal(globalThis.window[call().callback],undefined);
}));
test('write execution never gets a read timeout', () => mock(async(b,call,timers)=>{
  const promise=b.exec('write'); assert.equal(timers.size,0);
  globalThis.window[call().callback]('0','done','');
  assert.deepEqual(await promise,{errno:0,stdout:'done',stderr:''});
}));
test('malformed native status cannot be mistaken for success', () => mock(async(b,call)=>{
  const promise=b.execRead('read');globalThis.window[call().callback](null,'','');
  assert.equal(Number.isNaN((await promise).errno),true);
}));
