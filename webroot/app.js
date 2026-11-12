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
  if (document.hidden || actionBusy) return Promise.resolve();
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
  $('refreshBtn').disabled = actionBusy || refreshBusy;
  $('refreshBtn').setAttribute('aria-busy', String(refreshBusy));
}
function renderScan() {
  $('scanBtn').disabled = actionBusy || scanBusy;
  setText('scanBtn', scanBusy ? '扫描中…' : '扫描节点');
  $('scanBtn').setAttribute('aria-busy', String(scanBusy));
}
function renderControls() {
  ufcsPanel?.render();
  for (const [target, id] of [['stock','stockBtn'],['pps33','pps33Btn'],['pps55','pps55Btn']]) {
    const selected = controls.profile === target;
    $(id).classList.toggle('selected', selected);
    $(id).setAttribute('aria-pressed', String(selected));
    $(id).disabled = actionBusy || dtboBusy || !controls.canProfile(target);
  }
  const full = ['full_static', 'full_dynamic'].includes(controls.mode);
  $('patchModeBtn').classList.toggle('selected', controls.mode === 'patch');
  $('fullModeBtn').classList.toggle('selected', full);
  $('patchModeBtn').setAttribute('aria-pressed', String(controls.mode === 'patch'));
  $('fullModeBtn').setAttribute('aria-pressed', String(full));
  $('patchModeBtn').disabled = actionBusy || dtboBusy || !controls.canEnable;
  $('patchModeBtn').textContent = controls.otaPatch ? '检测并使用补丁' : '补丁模式';
  $('fullModeBtn').disabled = actionBusy || dtboBusy || !controls.canPromote;
  $('modeHint').textContent = actionBusy ? '正在执行，请勿重启或断电。'
    : dtboBusy ? '正在校验 DTBO…' : modeHint(controls);
  $('rebootHint').textContent = needsReboot ? '已写入 · 请重启' : '应用后需重启';
  renderRefresh();
  $('logBtn').disabled = actionBusy || logBusy;
  renderScan();
  $('verifyBtn').disabled = actionBusy || dtboBusy;
  $('verifyBtn').textContent = dtboBusy ? '校验中…' : '校验 DTBO';
  $('patchCheckBtn').hidden = controls.mode !== 'patch';
  $('patchCheckBtn').disabled = actionBusy || dtboBusy || !controls.canRecheck;
}
async function refreshDtbo() {
  if (dtboBusy || actionBusy) return;
  dtboBusy = true;
  renderControls();
  try {
    const result = await readCommand('dtbo_state.sh', 30000);
    if (result.errno !== 0) throw new Error(result.stderr || 'DTBO 读取失败');
    snapshot = parseKV(result.stdout);
    controls = controlState(snapshot);
    $('dtboLabel').textContent = controls.profile === 'unknown' ? '尚未识别' : profileName(controls.profile);
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
  if (refreshBusy || actionBusy) return;
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
  if (!action || actionBusy || dtboBusy) return false;
  if (action.signature && action.signature !== snapshotSignature()) return false;
  return action.type === 'profile' ? controls.canProfile(action.target)
    : action.type === 'enable' ? controls.canEnable
      : action.type === 'recheck' ? controls.canRecheck
      : action.type === 'promote' && controls.canPromote;
}
function snapshotSignature() {
  return `${snapshot.sha256 || ''}:${snapshot.slot_suffix || ''}:${controls.mode}`;
}
function ask(action) {
  if (!isAllowed(action)) return;
  pending = {...action, signature: snapshotSignature()};
  if (action.type === 'enable' || action.type === 'recheck') {
    $('confirmTitle').textContent = action.type === 'recheck' ? '重新检测补丁' : '启用补丁模式';
    $('confirmText').textContent = `${controls.otaPatch ? '仅为 OTA 换入的新原厂 DTBO 启用补丁。' : ''}检测驱动、DTBO 与 AVB，并保存精确原厂备份和救援快照。本操作不写入分区。`;
    $('confirmBtn').textContent = action.type === 'recheck' ? '重新检测' : '检测并启用';
  } else if (action.type === 'promote') {
    $('confirmTitle').textContent = '切换全分区模式';
    $('confirmText').textContent = '重新生成并校验三个完整镜像。同一 DTBO 版本不能返回补丁模式，不会自动切换档位。';
    $('confirmBtn').textContent = '确认单向切换';
  } else {
    const stock = action.target === 'stock';
    $('confirmTitle').textContent = `${stock ? '恢复' : '切换'}${profileName(action.target)}`;
    const tested = String(snapshot.dtbo_family || '') === 'PJX110_16.0.2.400';
    $('confirmText').textContent = `仅写入当前 ${dash(snapshot.slot)} 槽 DTBO，保留 AVB 并回读校验。${stock ? '' : tested ? '' : '当前固件的 PPS 未经实机验证。'}${action.target === 'pps55' ? '需 5A PPS 充电器与线材。' : ''}完成后需重启。`;
    $('confirmBtn').textContent = stock ? '恢复原厂' : '确认写入';
  }
  $('confirmDialog').showModal();
}
function closeDialog() {
  pending = null;
  $('confirmDialog').close();
}
async function applyAction() {
  const action = pending;
  closeDialog();
  if (!isAllowed(action)) { toast('状态已变化，请刷新后重试'); return; }
  actionBusy = true;
  clearTimeout(pollTimer);
  renderControls();
  const command = action.type === 'enable' ? `sh '${MODDIR}/bin/patch_mode.sh' enable`
    : action.type === 'recheck' ? `sh '${MODDIR}/bin/patch_mode.sh' recheck`
    : action.type === 'promote' ? `sh '${MODDIR}/bin/promote_full.sh'`
      : `sh '${MODDIR}/bin/${controls.mode === 'patch' ? 'patch_toggle.sh' : 'toggle.sh'}' '${action.target}'`;
  try {
    // No timeout on writes. The UI stays locked until the native command exits.
    const result = await exec(command);
    const output = `${result.stdout}${result.stderr ? `\n${result.stderr}` : ''}`.trim();
    showLog(result.errno === 0 ? '操作完成' : '操作失败', output);
    if (result.errno === 0) {
      if (action.type === 'profile') needsReboot = true;
      toast(action.type === 'profile' ? '已写入，请重启' : '模式设置完成');
    } else toast('操作失败，请查看日志');
  } catch (error) {
    showLog('执行失败', String(error));
    toast('执行失败');
  } finally {
    actionBusy = false;
    await refreshAll();
    await refreshDtbo();
    scheduleTelemetry();
  }
}
async function loadLog() {
  if (actionBusy || logBusy) return;
  logBusy = true;
  clearTimeout(pollTimer);
  renderControls();
  try {
    const result = await readCommand('charging_log.sh', 15000);
    if (result.errno !== 0) throw new Error(result.stderr || '日志不可读');
    // dmesg is historical. Never use it to replace current live measurements.
    showLog('充电日志 · 历史记录', result.stdout);
  } catch (error) { showLog('日志读取失败', String(error)); }
  finally { logBusy = false; renderControls(); scheduleTelemetry(); }
}
async function scanNodes() {
  if (actionBusy || scanBusy) return;
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
  if (document.hidden || actionBusy || logBusy) return;
  pollTimer = setTimeout(async () => {
    try { await Promise.allSettled([refreshTelemetry(), ufcsPanel?.refresh()]); }
    finally { if (generation === pollGeneration) scheduleTelemetry(); }
  }, pollDelay);
}
for (const [target, id] of [['stock','stockBtn'],['pps33','pps33Btn'],['pps55','pps55Btn']]) $(id).addEventListener('click', () => ask({type: 'profile', target}));
$('patchModeBtn').addEventListener('click', () => ask({type: 'enable'}));
$('fullModeBtn').addEventListener('click', () => ask({type: 'promote'}));
$('patchCheckBtn').addEventListener('click', () => ask({type: 'recheck'}));
$('cancelBtn').addEventListener('click', closeDialog);
$('confirmBtn').addEventListener('click', applyAction);
$('confirmDialog').addEventListener('cancel', () => { pending = null; });
$('confirmDialog').addEventListener('click', event => {
  if (event.target !== $('confirmDialog')) return;
  const box = event.target.getBoundingClientRect();
  if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) closeDialog();
});
$('refreshBtn').addEventListener('click', refreshAll);
$('verifyBtn').addEventListener('click', () => { void refreshDtbo(); });
$('logBtn').addEventListener('click', loadLog);
$('scanBtn').addEventListener('click', scanNodes);
$('copyLogBtn').addEventListener('click', copyLog);
$('closeLog').addEventListener('click', () => { $('logCard').hidden = true; });
document.addEventListener('visibilitychange', async () => {
  clearTimeout(pollTimer);
  const generation = ++pollGeneration;
  if (!document.hidden) {
    if (logBusy) return;
    if (Date.now() - lastTelemetryAt > 15000) markTelemetryStale('更新中');
    await Promise.allSettled([refreshTelemetry(), ufcsPanel?.refresh()]);
    if (generation === pollGeneration) scheduleTelemetry();
  }
});
ufcsPanel = mountUfcs({busy: () => actionBusy, setBusy: value => {
  actionBusy = value;
  if (value) clearTimeout(pollTimer);
  renderControls();
}, afterAction: () => { renderControls(); scheduleTelemetry(); }});
await refreshAll();
scheduleTelemetry();
void refreshDevice();
void refreshDtbo();
