# Cabinetry Designer — API

Express backend for the cabinetry designer. It verifies the designer's Supabase login using the project's anon key. Drawing payloads will be turned into DXFs through the Python geometry engine when the drawing preview route is added in step 310. Reports and saved revisions come later.

## Getting Started

```bash
npm install
cp .env.example .env
```

Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `.env` with the same values as `VITE_FF_JS_SUPABASE_URL` and `VITE_FF_JS_SUPABASE_ANON_KEY` in `cabinetry_designer/.env`.

```bash
npm run dev
```

The API starts on port 3001 by default and restarts when files change.

## Environment Variables

| Variable | Description |
|---|---|
| `PORT` | Server port (default: `3001`) |
| `SUPABASE_URL` | Required Supabase project URL, matching the designer |
| `SUPABASE_ANON_KEY` | Required Supabase anon key, matching the designer; used to verify logins |
| `GEOMETRY_ENGINE_PATH` | Geometry repository path (default: `../cabinetry_designer_geometry`, resolved from the working directory) |
| `GEOMETRY_PYTHON` | Optional Python executable path (default: `$GEOMETRY_ENGINE_PATH/.venv/bin/python`) |
| `GEOMETRY_TIMEOUT_MS` | Optional geometry command timeout in milliseconds (default: `30000`) |

## API Routes

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check; no authentication required. Returns `status: "ok"` and a timestamp. |
