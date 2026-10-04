import 'dotenv/config';
import path from 'path';

const geometryEnginePath = path.resolve(process.env.GEOMETRY_ENGINE_PATH || '../cabinetry_designer_geometry');

export const env = {
  port: parseInt(process.env.PORT || '3001', 10),
  supabaseUrl: process.env.SUPABASE_URL,
  supabaseAnonKey: process.env.SUPABASE_ANON_KEY,
  geometryEnginePath,
  // The geometry repo's virtualenv python, so its packages are found (SPEC-40).
  geometryPython: process.env.GEOMETRY_PYTHON
    ? path.resolve(process.env.GEOMETRY_PYTHON)
    : path.join(geometryEnginePath, '.venv', 'bin', 'python'),
  geometryTimeoutMs: parseInt(process.env.GEOMETRY_TIMEOUT_MS || '30000', 10),
};

for (const key of ['supabaseUrl', 'supabaseAnonKey']) {
  if (!env[key]) throw new Error(`Missing required env var for ${key} (see .env.example)`);
}
