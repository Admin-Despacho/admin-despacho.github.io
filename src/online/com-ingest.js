import { SIZE, ingestStorage, ingestOwner, installComCapture } from './com-capture.js';
// Emisor opcional: su ausencia no impide conservar cargas ni usar el Constructor.
const hex = buf => Array.from(new Uint8Array(buf), x => x.toString(16).padStart(2, '0')).join('');
// Respaldo privado del ORIGINAL (A-09): solo si está ENCENDIDO. Falla → la tarea queda PENDIENTE con su original (nunca se borra).
async function backupOriginal(api, job, storage) {
  if (!job.original || job.sourceFileId || typeof api.comRegisterSource !== 'function') return;
  const cfg = await api.comConfig(); const st = (cfg && cfg.settings) || {};
  if (!st.source_backup_enabled) return;
  if (job.originalSize > (st.source_max_mb || 15) * 1048576) throw new Error('FILE_TOO_LARGE: el original supera ' + (st.source_max_mb || 15) + ' MB');
  const sha = hex(await crypto.subtle.digest('SHA-256', await job.original.arrayBuffer()));
  const ext = String(job.originalName || '').toLowerCase().replace(/^.*\./, ''), path = job.kind + '/' + sha + '.' + ext;
  await api.comUploadSource(path, job.original, job.originalType || 'application/octet-stream');
  const reg = await api.comRegisterSource(job.kind, sha, job.originalSize, job.originalName, job.originalType, path);
  job.sourceFileId = reg.id; job.sourceVersion = reg.version; job.sourceSha = sha; await storage.put(job);
}
export function installComIngest(api, { log = () => {}, storage = ingestStorage } = {}) {
  if (!api || typeof api.comIngest !== 'function') return null;
  const { capture } = installComCapture(api, { storage, log });
  let running = false, again = false;
  async function runJob(job) {
    if (!job.owner || await ingestOwner(api) !== job.owner) throw new Error('OWNER_REVIEW_REQUIRED: pendiente conservado para su usuario original');
    await backupOriginal(api, job, storage);
    for (let b = job.next; b <= job.batches; b++) {
      if (await ingestOwner(api) !== job.owner) throw new Error('OWNER_REVIEW_REQUIRED');
      const ack = await api.comIngest(job.kind, { hash: job.hash, content_hash: job.contentHash, owner_id: job.owner, file_name: job.file, loaded_at: job.loadedAt, batch: b, batches: job.batches, source_file_id: job.sourceFileId || null }, job.rows.slice((b - 1) * SIZE, b * SIZE));
      if (!ack || (b === job.batches && ack.status !== 'OK') || (ack.batch != null && ack.batch !== b)) throw new Error('ACK_REQUIRED: servidor no confirmó el lote');
      job.next = b + 1; job.lastError = null; if (b < job.batches) await storage.put(job);
    }
    await storage.del(job.hash); log('ok', job.kind, job.file);
  }
  async function flush() {
    if (running) { again = true; return; } running = true;
    try { do { again = false;
      for (const h of await storage.keys()) {
        const job = await storage.get(h); if (!job) continue;
        try { await runJob(job); }
        catch (e) {
          const msg = String(e?.message || e); job.lastError = msg; job.attempts = (job.attempts || 0) + 1;
          await storage.put(job); log('pendiente', job.kind, msg);
          if (/OWNER_REVIEW_REQUIRED/.test(msg)) continue;
          try { await api.comIngestError(job.kind, { hash: job.hash, file_name: job.file, loaded_at: job.loadedAt }, msg); } catch (_) {}
          again = false; break;
        }
      }
    } while (again); } finally { running = false; }
  }
  async function ingest(kind, payload) { await capture(kind, payload, false); await flush(); }
  if (typeof window !== 'undefined') {
    window.addEventListener('okd-com-captured', () => { flush().catch(e => log('pendiente', '', String(e))); });
    window.addEventListener('online', () => { flush().catch(e => log('pendiente', '', String(e))); });
    setTimeout(() => { flush().catch(e => log('pendiente', '', String(e))); }, 3000);
    setInterval(() => { if(navigator.onLine)flush().catch(e=>log('pendiente','',String(e))); },30000);
  }
  return { ingest, flush, storage };
}
