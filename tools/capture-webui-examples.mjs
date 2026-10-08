// Render production WebUI with a MOCK KernelSU bridge. No ADB or device writes.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, writeFile, mkdir, stat} from 'node:fs/promises';
import {resolve, sep, extname, join} from 'node:path';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const require = createRequire(import.meta.url);
const {chromium} = require(process.env.PPS_NODE_MODULES
  ? resolve(process.env.PPS_NODE_MODULES, 'playwright') : 'playwright');
const repo = resolve('.'), web = join(repo, 'webroot');
const output = resolve(process.argv[2] || 'investigation/webui-examples');
if (!output.startsWith(join(repo, 'investigation') + sep)) throw new Error('Examples must stay in investigation');
await mkdir(join(output, 'raw'), {recursive:true});
await mkdir(join(output, 'focus'), {recursive:true});
const catalog = JSON.parse(await readFile(join(repo, 'FIRMWARES.json'), 'utf8'));
const firmware = family => catalog.find(row => row.family === family);
const current = firmware('1001'), legacy = firmware('400'), old = firmware('701');
const p33 = 'fd5c261d450643ac5f66f90628ea3021958a49314a6fa8e6d1b54557d9b8bb45';
const p55 = 'a8e3ac98f3f68df08e6856c2291167944e683d9014fa15b4bb223b054313a95a';
const state = {state:'stock',management_mode:'full_static',sha256:current.stock_sha,slot:'B',slot_suffix:'_b',
  slot_source:'bootconfig',trusted_slot_available:'1',trusted_slot_conflict:'0',prop_slot_conflict:'0',
  patch_driver_compatible:'1',patch_runtime_assets_compatible:'1',dynamic_assets_complete:'1',
  static_assets_complete:'0',static_stock_available:'0',ota_patch_available:'1',patch_can_enable:'1',
  patch_can_promote:'0',patch_can_recheck:'0',system_firmware:current.firmware,dtbo_family:current.firmware,
  rescue_ready:'0',rescue_last_written_slot:'none',stock_sha:current.stock_sha,pps33_sha:p33,pps55_sha:p55};
const patchState = {...state,management_mode:'patch',dtbo_family:`动态生成 / ${current.firmware}`,
  ota_patch_available:'0',patch_can_enable:'0',patch_can_promote:'1',patch_can_recheck:'1',rescue_ready:'1'};
const fullState = {...patchState,management_mode:'full_dynamic',patch_can_promote:'0',patch_can_recheck:'0'};
const telemetry = {schema:'2',state:'ok',timestamp:'模拟读数',status:'Charging',capacity:'63',capacity_unit:'percent',
  vbat_raw:'4180000',vbat_raw_unit:'uV',ibat_raw:'-2650',ibat_raw_unit:'mA',temp_raw:'325',temp_raw_unit:'deciC',
  cell1_raw:'4190',cell1_raw_unit:'cellV',cell2_raw:'4180',cell2_raw_unit:'cellV',
  cell2_raw_source:'/sys/class/power_supply/battery/voltage_min',usb_online:'1',ac_online:'0',
  usb_v_raw:'9000000',usb_v_raw_unit:'uV',usb_i_raw:'2800000',usb_i_raw_unit:'uA',usb_icl_raw:'3000000',usb_icl_raw_unit:'uA',
  usb_v_raw_source:'/sys/class/power_supply/usb/voltage_now',usb_i_raw_source:'/sys/class/power_supply/usb/current_now',
  usb_type_raw:'Unknown SDP DCP PD [PD_PPS]',usb_real_type:'PD_PPS',typec_mode:'Sink',pps_mode:'2',
  health:'Good',cycle_count:'127',charge_full_raw:'5970000',charge_full_raw_unit:'uAh',
  charge_full_design_raw:'6100000',charge_full_design_raw_unit:'uAh',mmi_charging_enable:'1',cool_down:'0'};
const patchPPS = {...patchState,state:'pps33',sha256:p33,patch_can_recheck:'0',rescue_last_written_slot:'B'};
const patchRepair = {...patchState,dynamic_assets_complete:'0',patch_can_promote:'0'};
const examples = [
  {id:'01-ota-patch-offer',title:'OTA 缺少新镜像集',caption:'33W / 55W 禁用；可重装模块，或手动检测后使用补丁。',data:state},
  {id:'02-reinstall-only',title:'不符合补丁条件',caption:'同版本缺失镜像或不具备 OTA 资格时，只提示重装，不开放补丁。',data:{...state,ota_patch_available:'0',patch_can_enable:'0'}},
  {id:'03-enable-confirm',title:'手动启用补丁的确认',caption:'先做驱动、DTBO、AVB、备份与救援校验；登记过程不写分区。',data:state,action:'patchModeBtn',focus:'#confirmDialog'},
  {id:'04-patch-stock',title:'启用后的补丁模式',caption:'当前仍为原厂；PPS 操作和手动切换全分区入口才会解锁。',data:patchState},
  {id:'05-unknown-dtbo',title:'未内置的 DTBO',caption:'不能直接刷全分区；只能手动检测并登记兼容的原厂 DTBO。',data:{...state,state:'unknown',management_mode:'none',ota_patch_available:'0',dtbo_family:'待检测 / '+current.firmware,sha256:'a153396e7203c95ccce1065b501fc1253751ed9c6b9666d748aa57d9ac7b6560'}},
  {id:'06-static-400',title:'内置全分区模式保持独立',caption:'以 400 为例：原厂 / 33W / 55W 可用，但不能使用补丁模式。',data:{...state,sha256:legacy.stock_sha,system_firmware:legacy.firmware,dtbo_family:legacy.firmware,
    static_assets_complete:'1',static_stock_available:'1',ota_patch_available:'0',patch_can_enable:'0'}},
  {id:'07-pps-confirm',title:'PPS 写入前确认',caption:'明确仅写当前 B 槽 DTBO、保留 AVB、回读校验；未实测固件有警告。',data:patchState,action:'pps33Btn',focus:'#confirmDialog'},
  {id:'08-patch-pps33',title:'补丁模式的 33W 档',caption:'33W 是当前档位，原厂恢复和 55W 可选择；未混入内置镜像集。',data:patchPPS},
  {id:'09-promote-confirm',title:'手动切换全分区的确认',caption:'重新生成并校验完整镜像；同一 DTBO 版本不能回切补丁，不自动换档。',data:patchState,action:'fullModeBtn',focus:'#confirmDialog'},
  {id:'10-full-locked',title:'动态全分区：禁止回切',caption:'全分区模式被选中，补丁按钮禁用；原厂 / PPS 档位仍由全分区入口管理。',data:fullState},
  {id:'11-patch-runtime-broken',title:'补丁资源异常：只准恢复原厂',caption:'当前 33W；驱动或动态工具不兼容后，禁止 PPS 和全分区切换。',data:{...patchPPS,patch_runtime_assets_compatible:'0',patch_can_promote:'0'}},
  {id:'12-full-set-incomplete',title:'全分区镜像不完整',caption:'当前 55W；只保留已验证的原厂恢复，不能借此回切补丁。',data:{...fullState,state:'pps55',sha256:p55,dynamic_assets_complete:'0',rescue_last_written_slot:'B'}},
  {id:'13-stock-recheck',title:'原厂恢复后可重检补丁',caption:'资源不完整时 PPS 继续禁用；详情中可手动重新校验并修复备份。',data:patchRepair,details:true},
  {id:'14-recheck-confirm',title:'重检补丁：不写分区',caption:'确认按钮为“重新检测”；这不是 PPS 刷写，也不是自动切换模式。',data:patchRepair,details:true,action:'patchCheckBtn',focus:'#confirmDialog'},
  {id:'15-slot-conflict',title:'可信槽位来源冲突',caption:'不能确定唯一 DTBO 写入目标时，所有写入与模式切换操作禁用。',data:{...patchState,trusted_slot_conflict:'1',management_mode:'error',patch_can_promote:'0',patch_can_recheck:'0'}},
  {id:'16-system-dtbo-version',title:'系统版本与 DTBO 匹配结果分开',caption:'示例系统显示 1001、DTBO 哈希匹配 701；镜像选择只跟 DTBO 哈希，不跟属性。',data:{...state,sha256:old.stock_sha,dtbo_family:old.firmware,
    static_assets_complete:'1',static_stock_available:'1',ota_patch_available:'0',patch_can_enable:'0',rescue_ready:'1'},details:true},
  {id:'17-recovery',title:'启动失败恢复入口',caption:'删除模块不会撤销 DTBO；页面给出 Recovery 挂载 /data 后的检查和恢复命令。',data:patchPPS,recovery:true,focus:'details:not(#diagnostics)'},
  {id:'18-stock-restore-confirm',title:'恢复原厂也要确认',caption:'仅恢复当前 B 槽的精确原厂 DTBO，保留 AVB 并验证完整回读。',data:patchPPS,action:'stockBtn',focus:'#confirmDialog'},
  {id:'19-disconnected',title:'拔线后不显示残留 PPS / USB 功率',caption:'充电信息是模拟读数；未连接时 USB 输入被清空，协议显示未连接。',data:patchPPS,
    measurements:{...telemetry,status:'Discharging',usb_online:'0',ac_online:'0',ibat_raw:'-900'},focus:'.card[aria-label="实时充电信息"]'},
  {id:'20-desktop',title:'桌面版的 OTA 提示',caption:'同一页面在宽屏上的实际布局；入口、提示和禁用规则与手机一致。',data:state,width:1280,focus:'main'}
];
const mime = {'.js':'text/javascript','.html':'text/html','.css':'text/css','.png':'image/png','.json':'application/json'};
const server = createServer(async (req,res) => {
  const path = decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  const gallery = path.startsWith('/examples/');
  const base = gallery ? output : web;
  const file = resolve(base,'.'+(gallery ? path.slice(9) : path));
  if (!file.startsWith(base+sep)) { res.writeHead(403).end(); return; }
  try { res.setHeader('Content-Type',mime[extname(file)] || 'application/octet-stream'); res.end(await readFile(file)); }
  catch { res.writeHead(404).end(); }
});
await new Promise(done => server.listen(0,'127.0.0.1',done));
const origin = `http://127.0.0.1:${server.address().port}`;
const escape = value => String(value).replace(/[&<>"']/g, ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
let browser;
try {
  browser = await chromium.launch({headless:true});
  for (const example of examples) {
    const page = await browser.newPage({viewport:{width:example.width || 390,height:1050},deviceScaleFactor:1});
    const pageErrors = [];
    page.on('pageerror', error => pageErrors.push(error.message));
    await page.addInitScript(({data,measurements}) => {
      window.__commands=[];
      const kv=value=>Object.entries(value).map(([k,v])=>`${k}=${v}`).join('\n');
      window.ksu={toast(){},exec(command,_options,callback){
        window.__commands.push(command);
        let text='';
        if(command.includes('dtbo_state.sh')) text=kv(data);
        else if(command.includes('boot_state.sh')) text=kv({boot_state:'已解锁',system_firmware:data.system_firmware});
        else if(command.includes('status.sh')) text=kv(measurements);
        else throw new Error('Screenshots allow only mock READ commands: '+command);
        queueMicrotask(()=>window[callback](0,text,''));
      }};
    },{data:example.data,measurements:example.measurements || telemetry});
    await page.goto(origin+'/index.html');
    await page.waitForFunction(()=>document.querySelector('#dtboLabel').textContent!=='正在校验…'
      && !document.querySelector('#refreshBtn').disabled && document.querySelector('#lastRefresh').textContent==='模拟读数');
    await page.evaluate(()=>document.fonts.ready);
    if(example.details) await page.locator('#diagnostics').evaluate(el=>{el.open=true;});
    if(example.recovery) await page.locator('details:not(#diagnostics)').evaluate(el=>{el.open=true;});
    if(example.action) {
      assert.equal(await page.locator('#'+example.action).isDisabled(),false,example.id+' unavailable action');
      await page.locator('#'+example.action).click();
      await page.waitForFunction(()=>document.querySelector('#confirmDialog').open);
    }
    await page.evaluate(()=>window.scrollTo(0,0));
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,example.id+' overflow');
    assert.deepEqual(pageErrors,[],example.id);
    assert.equal(await page.evaluate(()=>window.__commands.every(c=>/\/(dtbo_state|boot_state|status)\.sh/.test(c))),true);
    const screenshot = join(output,'raw',example.id+'.png');
    await page.screenshot({path:screenshot,fullPage:!example.action,animations:'disabled'});
    let focus=example.focus || '.control';
    if(example.id==='19-disconnected') focus='.card:not(.control):not(details):not(.log-card)';
    if(example.id==='13-stock-recheck') {
      await page.locator('#diagnostics .tools').screenshot({path:join(output,'focus',example.id+'-actions.png'),animations:'disabled'});
      example.extraImage='focus/'+example.id+'-actions.png';
    }
    if(example.id==='16-system-dtbo-version') focus='#diagnostics';
    if(example.id==='16-system-dtbo-version') {
      await page.locator('.card:not(.control):not(details):not(.log-card) .row').screenshot({path:join(output,'focus',example.id+'-system.png'),animations:'disabled'});
      example.extraImage='focus/'+example.id+'-system.png';
      example.extraCaption='系统固件版本：从 Android 属性读取';
      example.extraBefore=true;
      await page.setViewportSize({width:390,height:2200});
      const box=await page.locator('#diagnostics').boundingBox();
      const last=await page.locator('#diagnostics .kv').nth(8).boundingBox();
      await page.screenshot({path:join(output,'focus',example.id+'.png'),clip:{x:box.x,y:box.y,width:box.width,height:last.y+last.height-box.y+12},animations:'disabled'});
    } else await page.locator(focus).screenshot({path:join(output,'focus',example.id+'.png'),animations:'disabled'});
    example.raw='raw/'+example.id+'.png'; example.focusImage='focus/'+example.id+'.png';
    console.log('CAPTURED '+example.id+' · '+example.title);
    await page.close();
  }
  const zipPath=join(repo,'dist','PJX110-PPS-KSU-v1.2.0.zip');
  const zipData=await readFile(zipPath);
  const zipSHA=createHash('sha256').update(zipData).digest('hex');
  const inventory=JSON.parse(execFileSync('pwsh',['-NoLogo','-NoProfile','-Command',`
    $archive=[IO.Compression.ZipFile]::OpenRead('${zipPath.replace(/'/g,"''")}')
    try {
      [pscustomobject]@{Entries=$archive.Entries.Count;ImageSets=@($archive.Entries|Where-Object FullName -Like 'image_sets/*').Count;
        RawImages=@($archive.Entries|Where-Object FullName -Like 'images/*').Count;
        Agents=@($archive.Entries|Where-Object FullName -Like '*AGENTS.md').Count} | ConvertTo-Json -Compress
    } finally {$archive.Dispose()}
  `],{encoding:'utf8'}).trim());
  assert.equal(inventory.ImageSets,catalog.length);
  assert.equal(inventory.RawImages,0); assert.equal(inventory.Agents,0);
  let tripletBytes=0;
  for(const profile of ['stock','pps33','pps55']) tripletBytes+=(await stat(join(repo,'images',`dtbo_${current.family}_${profile}.img`))).size;
  const packageReport={...inventory,firmwares:catalog.length,sourceImages:catalog.length*3,
    zipBytes:zipData.length,zipSHA,selectedTripletBytes:tripletBytes,unknownBundledImages:0};
  const reportHTML=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>镜像集安装策略 · 本地检查</title>
    <style>*{box-sizing:border-box}body{margin:0;padding:36px;background:#f1f3ee;color:#17221e;font-family:"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:900px;margin:auto}.tag{display:inline-block;border-radius:99px;background:#e3f2e7;color:#147454;padding:8px 12px;font-size:12px}h1{font-size:28px;margin:20px 0 10px}p{font-size:14px;color:#687970;line-height:1.8}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:24px 0}.metric,.panel{background:#fff;border:1px solid #e5eae3;border-radius:20px;padding:22px}.metric strong{font-size:34px;display:block;margin-bottom:8px}.metric small{color:#687970;font-size:12px}.panel{margin-top:16px}h2{font-size:17px;margin:0 0 12px}table{width:100%;border-collapse:collapse;font-size:14px}td{padding:15px 0;border-bottom:1px solid #e5eae3}td:last-child{text-align:right;font-weight:600}tr:last-child td{border:0}code{font:12px/1.8 Consolas,monospace;overflow-wrap:anywhere;color:#52685b}.note{background:#182c23;color:#dcecdc;border-radius:18px;padding:18px 22px;font-size:13px;line-height:1.8;margin-top:20px}</style>
    <main><span class="tag">本地安装包检查 · 不是手机安装截图</span><h1>安装时只提取当前版本镜像集</h1>
    <p>以下安装包数据从当前 ZIP 与固件清单读取。手机端空间为安装策略，不代表已经安装到手机。</p>
    <section class="metrics"><div class="metric"><strong>${catalog.length}</strong><small>ZIP 内压缩镜像集</small></div><div class="metric"><strong>${catalog.length*3}</strong><small>源镜像总数</small></div><div class="metric"><strong>${tripletBytes/1048576} MiB</strong><small>匹配版本的 3 张镜像</small></div><div class="metric"><strong>${(zipData.length/1048576).toFixed(2)} MiB</strong><small>当前可刷 KSU ZIP</small></div></section>
    <section class="panel"><h2>安装后的保留策略</h2><table><tr><td>匹配当前 DTBO 完整 SHA256</td><td>仅保留原厂 / 33W / 55W</td></tr><tr><td>未知 DTBO 或槽位不可信</td><td>不保留内置原始镜像</td></tr><tr><td>压缩集与自检临时镜像</td><td>安装成功后删除</td></tr><tr><td>外部原厂备份与救援快照</td><td>保留，不随模块清理删除</td></tr><tr><td>安装是否写入分区</td><td>不写入 DTBO，也不动其他分区</td></tr></table></section>
    <section class="panel"><h2>当前 ZIP 核对</h2><table><tr><td>文件数量</td><td>${inventory.Entries}</td></tr><tr><td>未压缩 images/ 目录</td><td>不存在</td></tr><tr><td>AGENTS.md</td><td>未包含</td></tr></table><code>SHA256 ${zipSHA}</code></section>
    <div class="note">OTA 换入其他版本后，不沿用旧镜像集。缺少对应镜像时禁用刷写；重装模块，或在符合条件时手动检测新原厂 DTBO 并登记补丁模式。</div></main></html>`;
  await writeFile(join(output,'installation-report.html'),reportHTML);
  const reportPage=await browser.newPage({viewport:{width:980,height:1120},deviceScaleFactor:1});
  await reportPage.goto(origin+'/examples/installation-report.html');
  await reportPage.evaluate(()=>document.fonts.ready);
  await reportPage.screenshot({path:join(output,'raw','21-installation-report.png'),fullPage:true});
  await reportPage.locator('main').screenshot({path:join(output,'focus','21-installation-report.png')});
  await reportPage.close();
  examples.push({id:'21-installation-report',title:'安装时解压镜像集与空间占用',caption:'真实 ZIP 的本地文件检查图；不是手机安装画面，不是伪造的安装日志。',
    raw:'raw/21-installation-report.png',focusImage:'focus/21-installation-report.png',width:980,report:true});
  console.log('CAPTURED 21-installation-report · verified archive inventory');
  const galleryStyle=`*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#edf1eb;color:#17221e;font-family:"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1120px;margin:auto;padding:38px 24px}.eyebrow{font-size:12px;letter-spacing:1px;color:#147454;font-weight:700}h1{font-size:30px;margin:14px 0}.notice{background:#182c23;border-radius:18px;color:#dcebdc;line-height:1.9;padding:18px 22px;font-size:14px}.toplinks{display:flex;gap:10px;flex-wrap:wrap;margin:20px 0}.toplinks a{font-size:13px;color:#147454;background:white;padding:10px 14px;border:1px solid #dae4d9;border-radius:12px;text-decoration:none}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:22px;margin:26px 0}.example{background:white;border:1px solid #dbe4d8;border-radius:22px;overflow:hidden;align-self:start}.cap{padding:20px 22px 15px}.num{color:#147454;font-size:12px;font-weight:700}.cap h2{font-size:18px;margin:8px 0 9px}.cap p{font-size:12px;line-height:1.8;color:#63796a;margin:0}.label{font-size:11px;background:#eef6e9;color:#426243;border-radius:99px;display:inline-block;padding:5px 9px;margin-top:12px}.image{display:block;background:#f1f3ee}.image img{display:block;width:100%;height:auto}.image.thumb img{max-height:1220px;object-fit:cover;object-position:top}.extra{padding:10px 22px 16px;background:#f1f3ee;font-size:11px;color:#526759}.extra img{display:block;width:100%;margin-top:8px}.more{display:block;padding:12px 22px;color:#147454;font-size:12px;text-decoration:none;background:#f8faf5}.wide{grid-column:1/-1}footer{font-size:12px;line-height:1.8;color:#63796a}@media(max-width:720px){.grid{grid-template-columns:1fr}main{padding:24px 14px}h1{font-size:24px}}`;
  const extraImage=(example,compact)=>compact&&example.extraImage?`<div class="extra">${escape(example.extraCaption||'状态详情底部的工具按钮')}<img src="${example.extraImage}" alt="${escape(example.extraCaption||'重检补丁工具按钮')}"></div>`:'';
  const card=(example,compact=false)=>`<article class="example ${!compact&&example.width?'wide':''}" id="${example.id}"><div class="cap"><span class="num">${example.id.slice(0,2)}</span><h2>${escape(example.title)}</h2><p>${escape(example.caption)}</p><span class="label">${example.report?'本地文件检查 · 非手机截图':'WebUI 实际渲染 · 模拟 KSU 数据'}</span></div>${example.extraBefore?extraImage(example,compact):''}<a class="image ${compact?'':'thumb'}" href="${example.raw}"><img src="${compact?example.focusImage:example.raw}" alt="${escape(example.title)}"></a>${!example.extraBefore?extraImage(example,compact):''}<a class="more" href="${example.raw}">打开完整原图 ↗</a></article>`;
  const groups=[{name:'01-ota-entry',title:'OTA、缺镜像与补丁入口',ids:examples.slice(0,6)},
    {name:'02-modes-safety',title:'档位、单向切换与损坏资源门禁',ids:examples.slice(6,12)},
    {name:'03-status-recovery',title:'重检、槽位、版本读取与恢复',ids:examples.slice(12,18)},
    {name:'04-charging-install',title:'充电状态、宽屏与安装包',ids:examples.slice(18)}];
  for(const group of groups) {
    const sheet=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><style>${galleryStyle}main{width:1060px;max-width:none;padding:32px}.grid{align-items:start}.image img{max-height:620px;object-fit:contain;object-position:top}.cap{min-height:154px}.more{display:none}.notice{font-size:13px}h1{font-size:27px}</style><main><div class="eyebrow">ACE3PRO PPS · 修改截图实例</div><h1>${group.title}</h1><div class="notice">所有 WebUI 画面均来自未改布局的项目页面 + 模拟 KSU 数据。未连接或刷写手机，读数不代表实机功率或兼容性。</div><section class="grid">${group.ids.map(example=>card(example,true)).join('')}</section></main></html>`;
    await writeFile(join(output,group.name+'.html'),sheet);
    const sheetPage=await browser.newPage({viewport:{width:1060,height:900},deviceScaleFactor:1});
    await sheetPage.goto(origin+'/examples/'+group.name+'.html');
    await sheetPage.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(img=>img.decode()));});
    await sheetPage.screenshot({path:join(output,group.name+'.png'),fullPage:true});
    await sheetPage.close();
  }
  const gallery=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ace3Pro PPS · 新修改截图实例</title><style>${galleryStyle}</style><main><div class="eyebrow">ACE3PRO PPS · WEBUI EXAMPLES</div><h1>新修改截图实例</h1><div class="notice">${examples.length} 张完整截图：20 个 WebUI 状态 + 1 张本地安装包检查图。WebUI 使用模拟 KSU 数据，布局与文案来自当前项目原文件；没有连接或刷写手机，不构成开机、充电功率或固件兼容性的实机证明。点击图片可打开原图。</div><nav class="toplinks">${groups.map(group=>`<a href="${group.name}.png">${group.title} · 拼图</a>`).join('')}<a href="installation-report.html">安装包检查详情</a></nav><section class="grid">${examples.map(example=>card(example)).join('')}</section><footer>本次仅生成截图、相册和本地检查报告；未修改模块功能代码，未提交或推送。<br>底层分区写入仍只允许可信槽位对应的 dtbo_a / dtbo_b，保留完整 AVB，并校验镜像 SHA256 与回读。</footer></main></html>`;
  await writeFile(join(output,'index.html'),gallery);
  await writeFile(join(output,'manifest.json'),JSON.stringify({note:'Mock KSU WebUI screenshots; no phone or partition writes',package:packageReport,
    examples:examples.map(example=>({id:example.id,title:example.title,caption:example.caption,raw:example.raw,focus:example.focusImage,mode:example.data?.management_mode,profile:example.data?.state}))},null,2));
  const galleryPage=await browser.newPage({viewport:{width:1280,height:900}});
  await galleryPage.goto(origin+'/examples/index.html');
  await galleryPage.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(img=>img.decode()));});
  assert.equal(await galleryPage.locator('.example').count(),21);
  assert.equal(await galleryPage.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  await galleryPage.screenshot({path:join(output,'gallery-top.png')});
  await galleryPage.close();
  console.log(JSON.stringify({output,examples:examples.length,sheets:groups.length,package:packageReport},null,2));
} finally {
  if(browser) await browser.close();
  await new Promise(done=>server.close(done));
}
