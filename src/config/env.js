import 'dotenv/config';

export const env = {
  port: parseInt(process.env.PORT || '3001', 10),
  supabaseUrl: process.env.SUPABASE_URL,
  supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  supabaseAnonKey: process.env.SUPABASE_ANON_KEY,
  geometryEnginePath: process.env.GEOMETRY_ENGINE_PATH || '../cabinetry_designer_geometry',
  geometryEngineMode: process.env.GEOMETRY_ENGINE_MODE || 'cli', // 'cli' | 'http'
};

const required = ['supabaseUrl', 'supabaseServiceRoleKey'];
for (const key of required) {
  if (!env[key]) {
    throw new Error(`Missing required env var: ${key}`);
  }
}
