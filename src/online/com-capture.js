// Captura local inmediata, independiente del emisor comercial y de la conexión.
const DBN = 'okd-com-ingest', STORE = 'jobs';
export const SIZE = 2000;
const pick = (kind, records) => kind === 'sc' ? (records || []).map(r => r.san
  ? { c: r.c || '', cuit: r.cuit || '', comp: 'Saldo Anterior', san: true }
  : { c: r.c || '', cuit: r.cuit || '', comp: r.comp || '', n: r.n || '', d: r.d || '', m: r.m ?? null, ve: r.ve ?? null, s: r.s ?? null, due: r.due || '', q: r.q || '' })
  : (records || []).map(r => ({ c: r.c || '', cuit: r.cuit || '', saldo: r.s ?? null, localidad: r.loc || '' }));
const digest = async text => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))), x => x.toString(16).padStart(2, '0')).join('');
function tx(mode, fn) { return new Promise((ok, ko) => {
  const r = indexedDB.open(DBN, 1);
  r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'hash' }); r.onerror = () => ko(r.error);
  r.onsuccess = () => { const db = r.result, t = db.transaction(STORE, mode), res = fn(t.objectStore(STORE));
    t.oncomplete = () => { db.close(); ok(res && res.result); };
    t.onerror = t.onabort = () => { db.close(); ko(t.error || new Error('No se confirmó el guardado local')); };
  };
}); }
export const ingestStorage = { put: j => tx('readwrite', s => s.put(j)), del: k => tx('readwrite', s => s.delete(k)), keys: () => tx('readonly', s => s.getAllKeys()), get: k => tx('readonly', s => s.get(k)) };
export async function ingestOwner(api) {
  if (typeof api.getSession === 'function') return (await api.getSession())?.userId || null;
  return (await api.me())?.id || null;
}
export function installComCapture(api, { storage = ingestStorage, log = () => {} } = {}) {
  async function capture(kind, payload, notify = true, original = null) {
    const rows = pick(kind, payload?.records), K = kind === 'sc' ? 'SC' : 'CC'; if (!rows.length) return null;
    const owner = await ingestOwner(api), loadedAt = payload?.meta?.loadedAt || new Date().toISOString();
    const contentHash = await digest(K + '|' + JSON.stringify(rows));
    const hash = await digest([owner || 'SIN_IDENTIFICAR', K, loadedAt, payload?.meta?.fileName || '', contentHash].join('|'));
    const orig = typeof Blob !== 'undefined' && original instanceof Blob ? original : null;   // respaldo: el ORIGINAL viaja en la tarea (IndexedDB), no en memoria
    if (!(await storage.get(hash))) await storage.put({ hash, contentHash, owner, kind: K, file: payload?.meta?.fileName, loadedAt, rows, batches: Math.ceil(rows.length / SIZE), next: 1, savedAt: new Date().toISOString(),
      original: orig, originalName: orig ? (orig.name || payload?.meta?.fileName || '') : null, originalType: orig ? (orig.type || '') : null, originalSize: orig ? orig.size : null });
    if (notify && typeof window !== 'undefined') window.dispatchEvent(new Event('okd-com-captured')); return hash;
  }
  if (typeof window !== 'undefined') window.OKD_COM_INGEST = async (kind, payload, original) => {
    try { return await capture(kind, payload, true, original); } catch (e) { log('no-guardado', kind, String(e.message || e)); throw e; }
  };
  return { capture, storage };
}
