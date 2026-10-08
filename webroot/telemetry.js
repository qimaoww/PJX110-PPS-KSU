export function parseKV(text = '') {
  const out = Object.create(null);
  for (const line of String(text).split(/\r?\n/)) {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1).trim();
  }
  return out;
}
export function number(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const text = String(value).trim();
  if (!/^-?\d+(?:\.\d+)?$/.test(text)) return null;
  const result = Number(text);
  return Number.isFinite(result) ? result : null;
}
export function metric(data, key) {
  const raw = number(data[key]);
  if (raw === null) return null;
  const unit = data[`${key}_unit`];
  const scales = {uV: 1e6, mV: 1e3, uA: 1e6, mA: 1e3, uAh: 1e3, mAh: 1, deciC: 10, percent: 1, count: 1};
  if (unit === 'cellV') {
    const volts = raw >= 1e6 ? raw / 1e6 : raw / 1e3;
    return volts >= 2 && volts <= 5 ? volts : null;
  }
  return Object.prototype.hasOwnProperty.call(scales, unit) ? raw / scales[unit] : null;
}
export function activeUsbType(raw = '') {
  const text = String(raw).trim();
  const match = text.match(/\[([^\]]+)\]/);
  if (match) return match[1].trim();
  return text && !/\s/.test(text) ? text : '';
}
export function protocol(active, real, online, vendor = {}) {
  if (online === false) return ['未连接', 'online'];
  if (online === null) return ['未知', 'online 不可读'];
  const pps = number(vendor.pps_mode), fast = number(vendor.fast_chg_type);
  if (pps === 1 || pps === 2) return ['PPS', `ppschg_ing=${pps}`];
  if (pps === 3 || pps === 4) return ['UFCS', `ppschg_ing=${pps}`];
  if (number(vendor.vooc_active) === 1) return [fast === 2 ? 'SUPERVOOC' : 'VOOC', 'voocchg_ing'];
  if ([1, 2, 3, 4].includes(fast)) return [{1:'VOOC',2:'SUPERVOOC',3:'PD',4:'QC'}[fast], 'fast_chg_type'];
  const kind = String(active || real || '').toUpperCase();
  const source = active ? 'usb_type' : real ? 'real_type' : 'online';
  if (kind === 'PD_PPS' || kind === 'PPS') return ['PPS', source];
  if (['PD', 'PD_DRP', 'USB_PD'].includes(kind)) return ['PD', source];
  if (kind === 'UFCS') return ['UFCS', source];
  if (kind.includes('SUPERVOOC') || kind === 'SVOOC') return ['SUPERVOOC', source];
  if (kind === 'VOOC') return ['VOOC', source];
  if (kind.startsWith('QC') || kind.startsWith('HVDCP')) return ['QC', source];
  if (['DCP', 'CDP', 'SDP'].includes(kind)) return [kind === 'SDP' ? 'USB' : kind, source];
  return [kind && kind !== 'UNKNOWN' ? kind : '未识别', source];
}
export function telemetry(data) {
  if (data.schema !== '2' || data.state !== 'ok') throw new Error(data.message || '充电数据不完整');
  const status = String(data.status || '').trim().toLowerCase();
  const usbOnline = number(data.usb_online), acOnline = number(data.ac_online);
  const online = usbOnline === 1 || acOnline === 1 ? true
    : usbOnline === 0 || acOnline === 0 ? false : null;
  const charging = status === 'charging', discharging = status === 'discharging';
  const bounded = (value, low, high) => value !== null && value >= low && value <= high ? value : null;
  const rawCurrent = bounded(metric(data, 'ibat_raw'), -30, 30);
  const current = rawCurrent === null ? null : charging ? Math.abs(rawCurrent)
    : discharging ? -Math.abs(rawCurrent) : rawCurrent;
  const voltage = metric(data, 'vbat_raw');
  if (voltage === null && rawCurrent === null && status === '' && metric(data, 'capacity') === null) {
    throw new Error('电池节点不可读');
  }
  const plausibleCell = voltage !== null && voltage >= 2 && voltage <= 5 ? voltage : null;
  const validCell = value => value !== null && value >= 2 && value <= 5 ? value : null;
  const cell1Direct = validCell(metric(data, 'cell1_raw')), cell2Direct = validCell(metric(data, 'cell2_raw'));
  const direct = cell1Direct !== null && cell2Direct !== null;
  const cell1 = cell1Direct ?? plausibleCell, cell2 = cell2Direct ?? plausibleCell;
  const pack = cell1 !== null && cell2 !== null ? cell1 + cell2 : null;
  const power = pack !== null && current !== null ? Math.abs(pack * current) : null;
  const usbV = online === false ? null : bounded(metric(data, 'usb_v_raw'), 0, 30);
  const usbCurrent = online === false ? null : bounded(metric(data, 'usb_i_raw'), 0, 20);
  const usbI = usbCurrent !== null && !(charging && current !== null && Math.abs(current) > 0.05 && usbCurrent === 0)
    ? Math.abs(usbCurrent) : null;
  const active = activeUsbType(data.usb_type_raw);
  const [proto, protoSource] = protocol(active, data.usb_real_type, online, data);
  const capacityValue = metric(data, 'capacity');
  const capacity = capacityValue !== null && capacityValue >= 0 && capacityValue <= 100 ? capacityValue : null;
  const label = charging ? '充电中' : status === 'full' ? '已充满'
    : status === 'not charging' ? '暂停充电' : discharging ? (online ? '未充电' : '放电中') : '未知';
  return {capacity, current, cell1, cell2, pack, power, powerEstimated: !direct,
    temp: bounded(metric(data, 'temp_raw'), -40, 100), usbV, usbI,
    usbPower: usbV !== null && usbI !== null ? Math.abs(usbV * usbI) : null,
    icl: metric(data, 'usb_icl_raw'), active, proto, protoSource, label,
    tone: charging || status === 'full' ? 'good' : status === 'not charging' ? 'warn' : '',
    cellSource: direct ? data.cell2_raw_source?.endsWith('/voltage_min') ? '实测 · Cell 最大/最小' : '实测'
      : cell1 !== null || cell2 !== null ? '含估算' : '不可读',
    full: metric(data, 'charge_full_raw'), design: metric(data, 'charge_full_design_raw')};
}
