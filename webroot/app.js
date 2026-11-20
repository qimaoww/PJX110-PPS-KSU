import {exec, execRead, toast} from './ksu.js';
import {parseKV, telemetry} from './telemetry.js';
import {controlState, modeHint, profileName, modeName} from './controls.js';
import {mountUfcs} from './ufcs.js';

const MODDIR = '/data/adb/modules/PJX110_PPS_KSU';
const $ = id => document.getElementById(id);
const dash = value => value === undefined || value === null || String(value).trim() === '' ? '—' : String(value);
const fmt = (value, digits = 2) => Number.isFinite(value) ? value.toFixed(digits) : '—';
const readCommand = (script, timeout = 8000) => execRead(`sh '${MODDIR}/bin/web_read.sh' ${script}`, timeout);
let controls = controlState({}), snapshot = {}, actionBusy = false, dtboBusy = false;
let refreshBusy = false, telemetryFlight = null, pollTimer = null, lastTelemetryAt = 0, pollDelay = 5000;
let pending = null, needsReboot = false, logBusy = false, scanBusy = false;
let pollGeneration = 0;
let dtboReadError = '', phase = '', activeRequest = null, ufcsBusy = false;
let ufcsPanel;

function setText(id, value) {
  const node = $(id), text = String(value);
  if (node.textContent !== text) node.textContent = text;
}
function chip(id, label, tone = '') {
  setText(id, label);
  const name = `chip${tone ? ` ${tone}` : ''}`;
  if ($(id).className !== name) $(id).className = name;
}
function showLog(title, output) {
  $('logCard').hidden = false;
  $('logTitle').textContent = title;
  $('logOutput').textContent = String(output || '(无输出)');
}
function markTelemetryStale(message = '读取失败') {
  setText('lastRefresh', lastTelemetryAt ? `${message} · 上次读数` : message);
  chip('chargeStatus', message, 'bad');
}
function renderTelemetry(data) {
  const t = telemetry(data);
  setText('bridgeStatus', '正常');
  setText('pbat', fmt(t.power));
  setText('capacity', dash(t.capacity));
  const level = `${t.capacity ?? 0}%`;
  if ($('batteryRing').style.getPropertyValue('--level') !== level) $('batteryRing').style.setProperty('--level', level);
  setText('powerLabel', t.powerEstimated ? '电池功率 · 估算' : '电池功率');
  setText('protocol', t.proto);
  setText('temp', fmt(t.temp, 1));
  setText('vbat', fmt(t.pack, 3));
  setText('ibat', fmt(t.current, 3));
  setText('inputSummary', t.usbPower === null ? 'USB 输入 —' : `USB 输入 ${fmt(t.usbPower)} W`);
  setText('lastRefresh', dash(data.timestamp));
  chip('chargeStatus', t.label, t.tone);
  setText('cells', `${fmt(t.cell1, 3)} / ${fmt(t.cell2, 3)} V`);
  setText('cellSource', t.cellSource);
  setText('usbMeasurements', `${fmt(t.usbV, 3)} V / ${fmt(t.usbI, 3)} A`);
  setText('usbPower', t.usbPower === null ? '—' : `${fmt(t.usbPower)} W`);
  setText('icl', t.icl === null ? '—' : `${fmt(t.icl, 3)} A`);
  setText('protocolSource', t.protoSource);
  setText('usbTypeRaw', dash(data.usb_type_raw));
  setText('usbTypes', `${dash(data.usb_real_type)} / ${dash(data.typec_mode)}`);
  setText('readingSource', `${dash(data.usb_v_raw_source)} / ${dash(data.usb_i_raw_source)}`);
  setText('batteryHealth', `${dash(data.health)} / ${dash(data.cycle_count)}`);
  setText('batteryCapacity', `${fmt(t.full, 0)} / ${fmt(t.design, 0)} mAh`);
  setText('chargingPolicy', `${dash(data.mmi_charging_enable)} / ${dash(data.cool_down)}`);
  lastTelemetryAt = Date.now();
}
function refreshTelemetry() {
  if (document.hidden) return Promise.resolve();
  if (telemetryFlight) return telemetryFlight;
  telemetryFlight = (async () => {
    try {
      const result = await readCommand('status.sh');
      if (result.errno !== 0) throw new Error(result.stderr || '读取失败');
      renderTelemetry(parseKV(result.stdout));
      pollDelay = 5000;
    } catch (error) {
      markTelemetryStale(String(error.message || error).includes('超时') ? '读取超时' : '读取失败');
      pollDelay = Math.min(pollDelay * 2, 30000);
    } finally {
      telemetryFlight = null;
    }
  })();
  return telemetryFlight;
}
function renderRefresh() {
  $('refreshBtn').disabled = refreshBusy;
  $('refreshBtn').setAttribute('aria-busy', String(refreshBusy));
}
function renderScan() {
  $('scanBtn').disabled = scanBusy;
  setText('scanBtn', scanBusy ? '扫描中…' : '扫描节点');
  $('scanBtn').setAttribute('aria-busy', String(scanBusy));
}
function renderControls() {
  const locked = actionBusy || dtboBusy || ufcsBusy || Boolean(pending);
  for (const [target, id] of [['stock','stockBtn'],['pps33','pps33Btn'],['pps55','pps55Btn']]) {
    const selected = controls.profile === target;
    $(id).classList.toggle('selected', selected);
    $(id).setAttribute('aria-pressed', String(selected));
    $(id).disabled = locked || !controls.canProfile(target);
  }
  const full = ['full_static', 'full_dynamic'].includes(controls.mode);
  $('patchModeBtn').classList.toggle('selected', controls.mode === 'patch');
  $('fullModeBtn').classList.toggle('selected', full);
  // A request is not a selection: aria-pressed only reflects verified state.
  const requested = pending?.type || activeRequest;
  $('patchModeBtn').classList.toggle('requested', requested === 'enable' || requested === 'recheck');
  $('fullModeBtn').classList.toggle('requested', requested === 'selectStatic' || requested === 'promote');
  $('patchModeBtn').setAttribute('aria-pressed', String(controls.mode === 'patch'));
  $('fullModeBtn').setAttribute('aria-pressed', String(full));
  $('patchModeBtn').disabled = locked || !controls.canEnable;
  setText('patchModeBtn', controls.otaPatch ? '检测并使用补丁' : '补丁模式');
  $('fullModeBtn').disabled = locked || !(controls.canSelectStatic || controls.canPromote);
  $('modeHint').hidden = Boolean(pending && pending.type !== 'profile');
  setText('modeHint', phase || (dtboBusy ? '正在校验 DTBO…' : dtboReadError || modeHint(controls)));
  setText('rebootHint', needsReboot ? '已写入 · 请重启' : '更改档位后需重启');
  $('modeRetry').hidden = !dtboReadError || dtboBusy;
  $('verifyBtn').disabled = actionBusy || dtboBusy || Boolean(pending);
  setText('verifyBtn', dtboBusy ? '校验中…' : '校验 DTBO');
  $('patchCheckBtn').hidden = controls.mode !== 'patch';
  $('patchCheckBtn').disabled = locked || !controls.canRecheck;
}
async function refreshDtbo() {
  if (dtboBusy || actionBusy || pending) return;
  dtboBusy = true;
  dtboReadError = '';
  renderControls();
  try {
    const result = await readCommand('dtbo_state.sh', 65000);
    if ([124,137].includes(result.errno)) throw new Error('DTBO 校验超时');
    if (result.errno !== 0) throw new Error(result.stderr || parseKV(result.stdout).message || 'DTBO 读取失败');
    snapshot = parseKV(result.stdout);
    controls = controlState(snapshot);
    $('dtboLabel').textContent = controls.profile === 'stock' ? '原厂 DTBO' : controls.profile === 'unknown' ? '尚未识别' : profileName(controls.profile);
    chip('slotBadge', `槽位 ${dash(snapshot.slot)}`, controls.valid ? '' : 'bad');
    if (snapshot.system_firmware) $('systemFirmware').textContent = snapshot.system_firmware;
    $('dtboFamily').textContent = dash(snapshot.dtbo_family);
    $('managementMode').textContent = modeName(controls.mode);
    $('slotSource').textContent = dash(snapshot.slot_source);
    $('slotConflict').textContent = snapshot.trusted_slot_available !== '1' ? '无可信来源'
      : snapshot.trusted_slot_conflict === '1' ? '底层来源冲突'
        : snapshot.prop_slot_conflict === '1' ? '底层一致 · 属性不同' : '一致';
    $('sha').textContent = dash(snapshot.sha256);
    $('rescueStatus').textContent = snapshot.rescue_ready === '1' ? '已验证' : '写入前生成并校验';
    $('rescueLastSlot').textContent = snapshot.rescue_last_written_slot === 'none' ? '无' : dash(snapshot.rescue_last_written_slot);
  } catch (error) {
    snapshot = {};
    controls = controlState({});
    $('dtboLabel').textContent = String(error.message || error).includes('超时') ? '校验超时' : '读取失败';
    dtboReadError = `${$('dtboLabel').textContent}，请重新校验 DTBO。`;
    chip('slotBadge', '不可写入', 'bad');
    for (const id of ['dtboFamily','managementMode','slotSource','slotConflict','sha','rescueStatus','rescueLastSlot']) $(id).textContent = '—';
  } finally {
    dtboBusy = false;
    renderControls();
  }
}
async function refreshDevice() {
  try {
    const result = await readCommand('boot_state.sh');
    if (result.errno !== 0) throw new Error('读取失败');
    const data = parseKV(result.stdout);
    $('bootState').textContent = dash(data.boot_state);
    if (data.system_firmware) $('systemFirmware').textContent = data.system_firmware;
    $('bridgeStatus').textContent = '正常';
  } catch (_) {
    $('bootState').textContent = '不可读';
    $('bridgeStatus').textContent = '读取失败';
  }
}
async function refreshAll() {
  if (refreshBusy) return;
  refreshBusy = true;
  renderRefresh();
  // Let the pressed/loading feedback paint before crossing the native bridge.
  try {
    await new Promise(resolve => setTimeout(resolve, 32));
    await Promise.allSettled([refreshTelemetry(), ufcsPanel?.refresh()]);
  }
  finally {
    refreshBusy = false;
    renderRefresh();
  }
}
function isAllowed(action) {
  if (!action || actionBusy || ufcsBusy || dtboBusy) return false;
  if (action.signature && action.signature !== snapshotSignature()) return false;
  return action.type === 'profile' ? controls.canProfile(action.target)
    : action.type === 'enable' ? controls.canEnable
      : action.type === 'selectStatic' ? controls.canSelectStatic
      : action.type === 'recheck' ? controls.canRecheck
      : action.type === 'promote' && controls.canPromote;
}
function snapshotSignature() {
  return `${snapshot.sha256 || ''}:${snapshot.slot_suffix || ''}:${controls.mode}`;
}
function ask(action) {
  if (pending || !isAllowed(action)) return;
  pending = {...action, signature: snapshotSignature(), trigger: document.activeElement};
  if (action.type === 'enable' || action.type === 'recheck') {
    $('confirmTitle').textContent = action.type === 'recheck' ? '重新检测补丁' : '启用补丁模式';
    $('confirmText').textContent = `${controls.otaPatch ? '仅为 OTA 换入的新原厂 DTBO 启用补丁。' : ''}检测驱动、DTBO 与 AVB，并保存精确原厂备份和救援快照。本操作不写入分区。`;
    $('confirmBtn').textContent = action.type === 'recheck' ? '重新检测' : '检测并启用';
  } else if (action.type === 'selectStatic') {
    $('confirmTitle').textContent = '使用内置全分区模式';
    $('confirmText').textContent = '校验当前槽的原厂、33W 和 55W 内置镜像。仅记录选择，不写入分区。';
    $('confirmBtn').textContent = '选择全分区';
  } else if (action.type === 'promote') {
    $('confirmTitle').textContent = '切换全分区模式';
    $('confirmText').textContent = '重新生成并校验三个完整镜像。仅切换管理模式，不写入分区。';
    $('confirmBtn').textContent = '确认切换';
  } else {
    const stock = action.target === 'stock';
    $('confirmTitle').textContent = `${stock ? '恢复' : '切换'}${profileName(action.target)}`;
    const tested = String(snapshot.dtbo_family || '') === 'PJX110_16.0.2.400';
    $('confirmText').textContent = `仅写入当前 ${dash(snapshot.slot)} 槽 DTBO，保留 AVB 并回读校验。${stock ? '' : tested ? '' : '当前固件的 PPS 未经实机验证。'}${action.target === 'pps55' ? '需 5A PPS 充电器与线材。' : ''}完成后需重启。`;
    $('confirmBtn').textContent = stock ? '恢复原厂' : '确认写入';
  }
  const dialog = $('confirmDialog');
  dialog.classList.toggle('inline-confirm', action.type !== 'profile');
  if (action.type === 'profile') dialog.showModal(); else dialog.show();
  renderControls();
}
function closeDialog() {
  const trigger = pending?.trigger;
  pending = null;
  $('confirmDialog').close();
  renderControls();
  trigger?.focus({preventScroll:true});
}
async function applyAction() {
  const action = pending;
  if (!action) return;
  closeDialog();
  if (!isAllowed(action)) { toast('状态已变化，请刷新后重试'); return; }
  actionBusy = true;
  activeRequest = action.type;
  phase = {enable:'正在检测补丁并备份原厂 DTBO…', recheck:'正在重新检测补丁…',
    selectStatic:'正在校验内置镜像…', promote:'正在生成并校验全分区镜像…', profile:'正在写入并回读 DTBO，请勿重启。'}[action.type];
  $('actionDetails').hidden = true;
  $('actionDetails').open = false;
  ufcsPanel?.render();
  renderControls();
  const command = action.type === 'enable' ? `sh '${MODDIR}/bin/patch_mode.sh' enable`
    : action.type === 'recheck' ? `sh '${MODDIR}/bin/patch_mode.sh' recheck`
    : action.type === 'promote' ? `sh '${MODDIR}/bin/promote_full.sh'`
    : action.type === 'selectStatic' ? `sh '${MODDIR}/bin/select_static_full.sh' '${snapshot.slot_suffix}' '${snapshot.sha256}'`
      : `sh '${MODDIR}/bin/${controls.mode === 'patch' ? 'patch_toggle.sh' : 'toggle.sh'}' '${action.target}'`;
  let ok = false, output = '';
  try {
    // Give WebView a paint opportunity before calling the native bridge.
    await new Promise(resolve => setTimeout(resolve, 32));
    // Never release the mutation gate on a timer.
    const result = await exec(command);
    output = `${result.stdout}${result.stderr ? `\n${result.stderr}` : ''}`.trim();
    ok = result.errno === 0;
    if (ok && action.type === 'profile') needsReboot = true;
  } catch (error) { output = String(error); }
  finally {
    phase = '正在核对当前槽的实际状态…';
    actionBusy = false;
    await refreshDtbo();
    const expected = action.type === 'profile' ? controls.profile === action.target
      : controls.mode === ({enable:'patch',recheck:'patch',selectStatic:'full_static',promote:'full_dynamic'})[action.type];
    const [previousHash, previousSlot] = action.signature.split(':');
    const verified = controls.valid && controls.mode !== 'error' && expected && previousSlot === snapshot.slot_suffix
      && (action.type === 'profile' || previousHash === snapshot.sha256);
    phase = '';
    activeRequest = null;
    setText('actionTitle', !ok ? '操作失败 · 查看原因' : !verified ? '结果未确认 · 查看记录' : action.type === 'profile' ? '已写入 · 请重启' : `已核验：${modeName(controls.mode)}`);
    setText('actionOutput', output || '无脚本输出');
    $('actionDetails').hidden = false;
    $('actionDetails').open = !ok;
    ufcsPanel?.render();
    renderControls();
  }
}
async function loadLog() {
  if (logBusy) return;
  logBusy = true;
  $('logBtn').disabled = true;
  try {
    const result = await readCommand('charging_log.sh', 15000);
    if (result.errno !== 0) throw new Error(result.stderr || '日志不可读');
    // dmesg is historical. Never use it to replace current live measurements.
    showLog('充电日志 · 历史记录', result.stdout);
  } catch (error) { showLog('日志读取失败', String(error)); }
  finally { logBusy = false; $('logBtn').disabled = false; }
}
async function scanNodes() {
  if (scanBusy) return;
  scanBusy = true;
  $('nodeOutput').hidden = false;
  $('nodeOutput').textContent = '正在扫描…';
  $('nodeOutput').setAttribute('aria-busy', 'true');
  renderScan();
  try {
    await new Promise(resolve => setTimeout(resolve, 32));
    const result = await readCommand('details.sh', 10000);
    const data = parseKV(result.stdout);
    const lines = Object.entries(data).filter(([key]) => /^detail_\d+$/.test(key))
      .slice(0, 32).map(([,value]) => value);
    const incomplete = result.errno !== 0 || data.scan_complete !== '1';
    if (incomplete && !lines.length) throw new Error('扫描未完成，请重试');
    $('nodeOutput').textContent = (lines.join('\n') || '未找到可读节点')
      + (incomplete ? '\n\n扫描超时，已保留读取结果。' : data.scan_limited === '1' ? '\n\n已达到扫描上限。' : '');
  } catch (error) { $('nodeOutput').textContent = String(error); }
  finally {
    scanBusy = false;
    $('nodeOutput').setAttribute('aria-busy', 'false');
    renderScan();
  }
}
async function copyLog() {
  const text = $('logOutput').textContent;
  if (!text) return;
  try { await navigator.clipboard.writeText(text); toast('已复制'); }
  catch (_) {
    const field = document.createElement('textarea');
    field.value = text; field.style.position = 'fixed'; field.style.opacity = '0';
    document.body.appendChild(field); field.select();
    let copied = false;
    try { copied = document.execCommand('copy'); } catch (_) {}
    field.remove(); toast(copied ? '已复制' : '请长按日志复制');
  }
}
function scheduleTelemetry() {
  clearTimeout(pollTimer);
  const generation = ++pollGeneration;
  if (document.hidden) return;
  pollTimer = setTimeout(async () => {
    try { await Promise.allSettled([refreshTelemetry(), ufcsPanel?.refresh()]); }
    finally { if (generation === pollGeneration) scheduleTelemetry(); }
  }, pollDelay);
}
for (const [target, id] of [['stock','stockBtn'],['pps33','pps33Btn'],['pps55','pps55Btn']]) $(id).addEventListener('click', () => ask({type: 'profile', target}));
$('patchModeBtn').addEventListener('click', () => ask({type: 'enable'}));
$('fullModeBtn').addEventListener('click', () => ask({type: controls.canSelectStatic ? 'selectStatic' : 'promote'}));
$('patchCheckBtn').addEventListener('click', () => ask({type: 'recheck'}));
$('cancelBtn').addEventListener('click', closeDialog);
$('confirmBtn').addEventListener('click', applyAction);
$('confirmDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog(); });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && pending && pending.type !== 'profile') { event.preventDefault(); closeDialog(); }
});
$('confirmDialog').addEventListener('click', event => {
  if (event.target !== $('confirmDialog')) return;
  const box = event.target.getBoundingClientRect();
  if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) closeDialog();
});
$('refreshBtn').addEventListener('click', refreshAll);
$('verifyBtn').addEventListener('click', () => { void refreshDtbo(); });
$('modeRetry').addEventListener('click', () => { void refreshDtbo(); });
$('logBtn').addEventListener('click', loadLog);
$('scanBtn').addEventListener('click', scanNodes);
$('copyLogBtn').addEventListener('click', copyLog);
$('closeLog').addEventListener('click', () => { $('logCard').hidden = true; });
document.addEventListener('visibilitychange', async () => {
  clearTimeout(pollTimer);
  const generation = ++pollGeneration;
  if (!document.hidden) {
    if (Date.now() - lastTelemetryAt > 15000) markTelemetryStale('更新中');
    await Promise.allSettled([refreshTelemetry(), ufcsPanel?.refresh()]);
    if (generation === pollGeneration) scheduleTelemetry();
  }
});
ufcsPanel = mountUfcs({busy: () => actionBusy, setBusy: value => {
  ufcsBusy = value;
  renderControls();
}});
void refreshAll();
scheduleTelemetry();
void refreshDevice();
void refreshDtbo();
