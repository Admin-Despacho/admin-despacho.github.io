// Comunicaciones · adaptador ONLINE (SupabaseApi) con cliente Supabase SIMULADO: permisos efectivos, rechazos del servidor, adjuntos y OAuth.
import { describe, it, expect, vi } from 'vitest';
import { SupabaseApi } from '../../src/online/supabase-api.js';
import { SupabaseComms } from '../../src/online/comms-api.js';
import { roleNav } from '../../src/online/rc4-ui.js';
import { hasPerm } from '../../supabase/functions/_shared/rules.js';
Object.assign(SupabaseApi.prototype, SupabaseComms);

const UID = '00000000-0000-0000-0000-0000000000b1';
function fakeSb({ perms = [], rpcError = null, calls = [] } = {}) {
  const q = rows => { const b = { select: () => b, eq: () => b, in: () => b, order: () => b, limit: () => b, maybeSingle: async () => ({ data: rows[0] || null, error: null }), then: (ok, ko) => Promise.resolve({ data: rows, error: null }).then(ok, ko) }; return b; };
  const store = { uploads: [] };
  return { calls, store, supabaseUrl: 'https://proyecto.supabase.co', supabaseKey: 'anon-qa',
    auth: { getSession: async () => ({ data: { session: { user: { id: UID }, access_token: 'x.' + Buffer.from(JSON.stringify({ iat: Math.floor(Date.now() / 1000) })).toString('base64') + '.y' } } }) },
    from: t => q(t === 'profiles' ? [{ id: UID, full_name: 'Operario QA', role: 'OPERARIO_DEPOSITO', status: 'ACTIVO' }] : []),
    rpc: async (fn, args) => { calls.push([fn, args]); if (fn === 'user_effective_permissions') return { data: perms, error: null };
      if (rpcError) return { data: null, error: rpcError }; return { data: { id: 'ok', ...(args || {}) }, error: null }; },
    storage: { from: b => ({ upload: async (path, blob, o) => { store.uploads.push({ b, path, type: o.contentType }); return { data: { path }, error: null }; } }) } };
}
const file = (bytes, name, type) => ({ name, type, size: bytes.length, arrayBuffer: async () => new Uint8Array(bytes).buffer });

describe('Comunicaciones · adaptador online', () => {
  it('CO-01 permisos EFECTIVOS del servidor: con comms.view otorgado individualmente aparece "Comunicaciones"; revocado, no', async () => {
    const on = await new SupabaseApi('u', 'k', fakeSb({ perms: ['routes.create', 'comms.view', 'comms.compose'] })).me();
    expect(hasPerm(on, 'comms.compose')).toBe(true); expect(roleNav(on).flat(2)).toContain('#/comunicaciones');
    const off = await new SupabaseApi('u', 'k', fakeSb({ perms: ['routes.create'] })).me();
    expect(hasPerm(off, 'comms.view')).toBe(false); expect(roleNav(off).flat(2)).not.toContain('#/comunicaciones');
  });
  it('CO-02 cada acción va a su función del servidor; un rechazo FORBIDDEN llega como mensaje claro', async () => {
    const sb = fakeSb(); const a = new SupabaseApi('u', 'k', sb);
    await a.commsSaveMessage({ internal_name: 'X' }, true); await a.commsActivate('m1'); await a.commsRegisterWhatsApp('m1', 'nota');
    expect(sb.calls.map(c => c[0])).toEqual(['comm_save_message', 'comm_activate', 'comm_register_whatsapp']);
    expect(sb.calls[0][1]).toEqual({ p: { internal_name: 'X' }, p_confirm: true });
    const bad = new SupabaseApi('u', 'k', fakeSb({ rpcError: { message: 'FORBIDDEN: falta el permiso comms.schedule', code: '42501' } }));
    await expect(bad.commsActivate('m1')).rejects.toMatchObject({ code: 'FORBIDDEN', message: 'No tenés permiso para esta acción: comms.schedule' });
  });
  it('CO-03 adjuntos: el contenido se valida ANTES de subir; el REGISTRO lo hace la función del servidor sin metadatos del navegador', async () => {
    const sb = fakeSb(); const a = new SupabaseApi('u', 'k', sb);
    await expect(a.commsAddAttachment('11111111-1111-1111-1111-111111111111', file([0x4d, 0x5a, 0x90, 0], 'factura.pdf', 'application/pdf'), [])).rejects.toMatchObject({ code: 'ADJUNTO_INVALIDO' });
    expect(sb.store.uploads).toHaveLength(0);
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ attachment: { id: 'att-1' } }), { status: 200 })); vi.stubGlobal('fetch', fetchMock);
    await a.commsAddAttachment('11111111-1111-1111-1111-111111111111', file([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1], 'info.png', ''), [], true);
    expect(sb.store.uploads[0].path).toMatch(/^messages\/11111111-1111-1111-1111-111111111111\/[0-9a-f-]{36}\.png$/);
    expect(fetchMock.mock.calls[0][0]).toBe('https://proyecto.supabase.co/functions/v1/comm-attachments');
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(Object.keys(body).sort()).toEqual(['confirm', 'file_name', 'message_id', 'path']);   // ni tipo, ni tamaño, ni hash: los calcula el servidor
    expect(sb.calls.some(c => /register_attachment/.test(c[0]))).toBe(false);
    vi.unstubAllGlobals();
  });
  it('CO-04 conectar Gmail: usa la función del servidor con la sesión del usuario y redirige a Google; ningún token queda en el navegador', async () => {
    const sb = fakeSb(); const a = new SupabaseApi('u', 'k', sb);
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ url: 'https://accounts.google.com/o/oauth2/v2/auth?state=s' }), { status: 200 }));
    const assign = vi.fn(); vi.stubGlobal('fetch', fetchMock); vi.stubGlobal('location', { assign });
    await a.commsGmailConnect();
    expect(fetchMock.mock.calls[0][0]).toBe('https://proyecto.supabase.co/functions/v1/comm-gmail-oauth?action=start');
    expect(fetchMock.mock.calls[0][1].headers.Authorization).toMatch(/^Bearer /); expect(assign).toHaveBeenCalledWith('https://accounts.google.com/o/oauth2/v2/auth?state=s');
    vi.unstubAllGlobals();
  });
});
