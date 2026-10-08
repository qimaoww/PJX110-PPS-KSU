const modes = new Set(['full_static', 'full_dynamic', 'patch', 'none', 'error']);
const profiles = new Set(['stock', 'pps33', 'pps55']);
export const profileName = value => ({stock: '原厂', pps33: '33W PPS', pps55: '55W PPS'}[value] || '未知');
export const modeName = value => ({full_static: '全分区 · 内置', full_dynamic: '全分区 · 动态', patch: '补丁模式', none: '未启用', error: '不可写入'}[value] || '不可写入');

// UI hints are never write authority: all writers still re-read the partition,
// validate trusted slot sources, exact hashes and AVB immediately before dd.
export function controlState(data) {
  const valid = modes.has(data.management_mode) && /^[0-9a-f]{64}$/.test(data.sha256 || '')
    && ['_a', '_b'].includes(data.slot_suffix)
    && data.trusted_slot_available === '1' && data.trusted_slot_conflict === '0';
  const mode = valid ? data.management_mode : 'error';
  const profile = profiles.has(data.state) ? data.state : 'unknown';
  const dynamic = mode === 'patch' || mode === 'full_dynamic';
  const runtimeOk = data.patch_driver_compatible === '1' && data.patch_runtime_assets_compatible === '1';
  const dynamicOk = runtimeOk && data.dynamic_assets_complete === '1';
  const staticComplete = data.static_assets_complete === '1';
  const staticStock = data.static_stock_available === '1';
  const otaPatch = mode === 'full_static' && profile === 'stock' && !staticComplete
    && data.ota_patch_available === '1';
  return {mode, profile, valid, dynamicOk, staticComplete, staticStock, otaPatch,
    canEnable: (mode === 'none' || otaPatch) && data.patch_can_enable === '1' && dynamicOk,
    canPromote: mode === 'patch' && data.patch_can_promote === '1' && dynamicOk,
    canRecheck: mode === 'patch' && profile === 'stock' && data.patch_can_recheck === '1' && runtimeOk,
    canProfile(target) {
      return profiles.has(target) && profiles.has(profile) && target !== profile
        && ['full_static', 'full_dynamic', 'patch'].includes(mode)
        && (!dynamic || target === 'stock' || dynamicOk)
        && (mode !== 'full_static' || (target === 'stock' ? staticStock : staticComplete));
    }};
}

export function modeHint(state) {
  if (!state.valid || state.mode === 'error') return '状态校验未通过，已禁止写入。';
  if (state.mode === 'none') return state.canEnable ? '当前版本需先检测并启用补丁模式。' : '驱动或补丁资源不兼容。';
  if (state.mode === 'full_static' && !state.staticComplete) return state.canEnable
    ? '镜像集缺失：重装模块，或检测后使用补丁模式。' : '当前版本镜像集缺失，请重装模块提取。';
  if (['patch', 'full_dynamic'].includes(state.mode) && !state.dynamicOk) return state.canRecheck ? '原厂已恢复；可在详情中重检补丁。' : '动态资源异常，仅可恢复原厂。';
  if (state.mode === 'patch') return '可手动切换到全分区；同一版本不可返回。';
  return '';
}
