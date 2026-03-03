# Cabinetry Designer — API

Node.js/Express backend that manages projects, rooms, walls, and placed objects. Resolves parametric fallback chains, orchestrates Python geometry engine calls, and serves manufacturing reports.

## Tech Stack

- **Express** — HTTP server
- **Supabase** — Postgres DB + Storage + Auth verification
- **Zod** — Request validation
- **Child Process** — Spawns Python geometry engine via CLI

## Getting Started

```bash
# Install dependencies
npm install

# Copy env and fill in values
cp .env.example .env

# Start dev server (port 3001, auto-restart on changes)
npm run dev
```

## Environment Variables

| Variable | Description |
|---|---|
| `PORT` | Server port (default: 3001) |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key (bypasses RLS) |
| `SUPABASE_ANON_KEY` | Anon key (for user-scoped clients) |
| `GEOMETRY_ENGINE_PATH` | Path to Python geometry engine repo |
| `GEOMETRY_ENGINE_MODE` | `cli` or `http` |

## API Routes

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check (no auth) |
| `GET` | `/api/projects?team_id=` | List team projects |
| `POST` | `/api/projects` | Create project |
| `GET` | `/api/rooms/:roomId` | Get room with walls + objects |
| `POST` | `/api/rooms` | Create room |
| `PUT` | `/api/walls/batch` | Bulk upsert walls |
| `PUT` | `/api/objects/batch` | Bulk upsert objects |
| `POST` | `/api/rooms/:roomId/generate` | Generate DXF + reports |
| `GET` | `/api/rooms/:roomId/reports` | Quick reports (no DXF) |

## Parameter Fallback Chain

```
object.params.{key}
  → room.default_params.{key}
    → project.default_params.{key}
      → team_defaults.default_params.{key}
        → SYSTEM_DEFAULTS[key]
```

## Database Migration

Run `supabase/migrations/001_create_cd_tables.sql` against your Supabase project to create the `cd_*` tables with RLS policies.
