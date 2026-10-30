// Comunicaciones · OAuth de Gmail. Secretos: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, COMM_OAUTH_REDIRECT_URI, COMM_APP_URL. verify_jwt = false
// (Google vuelve con un GET sin sesión); las acciones 'start' y 'disconnect' validan la sesión y el permiso con el JWT del usuario.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { handle } from './handler.js';

const URL_ = Deno.env.get('SUPABASE_URL')!, ANON = Deno.env.get('SUPABASE_ANON_KEY')!, SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CORS = { 'Access-Control-Allow-Origin': Deno.env.get('COMM_APP_ORIGIN') ?? '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' };
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  const res = await handle(req, {
    env: { clientId: Deno.env.get('GOOGLE_CLIENT_ID') ?? '', clientSecret: Deno.env.get('GOOGLE_CLIENT_SECRET') ?? '', redirectUri: Deno.env.get('COMM_OAUTH_REDIRECT_URI') ?? '', appUrl: Deno.env.get('COMM_APP_URL') ?? '/' },
    userClient: (auth: string) => createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } }),
    serviceClient: () => createClient(URL_, SERVICE, { auth: { persistSession: false } }),
  });
  for (const [k, v] of Object.entries(CORS)) res.headers.set(k, v);
  return res;
});
