import { DemoApi } from './demo-api.js';
import { SupabaseApi } from './supabase-api.js';

// Con VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY → modo online real; sin ellas → modo demo.
export function createApi(env = import.meta.env) {
  const url = env && env.VITE_SUPABASE_URL, key = env && env.VITE_SUPABASE_ANON_KEY;
  return url && key ? new SupabaseApi(url, key) : new DemoApi();
}
