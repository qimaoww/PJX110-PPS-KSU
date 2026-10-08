import test from 'node:test';
import assert from 'node:assert/strict';
import {parseKV, number, metric, activeUsbType, telemetry} from '../../webroot/telemetry.js';
import {controlState, modeHint} from '../../webroot/controls.js';

const sample = () => ({schema:'2',state:'ok',status:'Charging',capacity:'63',capacity_unit:'percent',
  vbat_raw:'4200000',vbat_raw_unit:'uV',ibat_raw:'-50000',ibat_raw_unit:'uA',
  temp_raw:'85',temp_raw_unit:'deciC',usb_online:'1',usb_type_raw:'Unknown SDP DCP PD [PD_PPS]',
  usb_v_raw:'9000000',usb_v_raw_unit:'uV',usb_i_raw:'10000',usb_i_raw_unit:'uA',
  charge_full_raw:'6100000',charge_full_raw_unit:'uAh'});
const state = () => ({state:'stock',management_mode:'patch',sha256:'a'.repeat(64),slot_suffix:'_a',
  trusted_slot_available:'1',trusted_slot_conflict:'0',patch_driver_compatible:'1',
  patch_runtime_assets_compatible:'1',dynamic_assets_complete:'1',patch_can_enable:'0',patch_can_promote:'1'});

test('low currents, temperatures and capacities use declared units', () => {
  const t = telemetry(sample());
  assert.equal(t.current, 0.05); assert.equal(t.usbI, 0.01);
  assert.equal(t.temp, 8.5); assert.equal(t.full, 6100);
  assert.equal(t.pack, 8.4); assert.equal(t.powerEstimated, true);
});
test('strict numeric parsing preserves zero and rejects empty/nonfinite data', () => {
  assert.equal(number(''), null); assert.equal(number(null), null);
  assert.equal(number('1e309'), null); assert.equal(number('NaN'), null);
  assert.equal(number('0'), 0); assert.equal(metric({x:'123'}, 'x'), null);
});
test('OPlus mA battery current is distinct from standard uA USB current', () => {
  const t = telemetry({...sample(),ibat_raw:'-2000',ibat_raw_unit:'mA',usb_i_raw:'500000',usb_i_raw_unit:'uA'});
  assert.equal(t.current, 2); assert.equal(t.usbI, 0.5);
});
test('live PPS/UFCS state overrides generic PD and is ignored after unplug', () => {
  for (const [mode, expected] of [['1','PPS'],['2','PPS'],['3','UFCS'],['4','UFCS']]) {
    const d = {...sample(),pps_mode:mode,usb_type_raw:'Unknown [PD] PD_PPS'};
    assert.equal(telemetry(d).proto, expected);
    assert.equal(telemetry({...d,usb_online:'0'}).proto, '未连接');
  }
  assert.equal(telemetry({...sample(),pps_mode:'0',fast_chg_type:'5',usb_type_raw:'[PD] PD_PPS'}).proto, 'PD');
});
test('partial cell measurement is retained instead of replaced with an estimate', () => {
  const d = {...sample(),cell1_raw:'4300',cell1_raw_unit:'cellV'};
  const t = telemetry(d); assert.equal(t.cell1, 4.3); assert.equal(t.cell2, 4.2);
  assert.equal(t.powerEstimated, true);
});
test('independent cells are real measurements', () => {
  const d = {...sample(),cell1_raw:'4300',cell1_raw_unit:'cellV',cell2_raw:'4200000',cell2_raw_unit:'cellV'};
  const t = telemetry(d); assert.equal(t.pack, 8.5); assert.equal(t.powerEstimated, false);
});
test('unplugged supplies cannot expose stale USB power or PPS', () => {
  const t = telemetry({...sample(),usb_online:'0',ac_online:'0',status:'Discharging'});
  assert.equal(t.proto, '未连接'); assert.equal(t.usbV, null);
  assert.equal(t.usbI, null); assert.equal(t.usbPower, null); assert.equal(t.current, -0.05);
});
test('missing online is unknown, not disconnected', () => {
  assert.equal(telemetry({...sample(),usb_online:''}).proto, '未知');
});
test('enum list never mistaken for currently active PPS', () => {
  assert.equal(activeUsbType('Unknown [PD] PD_PPS'), 'PD');
  assert.equal(activeUsbType('Unknown PD PD_PPS'), '');
  assert.equal(telemetry({...sample(),usb_type_raw:'Unknown [PD] PD_PPS'}).proto, 'PD');
});
test('schema mismatch and empty collector are rejected', () => {
  assert.throws(() => telemetry({state:'ok'}));
  assert.throws(() => telemetry({schema:'2',state:'ok'}));
});
test('impossible measurements are hidden, not rendered as giant power figures', () => {
  const t = telemetry({...sample(),ibat_raw:'2650000',ibat_raw_unit:'mA',temp_raw:'5000',usb_v_raw:'50000000'});
  assert.equal(t.current,null); assert.equal(t.power,null); assert.equal(t.temp,null); assert.equal(t.usbV,null);
});
test('KV values cannot pollute prototypes', () => {
  const d = parseKV('__proto__=bad\npath=x=y\nstate=ok');
  assert.equal(Object.getPrototypeOf(d), null); assert.equal(d.path, 'x=y');
});
test('trusted dynamic state permits PPS and one-way promotion', () => {
  const s = controlState(state()); assert.equal(s.canProfile('pps33'), true);
  assert.equal(s.canPromote, true); assert.equal(s.canEnable, false);
});
test('any missing dynamic resource keeps only stock restoration', () => {
  for (const field of ['patch_driver_compatible','patch_runtime_assets_compatible','dynamic_assets_complete']) {
    const s = controlState({...state(),state:'pps33',[field]:'0'});
    assert.equal(s.canProfile('stock'), true); assert.equal(s.canProfile('pps55'), false);
    assert.equal(s.canPromote, false);
  }
});
test('unknown/invalid/conflicting slots and hashes fail closed', () => {
  for (const d of [{},{...state(),trusted_slot_available:'0'},{...state(),trusted_slot_conflict:'1'},
    {...state(),slot_suffix:'_c'},{...state(),sha256:'bad'},{...state(),management_mode:'whatever'}]) {
    const s = controlState(d); assert.equal(s.canProfile('pps33'), false);
    assert.equal(s.canEnable, false); assert.equal(s.canPromote, false);
  }
});
test('full modes without a distinct OTA offer never enable patch and targets are whitelisted', () => {
  for (const mode of ['full_static','full_dynamic']) {
    const s = controlState({...state(),management_mode:mode,patch_can_enable:'1'});
    assert.equal(s.canEnable, false); assert.equal(s.canPromote, false);
    assert.equal(s.canProfile('stock;anything'), false);
  }
});
test('manual recheck is available only on Patch Mode stock with a trusted runtime', () => {
  const base={...state(),patch_can_recheck:'1'};
  assert.equal(controlState(base).canRecheck,true);
  assert.equal(controlState({...base,dynamic_assets_complete:'0'}).canRecheck,true);
  for(const patch of [{state:'pps33'},{management_mode:'full_dynamic'},{management_mode:'full_static'},
    {patch_runtime_assets_compatible:'0'},{trusted_slot_conflict:'1'},{patch_driver_compatible:'0'}]) {
    assert.equal(controlState({...base,...patch}).canRecheck,false);
  }
});
test('missing static image set disables PPS without automatically falling back to Patch Mode', () => {
  const s=controlState({...state(),management_mode:'full_static',static_assets_complete:'0',static_stock_available:'0'});
  assert.equal(s.canProfile('pps33'),false);assert.equal(s.canProfile('pps55'),false);
  assert.equal(s.canEnable,false);assert.equal(s.canRecheck,false);
  const restore=controlState({...state(),state:'pps55',management_mode:'full_static',static_assets_complete:'0',static_stock_available:'1'});
  assert.equal(restore.canProfile('stock'),true);assert.equal(restore.canProfile('pps33'),false);
  const complete=controlState({...state(),management_mode:'full_static',static_assets_complete:'1',static_stock_available:'1'});
  assert.equal(complete.canProfile('pps33'),true);
});
test('only an explicit trusted OTA stock offer allows manual patch enablement', () => {
  const d={...state(),management_mode:'full_static',static_assets_complete:'0',static_stock_available:'0',
    ota_patch_available:'1',patch_can_enable:'1'};
  const s=controlState(d);
  assert.equal(s.mode,'full_static');assert.equal(s.canEnable,true);
  assert.equal(s.canProfile('pps33'),false);assert.equal(s.canRecheck,false);
  assert.match(modeHint(s),/重装模块.*补丁模式/);
  for(const invalid of [{state:'pps33'},{state:'unknown'},{static_assets_complete:'1'},
    {management_mode:'full_dynamic'},{ota_patch_available:'0'},{patch_can_enable:'0'},
    {patch_runtime_assets_compatible:'0'},{patch_driver_compatible:'0'},
    {trusted_slot_available:'0'},{trusted_slot_conflict:'1'},{sha256:'bad'}]) {
    assert.equal(controlState({...d,...invalid}).canEnable,false,JSON.stringify(invalid));
  }
});
