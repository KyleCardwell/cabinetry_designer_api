import { createClient } from '@supabase/supabase-js';
import { env } from './env.js';

// Service-role client for backend operations (bypasses RLS)
export const supabaseAdmin = createClient(env.supabaseUrl, env.supabaseServiceRoleKey);

// Create a client scoped to a specific user's JWT (respects RLS)
export function supabaseForUser(accessToken) {
  return createClient(env.supabaseUrl, env.supabaseAnonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}
