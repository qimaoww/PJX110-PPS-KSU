// Optional headless UI regression; uses a mocked KSU bridge, never a device.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve, sep, extname} from 'node:path';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
const {chromium} = require(process.env.PPS_NODE_MODULES
  ? resolve(process.env.PPS_NODE_MODULES, 'playwright') : 'playwright');
const root = resolve('webroot');
const server = createServer(async (req, res) => {
  const file = resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
  if (!file.startsWith(root + sep)) { res.writeHead(403).end(); return; }
  try {
    res.setHeader('Content-Type', {'.js':'text/javascript','.html':'text/html','.css':'text/css'}[extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.writeHead(404).end(); }
});
await new Promise(done => server.listen(0, '127.0.0.1', done));
let browser;
try {
  browser = await chromium.launch({headless:true});
  for (const width of [360, 1280]) {
    const page = await browser.newPage({viewport:{width,height:900}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => {
      window.__commands = [];
      window.__deferRead = '';
      window.__deferred = [];
      window.__ufcs = {schema:'1',state:'ok',active:'0',value:'0',effective_disabled:'0',
        configured_disable:'0',boot_apply:'0',config_valid:'1',can_set:'1'};
      window.__state = {state:'stock',management_mode:'full_static',sha256:'a'.repeat(64),slot:'A',slot_suffix:'_a',
        trusted_slot_available:'1',trusted_slot_conflict:'0',slot_source:'bootconfig',prop_slot_conflict:'0',
        patch_driver_compatible:'1',patch_runtime_assets_compatible:'1',dynamic_assets_complete:'1',
        static_assets_complete:'0',static_stock_available:'0',ota_patch_available:'1',patch_can_enable:'1',
        patch_can_promote:'0',patch_can_recheck:'0',system_firmware:'PJX110_16.0.5.1001',dtbo_family:'PJX110_16.0.5.1001',
        rescue_ready:'0',rescue_last_written_slot:'none'};
      const kv = value => Object.entries(value).map(([k,v]) => `${k}=${v}`).join('\n');
      window.ksu = {
        toast() {},
        exec(command, _options, callback) {
          window.__commands.push(command);
          let output = '', errno = 0;
          if (command.includes('ufcs_control.sh')) {
            const setting=command.match(/ set ([01]) ([01])$/);
            if(setting) Object.assign(window.__ufcs,{active:setting[1],value:setting[1]==='1'?'1':window.__ufcs.value,
              effective_disabled:setting[1],configured_disable:setting[1],boot_apply:setting[2],result:'applied'});
            output=kv(window.__ufcs);
          }
          else if (command.includes('details.sh')) {
            output=kv(window.__scanResult || {detail_0:'/sys/class/power_supply/usb/usb_type | PD',scan_complete:'1'});
            errno=window.__scanError || 0;
          }
          else if (command.includes('dtbo_state.sh')) output = kv(window.__state);
          else if (command.includes('boot_state.sh')) output = kv({boot_state:'已解锁',system_firmware:'PJX110_16.0.5.1001'});
          else if (command.includes('status.sh')) output = kv({schema:'2',state:'ok',status:'Charging',capacity:String(window.__capacity ?? 63),capacity_unit:'percent',
            vbat_raw:'4200000',vbat_raw_unit:'uV',ibat_raw:'-2000000',ibat_raw_unit:'uA',temp_raw:'320',temp_raw_unit:'deciC',usb_online:'1'});
          else if (command.includes('patch_mode.sh') && command.endsWith('enable')) {
            Object.assign(window.__state,{management_mode:'patch',ota_patch_available:'0',patch_can_enable:'0',patch_can_promote:'1',patch_can_recheck:'1',rescue_ready:'1'});
            output = 'state=enabled\nprofile=stock';
          } else if (command.includes('promote_full.sh')) {
            Object.assign(window.__state,{management_mode:'full_dynamic',patch_can_promote:'0',patch_can_recheck:'0'});
            output = 'Full Mode completed';
          }
          if (window.__deferRead && command.includes('web_read.sh') && command.includes(window.__deferRead)) {
            window.__deferred.push(() => window[callback](errno, output, ''));
          } else queueMicrotask(() => window[callback](errno, output, ''));
        }
      };
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await page.waitForFunction(() => !document.querySelector('#patchModeBtn').disabled);
    assert.match(await page.locator('#modeHint').innerText(), /重装模块.*补丁模式/);
    assert.equal(await page.locator('#pps33Btn').isDisabled(), true);
    assert.equal(await page.locator('#pps55Btn').isDisabled(), true);
    await page.waitForFunction(()=>!document.querySelector('#ufcsDisable').disabled);
    assert.equal(await page.locator('#ufcsBoot').isDisabled(),true);
    await page.locator('#ufcsDisable').check();
    await page.waitForFunction(()=>document.querySelector('#ufcsStatus').textContent==='已关闭' && !document.querySelector('#ufcsBoot').disabled);
    await page.locator('#ufcsBoot').check();
    await page.waitForFunction(()=>document.querySelector('#ufcsBoot').checked && !document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#ufcsDisable').isChecked(),true);
    await page.locator('.ufcs-card').scrollIntoViewIfNeeded();
    await page.screenshot({path:`investigation/webui-qa/ufcs-v1.2.1-enabled-${width}.png`,fullPage:true});
    // A separate tool may release the vote; a real status read must reflect it.
    await page.evaluate(()=>Object.assign(window.__ufcs,{active:'0',effective_disabled:'0'}));
    await page.locator('#refreshBtn').click();
    await page.waitForFunction(()=>!document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#ufcsDisable').isChecked(),false);
    assert.equal(await page.locator('#ufcsBoot').isChecked(),true);
    await page.locator('#ufcsBoot').uncheck();
    await page.waitForFunction(()=>!document.querySelector('#refreshBtn').disabled && !document.querySelector('#ufcsBoot').checked);
    assert.deepEqual(await page.evaluate(()=>window.__commands.filter(c=>c.includes('ufcs_control.sh')&&c.includes(' set '))),[
      "sh '/data/adb/modules/PJX110_PPS_KSU/bin/ufcs_control.sh' set 1 0",
      "sh '/data/adb/modules/PJX110_PPS_KSU/bin/ufcs_control.sh' set 1 1",
      "sh '/data/adb/modules/PJX110_PPS_KSU/bin/ufcs_control.sh' set 0 0"]);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.locator('#patchModeBtn').click();
    assert.match(await page.locator('#confirmText').innerText(), /OTA.*不写入分区/);
    await page.locator('#cancelBtn').click();
    assert.equal(await page.evaluate(() => window.__commands.some(c => c.includes('patch_mode.sh'))), false);
    await page.locator('#patchModeBtn').click();
    await page.locator('#confirmBtn').click();
    await page.waitForFunction(() => document.querySelector('#patchModeBtn').getAttribute('aria-pressed') === 'true');
    assert.equal(await page.locator('#pps33Btn').isDisabled(), false);
    // A normal refresh leaves already verified DTBO controls available and
    // does not silently start another heavy integrity check.
    await page.evaluate(()=>{window.__deferRead='status.sh';});
    await page.locator('#refreshBtn').click();
    await page.waitForFunction(()=>window.__deferred.length===1);
    assert.equal(await page.locator('#pps33Btn').isDisabled(),false);
    await page.locator('#pps33Btn').click();
    assert.equal(await page.locator('#confirmDialog').evaluate(node=>node.open),true);
    const confirmation=await page.locator('#confirmText').innerText();
    await page.evaluate(()=>{
      window.__deferRead='';window.__deferred.splice(0).forEach(done=>done());
    });
    await page.waitForFunction(()=>!document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#confirmDialog').evaluate(node=>node.open),true);
    assert.equal(await page.locator('#confirmText').innerText(),confirmation);
    assert.notEqual(await page.locator('body').getAttribute('aria-busy'),'true');
    await page.locator('#cancelBtn').click();
    assert.equal(await page.locator('#fullModeBtn').isDisabled(), false);
    assert.deepEqual(await page.evaluate(() => window.__commands.filter(c => /patch_mode|toggle/.test(c))), ["sh '/data/adb/modules/PJX110_PPS_KSU/bin/patch_mode.sh' enable"]);
    await page.locator('#fullModeBtn').click();
    await page.locator('#confirmBtn').click();
    await page.waitForFunction(() => document.querySelector('#fullModeBtn').getAttribute('aria-pressed') === 'true');
    assert.equal(await page.locator('#patchModeBtn').isDisabled(), true);
    assert.equal(await page.locator('#pps33Btn').isDisabled(), false);
    for (const patch of [
      {management_mode:'full_static',patch_can_enable:'0',ota_patch_available:'0'},
      {management_mode:'full_static',patch_can_enable:'1',ota_patch_available:'1',patch_driver_compatible:'0'},
      {management_mode:'full_static',patch_driver_compatible:'1',trusted_slot_conflict:'1'}
    ]) {
      await page.evaluate(patch => Object.assign(window.__state,patch), patch);
      await page.locator('#diagnostics').evaluate(node=>{node.open=true;});
      await page.locator('#verifyBtn').click();
      await page.waitForFunction(() => !document.querySelector('#verifyBtn').disabled);
      assert.equal(await page.locator('#patchModeBtn').isDisabled(), true);
      assert.equal(await page.locator('#pps33Btn').isDisabled(), true);
    }
    // A slow complete DTBO check must not hold the fast refresh button.
    await page.evaluate(() => { window.__deferRead='dtbo_state.sh'; });
    await page.locator('#verifyBtn').click();
    await page.waitForFunction(() => window.__deferred.length === 1 && !document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#pps33Btn').isDisabled(),true);
    assert.equal(await page.locator('#ufcsDisable').isDisabled(),false);
    await page.evaluate(() => {
      window.__deferRead=''; window.__deferred.splice(0).forEach(done=>done());
    });
    // Periodic UFCS reads do not disable switches. A late pre-write result
    // must never replace the actual state returned by the user's write.
    await page.evaluate(() => { window.__deferRead='ufcs_control.sh'; });
    await page.locator('#refreshBtn').click();
    await page.waitForFunction(() => window.__deferred.length === 1);
    assert.equal(await page.locator('#ufcsDisable').isDisabled(),false);
    await page.locator('#ufcsDisable').check();
    await page.waitForFunction(() => document.querySelector('#ufcsStatus').textContent==='已关闭');
    await page.evaluate(() => {
      window.__deferRead=''; window.__deferred.splice(0).forEach(done=>done());
    });
    await page.waitForFunction(() => !document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#ufcsDisable').isChecked(),true);
    // A lost read callback times out, unlocks refresh, and the next refresh
    // recovers. Shorten only the bridge read deadline in this fault fixture.
    await page.evaluate(() => {
      const original=window.setTimeout.bind(window);
      window.__restoreTimeout=()=>{window.setTimeout=original;};
      window.setTimeout=(fn,ms,...args)=>original(fn,ms===8000?150:ms,...args);
      window.__deferRead='status.sh';
    });
    await page.locator('#refreshBtn').click();
    const previousCapacity=await page.locator('#capacity').innerText();
    await page.waitForFunction(() => document.querySelector('#lastRefresh').textContent.startsWith('读取超时')
      && !document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#capacity').innerText(),previousCapacity);
    assert.match(await page.locator('#lastRefresh').innerText(),/上次读数/);
    await page.evaluate(() => {
      window.__deferRead=''; window.__restoreTimeout();
      window.__deferred.splice(0).forEach(done=>done());
    });
    await page.locator('#refreshBtn').click();
    await page.waitForFunction(() => document.querySelector('#chargeStatus').textContent!=='读取超时'
      && !document.querySelector('#refreshBtn').disabled);
    const checks=await page.evaluate(()=>window.__commands.filter(c=>/dtbo_state|boot_state/.test(c)).length);
    await page.locator('#refreshBtn').click();
    await page.waitForFunction(()=>!document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.evaluate(()=>window.__commands.filter(c=>/dtbo_state|boot_state/.test(c)).length),checks);
    // Scan has visible feedback, suppresses duplicate scans, and preserves
    // useful partial output if the native overall deadline expires.
    await page.evaluate(()=>{
      window.__deferRead='details.sh';
      window.__scanResult={detail_0:'/sys/class/power_supply/usb/usb_type | PD'};
      window.__scanError=137;
      window.__controlMutations=0;
      window.__controlObserver=new MutationObserver(records=>{window.__controlMutations+=records.length;});
      window.__controlObserver.observe(document.querySelector('.control'),{subtree:true,attributes:true,childList:true,characterData:true});
    });
    await page.locator('#scanBtn').click();
    await page.waitForFunction(()=>window.__deferred.length===1);
    assert.equal(await page.locator('#scanBtn').innerText(),'扫描中…');
    assert.equal(await page.locator('#scanBtn').isDisabled(),true);
    assert.equal(await page.evaluate(()=>window.__controlMutations),0);
    assert.equal(await page.locator('#logBtn').isDisabled(),false);
    assert.equal(await page.locator('#verifyBtn').isDisabled(),false);
    assert.equal(await page.locator('#refreshBtn').isDisabled(),false);
    const ufcsBeforeScan=await page.locator('#ufcsStatus').innerText();
    const dtboBeforeScan=await page.locator('#dtboLabel').innerText();
    await page.evaluate(()=>{window.__capacity=64;});
    await page.locator('#refreshBtn').click();
    await page.waitForFunction(()=>document.querySelector('#capacity').textContent==='64'
      && !document.querySelector('#refreshBtn').disabled);
    assert.equal(await page.locator('#scanBtn').isDisabled(),true);
    assert.equal(await page.locator('#ufcsStatus').innerText(),ufcsBeforeScan);
    assert.equal(await page.locator('#dtboLabel').innerText(),dtboBeforeScan);
    // Returning to the page refreshes live status even while a scan is pending.
    await page.evaluate(()=>{
      window.__capacity=65;document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction(()=>document.querySelector('#capacity').textContent==='65');
    await page.evaluate(()=>{window.__capacity=66;});
    await page.waitForFunction(()=>document.querySelector('#capacity').textContent==='66',null,{timeout:7000});
    assert.equal(await page.locator('#scanBtn').isDisabled(),true);
    await page.evaluate(()=>{
      window.__deferRead=''; window.__deferred.splice(0).forEach(done=>done());
    });
    await page.waitForFunction(()=>!document.querySelector('#scanBtn').disabled);
    assert.match(await page.locator('#nodeOutput').innerText(),/usb_type.*PD/);
    assert.match(await page.locator('#nodeOutput').innerText(),/保留读取结果/);
    await page.locator('#diagnostics').scrollIntoViewIfNeeded();
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.screenshot({path:`investigation/webui-qa/refresh-scan-v1.2.1-${width}.png`,fullPage:true});
    await page.evaluate(()=>{window.__scanResult={scan_complete:'1'};window.__scanError=0;});
    await page.locator('#scanBtn').click();
    await page.waitForFunction(()=>!document.querySelector('#scanBtn').disabled);
    assert.equal(await page.locator('#nodeOutput').innerText(),'未找到可读节点');
    const pageState=await page.evaluate(()=>{
      document.querySelector('#diagnostics').open=true;
      document.querySelector('#verifyBtn').focus({preventScroll:true});
      window.scrollTo(0,Math.min(850,document.documentElement.scrollHeight-innerHeight));
      window.__powerTextNode=document.querySelector('#pbat').firstChild;
      return {scroll:scrollY,open:document.querySelector('#diagnostics').open,
        focus:document.activeElement.id,mode:document.querySelector('#managementMode').textContent,
        output:document.querySelector('#nodeOutput').textContent};
    });
    await page.evaluate(()=>document.querySelector('#refreshBtn').click());
    await page.waitForFunction(()=>!document.querySelector('#refreshBtn').disabled);
    assert.deepEqual(await page.evaluate(()=>({scroll:scrollY,open:document.querySelector('#diagnostics').open,
      focus:document.activeElement.id,mode:document.querySelector('#managementMode').textContent,
      output:document.querySelector('#nodeOutput').textContent})),pageState);
    assert.equal(await page.evaluate(()=>window.__powerTextNode===document.querySelector('#pbat').firstChild),true);
    assert.equal(await page.evaluate(()=>window.__controlMutations),0);
    assert.deepEqual(errors, []);
    await page.locator('.ufcs-card').scrollIntoViewIfNeeded();
    await page.screenshot({path:`investigation/webui-qa/ufcs-v1.2.1-${width}.png`,fullPage:true});
    console.log(`PASS WebUI ${width}px: OTA offer, manual confirmation, no mixed commands, Full lock and failure gates`);
    await page.close();
  }
} finally {
  if (browser) await browser.close();
  await new Promise(done => server.close(done));
}
