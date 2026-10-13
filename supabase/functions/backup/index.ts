// Edge Function "backup" (service role; solo settings.manage). Secrets automáticos: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { json } from '../_shared/http.js';
import { handle, listAllObjects, safeAuthUser, BUCKETS } from './handler.js';
const url = Deno.env.get('SUPABASE_URL') ?? '', key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const admin = createClient(url || 'http://invalid', key || 'invalid', { auth: { persistSession: false } });
const deps = {
  async getUserFromJwt(jwt: string) { const { data } = await admin.auth.getUser(jwt); return data?.user ? { id: data.user.id } : null; },
  async userHasPerm(id: string, perm: string) { const r = await admin.rpc('user_has_perm', { p_user: id, p_perm: perm }); if (r.error) throw new Error('permiso: ' + r.error.message); return !!r.data; },
  async dumpTable(t: string) { const out: any[] = []; for (let from = 0; ; from += 1000) { const r = await admin.from(t).select('*').range(from, from + 999); if (r.error) throw new Error(t + ': ' + r.error.message); out.push(...(r.data ?? [])); if ((r.data ?? []).length < 1000) break; } return out; },
  async downloadObject(b: string, name: string) { const r = await admin.storage.from(b).download(name); if (r.error) throw new Error(b + '/' + name + ': ' + r.error.message); return new Uint8Array(await r.data.arrayBuffer()); },
  async listStorage() {
    const res: Record<string, string[]> = {};
    const listFn = async (b: string, prefix: string, opts: any) => { const r = await admin.storage.from(b).list(prefix, opts); if (r.error) throw new Error(b + ': ' + r.error.message); return (r.data ?? []) as any[]; };
    for (const b of BUCKETS) res[b] = await listAllObjects(listFn, b);
    return res;
  },
  async listAuthUsers() {
    const out: any[] = [];
    for (let page = 1; ; page++) { const r = await admin.auth.admin.listUsers({ page, perPage: 1000 }); if (r.error) throw new Error('auth: ' + r.error.message); out.push(...r.data.users.map(safeAuthUser)); if (r.data.users.length < 1000) break; }
    return out;
  },
  async audit(e: any) { await admin.from('audit_log').insert(e); }
};
Deno.serve(async (req) => {
  if (!url || !key) return json(500, { error: 'Función mal configurada: faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY', code: 'CONFIG_ERROR' });
  try { return await handle(req, deps); } catch (e) { return json(500, { error: String((e as Error).message || e), code: 'SERVER_ERROR' }); }
});
