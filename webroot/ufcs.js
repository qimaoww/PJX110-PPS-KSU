import {exec, execRead} from './ksu.js';
import {parseKV} from './telemetry.js';

const script = "sh '/data/adb/modules/PJX110_PPS_KSU/bin/ufcs_control.sh'";
export function ufcsState(data) {
  const valid = data.schema === '1' && data.state === 'ok'
    && ['0','1'].includes(data.active) && /^\d{1,10}$/.test(data.value || '')
    && ['0','1'].includes(data.effective_disabled)
    && ['0','1'].includes(data.boot_apply) && ['0','1'].includes(data.configured_disable)
    && !(data.boot_apply === '1' && data.configured_disable !== '1');
  const overridden = valid && data.active === '1' && Number(data.value) > 0;
  const blocked = valid && data.effective_disabled === '1';
  const consistent = valid && (data.active === '0' || overridden === blocked);
  return {valid:consistent, canSet:consistent && data.can_set === '1', overridden, blocked,
    bootApply:consistent && data.boot_apply === '1', configValid:data.config_valid === '1'};
}

export function mountUfcs({busy, setBusy, afterAction}) {
  const $ = id => document.getElementById(id);
  function set(id, property, value) {
    const node = $(id);
    if (node[property] !== value) node[property] = value;
  }
  let data = {}, state = ufcsState({}), flight = null, changing = false, notice = '', revision = 0;
  function render() {
    const waiting = changing || busy();
    set('ufcsDisable', 'checked', state.overridden);
    set('ufcsBoot', 'checked', state.bootApply);
    set('ufcsDisable', 'disabled', waiting || !state.canSet);
    set('ufcsBoot', 'disabled', waiting || !state.canSet || (!state.overridden && !state.bootApply));
    set('ufcsStatus', 'textContent', changing ? '应用中…' : !state.valid ? '不可用'
      : state.overridden ? '已关闭' : state.blocked ? '系统已禁用' : '跟随系统');
    set('ufcsStatus', 'className', `chip${!state.valid ? ' bad' : state.overridden ? ' good' : ''}`);
    set('ufcsHint', 'textContent', notice || (!state.valid ? (data.message || '接口不可用，请刷新检查。')
      : !state.configValid ? '设置读取异常，请重新设置。'
      : state.bootApply && !state.overridden ? '当前跟随系统，下次开机自动关闭 UFCS。'
      : state.bootApply ? '重启后自动关闭 UFCS，不刷写分区。'
      : '立即生效，不刷写分区。'));
  }
  async function refresh(keepNotice = false) {
    if (changing || busy()) return;
    if (flight) return flight;
    if (!keepNotice) notice = '';
    const currentRevision = revision;
    flight = (async () => {
      try {
        const result = await execRead("sh '/data/adb/modules/PJX110_PPS_KSU/bin/web_read.sh' ufcs_control.sh status");
        if (currentRevision !== revision || changing) return;
        data = parseKV(result.stdout);
        if (result.errno !== 0) throw new Error(data.message || '接口读取失败');
        const next = ufcsState(data);
        if (!next.valid) throw new Error(data.message || '接口状态异常，请刷新检查。');
        state = next;
      } catch (error) {
        if (currentRevision === revision && !changing) {
          data = {message:String(error.message || error)};
          // Preserve the last displayed settings, while clearly marking the
          // current interface unreadable and preventing writes until reread.
          state = {...state, valid:false, canSet:false};
        }
      }
      finally { flight = null; render(); }
    })();
    render();
    return flight;
  }
  async function change(event) {
    const desired = $('ufcsDisable').checked ? 1 : 0;
    const automatic = desired && $('ufcsBoot').checked ? 1 : 0;
    if (!state.canSet || changing || busy()) { render(); return; }
    revision++;
    changing = true; notice = ''; setBusy(true); render();
    try {
      // Fixed binary choices only. Writes have no read timeout.
      const result = await exec(`${script} set ${desired} ${automatic}`);
      const output = parseKV(result.stdout);
      if (result.errno !== 0 || output.result !== 'applied') {
        throw new Error(output.message || '应用失败，请刷新检查');
      }
      data = output; state = ufcsState(data);
      if (!state.valid || state.overridden !== Boolean(desired) || state.bootApply !== Boolean(automatic)) {
        throw new Error('状态已变化，以实际接口为准');
      }
      notice = desired ? (automatic ? '已关闭 UFCS，重启后自动应用。' : '已关闭 UFCS，本次开机有效。') : '已恢复系统默认。';
    } catch (error) { notice = String(error.message || error); }
    finally {
      changing = false; setBusy(false);
      await flight;
      await refresh(true);
      afterAction();
    }
  }
  $('ufcsDisable').addEventListener('change', change);
  $('ufcsBoot').addEventListener('change', change);
  render();
  return {refresh, render};
}
