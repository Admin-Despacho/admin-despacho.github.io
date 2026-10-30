import { DemoApi } from './demo-api.js';
import { SupabaseApi } from './supabase-api.js';
import { DemoComms, SupabaseComms } from './comms-api.js';   // módulo Comunicaciones (separado)
// el módulo NUNCA pisa un método existente de los adaptadores (si hubiera un nombre repetido, se omite y se avisa)
for (const [Cls, mix] of [[DemoApi, DemoComms], [SupabaseApi, SupabaseComms]]) for (const [k, v] of Object.entries(mix)) {
  if (k in Cls.prototype) { console.error('Comunicaciones: nombre repetido en el adaptador, se omite: ' + k); continue; } Cls.prototype[k] = v; }

// Con VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY → modo online real; sin ellas → modo demo.
export function createApi(env = import.meta.env) {
  const url = env && env.VITE_SUPABASE_URL, key = env && env.VITE_SUPABASE_ANON_KEY;
  return url && key ? new SupabaseApi(url, key) : new DemoApi();
}
