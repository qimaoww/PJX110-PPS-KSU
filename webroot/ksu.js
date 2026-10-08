let callbackCounter = 0;

function unique(prefix) {
  return `${prefix}_${Date.now()}_${callbackCounter++}`;
}

function run(command, options, timeoutMs) {
  return new Promise((resolve, reject) => {
    const cb = unique("exec");
    let timer = null;
    window[cb] = (errno, stdout, stderr) => {
      if (timer !== null) clearTimeout(timer);
      delete window[cb];
      const code = typeof errno === 'number' || (typeof errno === 'string' && /^-?\d+$/.test(errno)) ? Number(errno) : NaN;
      resolve({ errno: code, stdout: stdout || '', stderr: stderr || '' });
    };
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        // A timeout does NOT cancel the native command. Use only for reads.
        // Keep a no-op callback briefly for a delayed native completion.
        window[cb] = () => { delete window[cb]; };
        setTimeout(() => { delete window[cb]; }, 60000);
        reject(new Error('读取超时，请刷新'));
      }, timeoutMs);
    }
    try {
      ksu.exec(command, JSON.stringify(options), cb);
    } catch (e) {
      if (timer !== null) clearTimeout(timer);
      delete window[cb];
      reject(e);
    }
  });
}

// Mutations have no timeout: never release the UI lock while a write may run.
export function exec(command, options = {}) {
  return run(command, options, 0);
}

export function execRead(command, timeoutMs = 8000) {
  return run(command, {}, timeoutMs);
}

export function toast(message) {
  try { ksu.toast(String(message)); } catch (_) {}
}

export function moduleInfo() {
  try { return ksu.moduleInfo(); } catch (_) { return "PJX110_PPS_KSU"; }
}
