const modes = new Set(['stock_idle', 'restore_only', 'full_static', 'full_dynamic', 'patch', 'none', 'error']);
const profiles = new Set(['stock', 'pps33', 'pps55']);
export const profileName = value => ({stock: '原厂', pps33: '33W PPS', pps55: '55W PPS'}[value] || '未知');
export const modeName = value => ({stock_idle: '未选择', restore_only: '未选择 · 仅可恢复原厂', full_static: '全分区 · 内置', full_dynamic: '全分区 · 动态', patch: '补丁模式', none: '未启用', error: '不可写入'}[value] || '不可写入');

// UI hints are never write authority: all writers still re-read the partition,
// validate trusted slot sources, exact hashes and AVB immediately before dd.
export function controlState(data) {
  const valid = modes.has(data.management_mode) && /^[0-9a-f]{64}$/.test(data.sha256 || '')
    && ['_a', '_b'].includes(data.slot_suffix)
    && data.trusted_slot_available === '1' && data.trusted_slot_conflict === '0';
  const stockIdle = data.management_mode === 'stock_idle';
  const mode = valid && (!stockIdle || (data.state === 'stock' && data.stock_sha === data.sha256)) ? data.management_mode : 'error';
  const profile = profiles.has(data.state) ? data.state : 'unknown';
  const dynamic = mode === 'patch' || mode === 'full_dynamic';
  const driverOk = data.patch_driver_compatible === '1';
  const toolsOk = data.patch_runtime_assets_compatible === '1';
  const runtimeOk = driverOk && toolsOk;
  const dynamicOk = runtimeOk && data.dynamic_assets_complete === '1';
  const staticComplete = data.static_assets_complete === '1';
  const staticStock = data.static_stock_available === '1';
  const exactStock = valid && profile === 'stock' && data.stock_sha === data.sha256;
  const bundled = mode === 'full_static' || mode === 'stock_idle';
  const otaPatch = bundled && exactStock && !staticComplete
    && data.ota_patch_available === '1';
  const fullStockPatch = exactStock && data.full_stock_patch_available === '1'
    && ((bundled && staticStock && staticComplete) || mode === 'full_dynamic');
  return {mode, profile, valid, driverOk, toolsOk, dynamicOk, staticComplete, staticStock, otaPatch, fullStockPatch,
    canSelectStatic: mode === 'stock_idle' && exactStock && staticStock && staticComplete && data.static_full_selectable === '1',
    canEnable: ((mode === 'none' && (profile === 'unknown' || exactStock)) || otaPatch || fullStockPatch) && data.patch_can_enable === '1' && dynamicOk,
    canPromote: mode === 'patch' && exactStock && data.patch_can_promote === '1' && dynamicOk,
    canRecheck: mode === 'patch' && profile === 'stock' && data.patch_can_recheck === '1' && runtimeOk,
    canProfile(target) {
      if (!profiles.has(target) || !profiles.has(profile) || target === profile) return false;
      if (mode === 'restore_only') return target === 'stock' && staticStock;
      if (mode === 'full_static') return target === 'stock' ? staticStock : staticComplete;
      return dynamic && (target === 'stock' || dynamicOk);
    }};
}

export function modeHint(state) {
  if (!state.valid || state.mode === 'error') return '状态校验未通过，已禁止写入。';
  if (state.mode === 'restore_only') return state.staticStock ? '尚未选择模式。请先恢复原厂，再选择模式。' : '原厂镜像不可用，请重装模块提取对应镜像。';
  if (state.mode === 'none') {
    if (state.canEnable) return '当前版本需先检测并启用补丁模式。';
    if (!state.toolsOk) return '补丁工具或模板校验失败，请重新安装模块。';
    if (!state.driverOk) return '未检测到受支持的 PPS 驱动，不能启用补丁。';
    return '当前 DTBO 不符合补丁启用条件。';
  }
  if (['stock_idle','full_static'].includes(state.mode) && !state.staticComplete) return state.canEnable
    ? '镜像集缺失：重装模块，或检测后使用补丁模式。' : '当前版本镜像集缺失，请重装模块提取。';
  if (['patch', 'full_dynamic'].includes(state.mode) && !state.dynamicOk) return state.canRecheck ? '原厂已恢复；可在详情中重检补丁。' : '动态资源异常，仅可恢复原厂。';
  if (state.profile === 'pps33' || state.profile === 'pps55') return '切换管理模式前，请先恢复原厂 DTBO。';
  if (state.mode === 'stock_idle' && state.canEnable && state.canSelectStatic) return '先选模式，再选 33W 或 55W。';
  if (state.mode === 'stock_idle' && state.canSelectStatic) return '内置全分区可用；补丁模式未通过校验。';
  if (state.canEnable || state.canPromote) return '当前为原厂 DTBO，可手动切换管理模式。';
  if (!state.toolsOk) return '补丁工具或模板校验失败，请重装模块。';
  if (!state.driverOk) return '未检测到受支持的 PPS 驱动，不能切换模式。';
  return '原厂镜像集或槽位登记未通过校验，不能切换模式。';
}
