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
          let output = '';
          if (command.includes('dtbo_state.sh')) output = kv(window.__state);
          else if (command.includes('boot_state.sh')) output = kv({boot_state:'已解锁',system_firmware:'PJX110_16.0.5.1001'});
          else if (command.includes('status.sh')) output = kv({schema:'2',state:'ok',status:'Charging',capacity:'63',capacity_unit:'percent',
            vbat_raw:'4200000',vbat_raw_unit:'uV',ibat_raw:'-2000000',ibat_raw_unit:'uA',temp_raw:'320',temp_raw_unit:'deciC',usb_online:'1'});
          else if (command.includes('patch_mode.sh') && command.endsWith('enable')) {
            Object.assign(window.__state,{management_mode:'patch',ota_patch_available:'0',patch_can_enable:'0',patch_can_promote:'1',patch_can_recheck:'1',rescue_ready:'1'});
            output = 'state=enabled\nprofile=stock';
          } else if (command.includes('promote_full.sh')) {
            Object.assign(window.__state,{management_mode:'full_dynamic',patch_can_promote:'0',patch_can_recheck:'0'});
            output = 'Full Mode completed';
          }
          queueMicrotask(() => window[callback](0, output, ''));
        }
      };
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await page.waitForFunction(() => !document.querySelector('#patchModeBtn').disabled);
    assert.match(await page.locator('#modeHint').innerText(), /重装模块.*补丁模式/);
    assert.equal(await page.locator('#pps33Btn').isDisabled(), true);
    assert.equal(await page.locator('#pps55Btn').isDisabled(), true);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.locator('#patchModeBtn').click();
    assert.match(await page.locator('#confirmText').innerText(), /OTA.*不写入分区/);
    await page.locator('#cancelBtn').click();
    assert.equal(await page.evaluate(() => window.__commands.some(c => c.includes('patch_mode.sh'))), false);
    await page.locator('#patchModeBtn').click();
    await page.locator('#confirmBtn').click();
    await page.waitForFunction(() => document.querySelector('#patchModeBtn').getAttribute('aria-pressed') === 'true');
    assert.equal(await page.locator('#pps33Btn').isDisabled(), false);
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
      await page.locator('#refreshBtn').click();
      await page.waitForFunction(() => !document.querySelector('#refreshBtn').disabled);
      assert.equal(await page.locator('#patchModeBtn').isDisabled(), true);
      assert.equal(await page.locator('#pps33Btn').isDisabled(), true);
    }
    assert.deepEqual(errors, []);
    console.log(`PASS WebUI ${width}px: OTA offer, manual confirmation, no mixed commands, Full lock and failure gates`);
    await page.close();
  }
} finally {
  if (browser) await browser.close();
  await new Promise(done => server.close(done));
}
