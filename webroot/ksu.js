let callbackCounter = 0;

function unique(prefix) {
  return `${prefix}_${Date.now()}_${callbackCounter++}`;
}

export function exec(command, options = {}) {
  return new Promise((resolve, reject) => {
    const cb = unique("exec");
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno, stdout, stderr });
    };
    try {
      ksu.exec(command, JSON.stringify(options), cb);
    } catch (e) {
      delete window[cb];
      reject(e);
    }
  });
}

export function toast(message) {
  try { ksu.toast(String(message)); } catch (_) {}
}

export function moduleInfo() {
  try { return ksu.moduleInfo(); } catch (_) { return "PJX110_PPS_KSU"; }
}
