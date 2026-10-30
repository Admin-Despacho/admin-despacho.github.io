// Comunicaciones · registro de adjuntos validado en el SERVIDOR e IDEMPOTENTE (almacenamiento y base SIMULADOS con las reglas del SQL).
import { describe, it, expect } from 'vitest';
import { handle } from '../../supabase/functions/comm-attachments/handler.js';
import { dispatch } from '../../supabase/functions/comm-dispatcher/handler.js';
import { MemoryCommsStore } from '../../supabase/functions/_shared/comms-memory-store.js';
import { zonedToUtc } from '../../supabase/functions/_shared/comms-core.js';

const MID = '11111111-2222-3333-4444-555555555555', K = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9, 9, 9, 9]), MZ = new Uint8Array([0x4d, 0x5a, 0x90, 0, 3, 0, 0, 0]);
const PATH_PNG = 'messages/' + MID + '/' + K + '.png', PATH_PDF = 'messages/' + MID + '/' + K + '.pdf';
// base simulada con las reglas de comm_register_attachment_srv: idempotente por ruta (mismo comunicado, hash y tamaño)
function world({ registeredLookup, rpcBehaviour } = {}) {
  const storage = new Map(), rows = new Map(), removed = [], calls = [];
  const userClient = () => ({ rpc: async () => ({ data: true, error: null }), auth: { getUser: async () => ({ data: { user: { id: 'u-autor' } } }) } });
  const serviceClient = () => ({
    storage: { from: () => ({ download: async p => storage.has(p) ? { data: new Blob([storage.get(p)]), error: null } : { data: null, error: { message: 'not found' } },
      remove: async ps => { ps.forEach(p => { removed.push(p); storage.delete(p); }); return {}; } }) },
    rpc: async (fn, a) => { calls.push(fn);
      if (fn === 'comm_attachment_registered') return registeredLookup ? registeredLookup(a.p_path, rows) : { data: rows.has(a.p_path), error: null };
      if (rpcBehaviour) { const r = await rpcBehaviour(a, rows); if (r) return r; }
      const ex = rows.get(a.p_path);
      if (ex) return ex.sha256 === a.p_sha && ex.size_bytes === a.p_size ? { data: ex, error: null } : { data: null, error: { message: 'RUTA_YA_REGISTRADA: esa ruta ya corresponde a otro adjunto', code: '22023' } };
      const row = { id: 'att-' + (rows.size + 1), message_id: a.p_message, storage_path: a.p_path, file_name: a.p_name, mime: a.p_mime, size_bytes: a.p_size, sha256: a.p_sha };
      rows.set(a.p_path, row); return { data: row, error: null }; } });
  return { storage, rows, removed, calls, deps: { userClient, serviceClient } };
}
const req = body => new Request('https://f/comm-attachments', { method: 'POST', headers: { Authorization: 'Bearer x' }, body: JSON.stringify(body) });
const body = path => ({ message_id: MID, path, file_name: 'infografia.png' });

describe('Adjuntos validados por el servidor (idempotentes)', () => {
  it('AT-01 (Codex) bytes MZ declarados PDF: rechazado; se borra SOLO porque la base confirma que no está registrado', async () => {
    const w = world(); w.storage.set(PATH_PDF, MZ); const r = await handle(req(body(PATH_PDF)), w.deps);
    expect((await r.json()).error).toBe('CONTENIDO_NO_PERMITIDO'); expect(w.removed).toEqual([PATH_PDF]); expect(w.rows.size).toBe(0);
  });
  it('AT-02 se registra con tamaño, tipo y hash calculados EN EL SERVIDOR', async () => {
    const w = world(); w.storage.set(PATH_PNG, PNG); const r = await handle(req({ ...body(PATH_PNG), mime: 'application/pdf', size: 1, sha256: 'f'.repeat(64) }), w.deps);
    expect(r.status).toBe(200); const row = w.rows.get(PATH_PNG);
    expect(row).toMatchObject({ mime: 'image/png', size_bytes: PNG.length }); expect(row.sha256).toMatch(/^[0-9a-f]{64}$/); expect(row.sha256).not.toBe('f'.repeat(64));
  });
  it('AT-07 (Codex) REPETIR la misma solicitud: devuelve el adjunto existente; no duplica ni BORRA el archivo', async () => {
    const w = world(); w.storage.set(PATH_PNG, PNG);
    const a = await (await handle(req(body(PATH_PNG)), w.deps)).json(), b = await handle(req(body(PATH_PNG)), w.deps);
    expect(b.status).toBe(200); expect((await b.json()).attachment.id).toBe(a.attachment.id);
    expect(w.rows.size).toBe(1); expect(w.removed).toEqual([]); expect(w.storage.has(PATH_PNG)).toBe(true);
  });
  it('AT-07b (Codex, SQL anterior) la repetición choca con la restricción única (23505): el archivo YA registrado NO se borra', async () => {
    let first = true;
    const w = world({ rpcBehaviour: async (a, rows) => { if (first) { first = false; return null; }
      return { data: null, error: { message: 'duplicate key value violates unique constraint "comm_attachments_storage_path_key"', code: '23505' } }; } });
    w.storage.set(PATH_PNG, PNG);
    expect((await handle(req(body(PATH_PNG)), w.deps)).status).toBe(200);
    await handle(req(body(PATH_PNG)), w.deps);
    expect(w.removed).toEqual([]); expect(w.storage.has(PATH_PNG)).toBe(true); expect(w.rows.size).toBe(1);
  });
  it('AT-08 respuesta PERDIDA después de registrar (corte): RESULTADO_INCIERTO, el archivo se CONSERVA; al repetir devuelve el existente', async () => {
    let cut = true;
    const w = world({ rpcBehaviour: async (a, rows) => { if (!cut) return null;
      cut = false; rows.set(a.p_path, { id: 'att-1', message_id: a.p_message, storage_path: a.p_path, file_name: a.p_name, mime: a.p_mime, size_bytes: a.p_size, sha256: a.p_sha });
      throw new TypeError('fetch failed'); } });   // la base REGISTRÓ, pero la respuesta no llegó
    w.storage.set(PATH_PNG, PNG);
    const r1 = await handle(req(body(PATH_PNG)), w.deps);
    expect(r1.status).toBe(503); expect((await r1.json()).error).toBe('RESULTADO_INCIERTO'); expect(w.removed).toEqual([]);
    const r2 = await handle(req(body(PATH_PNG)), w.deps);
    expect(r2.status).toBe(200); expect((await r2.json()).attachment.id).toBe('att-1'); expect(w.rows.size).toBe(1);
  });
  it('AT-09 error DEFINITIVO de la base (límite superado o ruta de otro adjunto): se informa y NO se borra en el momento', async () => {
    const w = world({ rpcBehaviour: async () => ({ data: null, error: { message: 'ADJUNTOS_MUY_GRANDES: el máximo es 15 MB por comunicado', code: '22023' } }) });
    w.storage.set(PATH_PNG, PNG); const r = await handle(req(body(PATH_PNG)), w.deps);
    expect((await r.json()).error).toBe('ADJUNTOS_MUY_GRANDES'); expect(w.removed).toEqual([]);
  });
  it('AT-10 contenido inválido pero la consulta de registro FALLA o dice que está registrado: el archivo se CONSERVA', async () => {
    for (const look of [async () => ({ data: null, error: { message: 'fetch failed' } }), async () => ({ data: true, error: null })]) {
      const w = world({ registeredLookup: look }); w.storage.set(PATH_PDF, MZ); await handle(req(body(PATH_PDF)), w.deps); expect(w.removed).toEqual([]);
    }
  });
  it('AT-11 tras repetición y respuesta perdida, el archivo SIGUE descargándose y se ENVÍA después (despachador)', async () => {
    let cut = true;
    const w = world({ rpcBehaviour: async (a, rows) => { if (!cut) return null; cut = false; rows.set(a.p_path, { id: 'att-1', message_id: a.p_message, storage_path: a.p_path, file_name: a.p_name, mime: a.p_mime, size_bytes: a.p_size, sha256: a.p_sha }); throw new TypeError('fetch failed'); } });
    w.storage.set(PATH_PNG, PNG);
    await handle(req(body(PATH_PNG)), w.deps); await handle(req(body(PATH_PNG)), w.deps); await handle(req(body(PATH_PNG)), w.deps);
    const dl = await w.deps.serviceClient().storage.from('comm-attachments').download(PATH_PNG); expect(new Uint8Array(await dl.data.arrayBuffer())).toEqual(PNG);
    const row = w.rows.get(PATH_PNG), s = new MemoryCommsStore();
    s.db.gmail = { connected: true, needs_reconnect: false, email: 'comunicados.qa@gmail.com' }; s.db.blobs[PATH_PNG] = w.storage.get(PATH_PNG);
    s.db.collaborators = [{ id: 'c1', full_name: 'Ana', email: 'ana@ejemplo.test', active: true, sector: 'Cobranzas' }];
    s.db.messages = [{ id: MID, subject: 'Con adjunto', body_html: '<p>x</p>', version: 1, status: 'BORRADOR', selection: { all: true }, schedule: { kind: 'ONCE', time: '09:00', start_date: '2026-11-02' },
      attachments: [{ id: row.id, name: row.file_name, mime: row.mime, size_bytes: row.size_bytes, sha256: row.sha256, storage_path: row.storage_path }] }];
    s.activate(MID, Date.parse('2026-11-01T12:00:00Z')); const sent = [];
    await dispatch(s, { send: async raw => { sent.push(Buffer.from(raw.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString()); return { id: 'gm-1' }; } }, { now: zonedToUtc('2026-11-02', '09:01') });
    expect(sent).toHaveLength(1); expect(sent[0]).toContain('filename="infografia.png"');
  });
  it('AT-03/04/06 permiso, ruta ajena y confirmación pendiente: nada se borra', async () => {
    const w = world({ rpcBehaviour: async () => ({ data: null, error: { message: 'CONFIRMATION_REQUIRED: agregar un adjunto afecta los próximos envíos', code: '22023' } }) });
    w.storage.set(PATH_PNG, PNG);
    expect((await (await handle(req(body(PATH_PNG)), w.deps)).json()).error).toBe('CONFIRMATION_REQUIRED');
    expect((await (await handle(req({ ...body(PATH_PNG), path: 'messages/99999999-2222-3333-4444-555555555555/' + K + '.png' }), w.deps)).json()).error).toBe('RUTA_INVALIDA');
    const no = { ...w.deps, userClient: () => ({ rpc: async () => ({ data: false, error: null }), auth: { getUser: async () => ({ data: {} }) } }) };
    expect((await handle(req(body(PATH_PNG)), no)).status).toBe(403); expect(w.removed).toEqual([]);
  });
});
