import { createClient } from '@supabase/supabase-js';
import { env } from './env.js';

export const supabaseAuth = createClient(env.supabaseUrl, env.supabaseAnonKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
});
