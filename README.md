# Cabinetry Designer — API

Express backend for the cabinetry designer. It verifies the designer's Supabase login using the project's anon key and turns drawing payloads into zipped DXFs through the Python geometry engine. Reports and saved revisions come later.

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
| `POST` | `/api/drawings/preview` | Requires a Bearer token. Accepts a drawing payload v1 and returns an `application/zip` attachment with `Content-Disposition` and `X-Drawing-Files` headers. |

Create the geometry virtualenv before exporting drawings (from the geometry repository):

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Save a drawing payload v1 as `payload.json`, then use the designer's Supabase access token:

```bash
curl --fail-with-body -X POST http://localhost:3001/api/drawings/preview \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @payload.json \
  --output g1-euro-kitchen.zip
```

The response names the zip after the room (for example, `g1-euro-kitchen.zip`). `X-Drawing-Files` lists the DXF names, separated by commas. Invalid payloads return `400` for the API's light schema check or `422` with geometry's validation details; engine failures return `502`, and timeouts return `504`.
