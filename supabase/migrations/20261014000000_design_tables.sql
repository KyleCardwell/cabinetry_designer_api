-- Migration: designer tables, RLS and RPCs (DATABASE-PLAN round D3, 2026-10-14)
--
-- Adds the cabinetry designer's storage to the ff-job-schedule Supabase project.
-- Only NEW tables and functions are created; nothing existing is altered.
--
--   design_team_settings   shop standard (one row per team)
--   design_projects        designer companion row for an estimate_projects row
--   design_phases          project > phase
--   design_rooms           phase > room (one autosaved draft document per room)
--   design_room_versions   frozen copies made by Issue (never updated or deleted)
--   design_profiles        section profile library
--   design_door_designs    door design library
--
-- Rules (DATABASE-PLAN §4):
--   - RLS on every table, SELECT policies only. The browser cannot insert/update/delete;
--     every write goes through a security-definer RPC below.
--   - Every RPC checks has_team_permission() first:
--       view   = can_view_estimates or can_create_estimates (can_read_estimate_team)
--       edit   = can_create_estimates   (projects, phases, rooms, overrides, status, issue)
--       manage = can_manage_teams       (shop standard, library)
--   - Every editable row has a `version` counter. Writes send the version they loaded;
--     a stale version saves nothing and returns { ok: false, reason: 'conflict', ... }
--     with who saved last and when.
--   - Child rows carry team_id and composite foreign keys, so a phase/room/version can
--     never belong to a different team than its parent.
--   - Design rows reference estimate_projects ON DELETE RESTRICT: deleting an estimate
--     project that has drawings fails instead of cascading them away.
--   - The designer's /projects list shows only projects with a design_projects row
--     (list_design_projects). The estimator is unaffected.
--
-- Run the whole file once in the Supabase SQL editor (it is one transaction).
-- Not safe to re-run as-is once applied (tables already exist).

begin;

-- =======================================================================================
-- 1. Helpers
-- =======================================================================================

-- Time-ordered UUID (v7). Postgres 18 has uuidv7(); this works on earlier versions.
create or replace function public.design_uuidv7()
returns uuid
language sql
volatile
set search_path = public
as $$
  select encode(
    set_bit(
      set_bit(
        overlay(
          uuid_send(gen_random_uuid())
          placing substring(int8send((extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
          from 1 for 6
        ),
        52, 1
      ),
      53, 1
    ),
    'hex'
  )::uuid;
$$;

-- Raise 42501 unless the caller is signed in and holds p_permission on p_team_id.
create or replace function public.design_require(p_team_id uuid, p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if p_team_id is null or not public.has_team_permission(p_team_id, p_permission) then
    raise exception 'You do not have permission to do this (%)', p_permission
      using errcode = '42501';
  end if;
end;
$$;

-- A team member's display name (team_members.user_name), or null.
create or replace function public.design_user_name(p_team_id uuid, p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select tm.user_name
  from public.team_members tm
  where tm.team_id = p_team_id
    and tm.user_id = p_user_id
    and public.can_read_estimate_team(p_team_id)
  limit 1;
$$;

-- The standard "someone else saved first" reply.
create or replace function public.design_conflict(
  p_team_id uuid, p_version int, p_updated_by uuid, p_updated_at timestamptz
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ok', false,
    'reason', 'conflict',
    'version', p_version,
    'updated_by', p_updated_by,
    'updated_by_name', public.design_user_name(p_team_id, p_updated_by),
    'updated_at', p_updated_at
  );
$$;

-- Nonblank trimmed text or an error naming the field.
create or replace function public.design_required_text(p_value text, p_label text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := nullif(trim(p_value), '');
begin
  if v is null then
    raise exception '% is required', p_label using errcode = '22023';
  end if;
  return v;
end;
$$;

-- A jsonb object or an error naming the field.
create or replace function public.design_required_object(p_value jsonb, p_label text)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_value is null or jsonb_typeof(p_value) <> 'object' then
    raise exception '% must be a JSON object', p_label using errcode = '22023';
  end if;
  return p_value;
end;
$$;

-- =======================================================================================
-- 2. Tables
-- =======================================================================================

create table public.design_team_settings (
  team_id     uuid primary key references public.teams (team_id) on delete restrict,
  settings    jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  version     int not null default 1,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);

create table public.design_projects (
  est_project_id  bigint primary key
                  references public.estimate_projects (est_project_id) on delete restrict,
  team_id         uuid not null references public.teams (team_id) on delete restrict,
  overrides       jsonb not null default '{}'::jsonb check (jsonb_typeof(overrides) = 'object'),
  version         int not null default 1,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_by      uuid,
  updated_at      timestamptz not null default now(),
  archived_at     timestamptz,
  unique (est_project_id, team_id)
);
create index design_projects_team_idx on public.design_projects (team_id);

create table public.design_phases (
  phase_id        uuid primary key default public.design_uuidv7(),
  team_id         uuid not null,
  est_project_id  bigint not null,
  name            text not null check (trim(name) <> ''),
  sort            int not null default 0,
  overrides       jsonb not null default '{}'::jsonb check (jsonb_typeof(overrides) = 'object'),
  version         int not null default 1,
  estimate_id     bigint references public.estimates (estimate_id) on delete set null, -- DB14, unused for now
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_by      uuid,
  updated_at      timestamptz not null default now(),
  archived_at     timestamptz,
  unique (phase_id, team_id),
  foreign key (est_project_id, team_id)
    references public.design_projects (est_project_id, team_id) on delete restrict
);
create index design_phases_project_idx on public.design_phases (est_project_id, sort);

create table public.design_rooms (
  room_id              uuid primary key default public.design_uuidv7(),
  team_id              uuid not null,
  phase_id             uuid not null,
  name                 text not null check (trim(name) <> ''),
  sort                 int not null default 0,
  status               text not null default 'drafting'
                       check (status in ('drafting', 'approved', 'released')),
  status_by            uuid,
  status_at            timestamptz,
  document             jsonb not null check (jsonb_typeof(document) = 'object'),
  schema_version       int not null,
  version              int not null default 1,  -- optimistic-concurrency counter, not a design version
  copied_from_room_id  uuid references public.design_rooms (room_id) on delete set null,
  created_by           uuid,
  created_at           timestamptz not null default now(),
  updated_by           uuid,
  updated_at           timestamptz not null default now(),
  archived_at          timestamptz,
  unique (room_id, team_id),
  foreign key (phase_id, team_id)
    references public.design_phases (phase_id, team_id) on delete restrict
);
create index design_rooms_phase_idx on public.design_rooms (phase_id, sort);
create index design_rooms_copied_from_idx on public.design_rooms (copied_from_room_id);

create table public.design_room_versions (
  version_id         uuid primary key default public.design_uuidv7(),
  room_id            uuid not null,
  team_id            uuid not null,
  seq                int not null check (seq > 0),
  label              text not null check (trim(label) <> ''),
  note               text,
  document           jsonb not null check (jsonb_typeof(document) = 'object'),
  schema_version     int not null,
  settings_snapshot  jsonb not null check (jsonb_typeof(settings_snapshot) = 'object'),
  issued_by          uuid,
  issued_at          timestamptz not null default now(),
  unique (room_id, seq),
  foreign key (room_id, team_id)
    references public.design_rooms (room_id, team_id) on delete restrict
);

create table public.design_profiles (
  profile_id   uuid primary key default public.design_uuidv7(),
  team_id      uuid not null references public.teams (team_id) on delete restrict,
  kind         text not null check (trim(kind) <> ''),
  name         text not null check (trim(name) <> ''),
  data         jsonb not null check (jsonb_typeof(data) = 'object'),
  version      int not null default 1,
  sort         int not null default 0,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_by   uuid,
  updated_at   timestamptz not null default now(),
  archived_at  timestamptz
);
create index design_profiles_team_idx on public.design_profiles (team_id, kind, sort);

create table public.design_door_designs (
  design_id    uuid primary key default public.design_uuidv7(),
  team_id      uuid not null references public.teams (team_id) on delete restrict,
  code         text not null check (trim(code) <> ''),
  data         jsonb not null check (jsonb_typeof(data) = 'object'),
  version      int not null default 1,
  sort         int not null default 0,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_by   uuid,
  updated_at   timestamptz not null default now(),
  archived_at  timestamptz
);
create index design_door_designs_team_idx on public.design_door_designs (team_id, sort);
-- Codes are unique per team among live (unarchived) designs, ignoring case (as isDoorDesignList).
create unique index design_door_designs_code_idx
  on public.design_door_designs (team_id, lower(code))
  where archived_at is null;

-- Issued versions are frozen: no UPDATE or DELETE, even from RPCs or the SQL editor.
create or replace function public.design_versions_frozen()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'Issued versions cannot be changed or deleted' using errcode = '42501';
end;
$$;

create trigger design_room_versions_frozen
  before update or delete on public.design_room_versions
  for each row execute function public.design_versions_frozen();

-- =======================================================================================
-- 3. RLS: select only
-- =======================================================================================

alter table public.design_team_settings  enable row level security;
alter table public.design_projects       enable row level security;
alter table public.design_phases         enable row level security;
alter table public.design_rooms          enable row level security;
alter table public.design_room_versions  enable row level security;
alter table public.design_profiles       enable row level security;
alter table public.design_door_designs   enable row level security;

create policy "View with estimate permission" on public.design_team_settings
  for select to authenticated using (public.can_read_estimate_team(team_id));
create policy "View with estimate permission" on public.design_projects
  for select to authenticated using (public.can_read_estimate_team(team_id));
create policy "View with estimate permission" on public.design_phases
  for select to authenticated using (public.can_read_estimate_team(team_id));
create policy "View with estimate permission" on public.design_rooms
  for select to authenticated using (public.can_read_estimate_team(team_id));
create policy "View with estimate permission" on public.design_room_versions
  for select to authenticated using (public.can_read_estimate_team(team_id));
create policy "View with estimate permission" on public.design_profiles
  for select to authenticated using (public.can_read_estimate_team(team_id));
create policy "View with estimate permission" on public.design_door_designs
  for select to authenticated using (public.can_read_estimate_team(team_id));

-- Belt and braces: no direct writes from the API roles even if a policy is added by mistake.
revoke insert, update, delete, truncate on
  public.design_team_settings, public.design_projects, public.design_phases,
  public.design_rooms, public.design_room_versions, public.design_profiles,
  public.design_door_designs
from anon, authenticated;
revoke all on
  public.design_team_settings, public.design_projects, public.design_phases,
  public.design_rooms, public.design_room_versions, public.design_profiles,
  public.design_door_designs
from anon;

-- =======================================================================================
-- 4. Read RPCs (security invoker: RLS applies)
-- =======================================================================================

-- The designer's /projects list: only projects that have been opened in the designer.
create or replace function public.list_design_projects(
  p_team_id uuid,
  p_include_archived boolean default false
)
returns table (
  est_project_id   bigint,
  est_project_name text,
  est_client_name  text,
  street           text,
  city             text,
  state            text,
  zip              text,
  created_at       timestamptz,
  updated_at       timestamptz,
  archived_at      timestamptz,
  phase_count      int,
  room_count       int
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    ep.est_project_id,
    ep.est_project_name,
    ep.est_client_name,
    ep.street, ep.city, ep.state, ep.zip,
    dp.created_at,
    greatest(dp.updated_at, rm.last_room_update, ph.last_phase_update) as updated_at,
    dp.archived_at,
    coalesce(ph.phase_count, 0)::int,
    coalesce(rm.room_count, 0)::int
  from public.design_projects dp
  join public.estimate_projects ep on ep.est_project_id = dp.est_project_id
  left join lateral (
    select count(*) filter (where p.archived_at is null) as phase_count,
           max(p.updated_at) as last_phase_update
    from public.design_phases p
    where p.est_project_id = dp.est_project_id
  ) ph on true
  left join lateral (
    select count(*) filter (where r.archived_at is null and p.archived_at is null) as room_count,
           max(r.updated_at) as last_room_update
    from public.design_rooms r
    join public.design_phases p on p.phase_id = r.phase_id
    where p.est_project_id = dp.est_project_id
  ) rm on true
  where dp.team_id = p_team_id
    and (p_include_archived or dp.archived_at is null)
  order by 9 desc nulls last;
$$;

-- Estimator projects that are NOT in the designer yet (the "add existing project" picker).
create or replace function public.list_attachable_estimate_projects(
  p_team_id uuid,
  p_search text default ''
)
returns table (
  est_project_id   bigint,
  est_project_name text,
  est_client_name  text,
  street           text,
  city             text,
  created_at       timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select ep.est_project_id, ep.est_project_name, ep.est_client_name,
         ep.street, ep.city, ep.created_at
  from public.estimate_projects ep
  where ep.team_id = p_team_id
    and not exists (
      select 1 from public.design_projects dp where dp.est_project_id = ep.est_project_id
    )
    and (
      coalesce(trim(p_search), '') = ''
      or ep.est_project_name ilike '%' || trim(p_search) || '%'
      or ep.est_client_name  ilike '%' || trim(p_search) || '%'
    )
  order by ep.created_at desc
  limit 50;
$$;

-- One project page: project info, design overrides, phases and their rooms (no documents).
create or replace function public.get_design_project(p_est_project_id bigint)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'project', jsonb_build_object(
      'est_project_id',   ep.est_project_id,
      'est_project_name', ep.est_project_name,
      'est_client_name',  ep.est_client_name,
      'street', ep.street, 'city', ep.city, 'state', ep.state, 'zip', ep.zip,
      'team_id', ep.team_id
    ),
    'design', jsonb_build_object(
      'overrides',       dp.overrides,
      'version',         dp.version,
      'updated_at',      dp.updated_at,
      'updated_by_name', public.design_user_name(dp.team_id, dp.updated_by),
      'archived_at',     dp.archived_at
    ),
    'phases', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'phase_id',    ph.phase_id,
          'name',        ph.name,
          'sort',        ph.sort,
          'overrides',   ph.overrides,
          'version',     ph.version,
          'created_at',  ph.created_at,
          'archived_at', ph.archived_at,
          'rooms', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'room_id',             r.room_id,
                'name',                r.name,
                'sort',                r.sort,
                'status',              r.status,
                'status_at',           r.status_at,
                'status_by_name',      public.design_user_name(r.team_id, r.status_by),
                'version',             r.version,
                'schema_version',      r.schema_version,
                'updated_at',          r.updated_at,
                'updated_by_name',     public.design_user_name(r.team_id, r.updated_by),
                'copied_from_room_id', r.copied_from_room_id,
                'archived_at',         r.archived_at,
                'last_version', (
                  select jsonb_build_object('seq', v.seq, 'label', v.label, 'issued_at', v.issued_at)
                  from public.design_room_versions v
                  where v.room_id = r.room_id
                  order by v.seq desc
                  limit 1
                )
              )
              order by r.sort, r.created_at
            )
            from public.design_rooms r
            where r.phase_id = ph.phase_id
          ), '[]'::jsonb)
        )
        order by ph.sort, ph.created_at
      )
      from public.design_phases ph
      where ph.est_project_id = dp.est_project_id
    ), '[]'::jsonb)
  )
  from public.design_projects dp
  join public.estimate_projects ep on ep.est_project_id = dp.est_project_id
  where dp.est_project_id = p_est_project_id;
$$;

-- A room's issued versions, newest first (no documents).
create or replace function public.list_design_room_versions(p_room_id uuid)
returns table (
  version_id      uuid,
  seq             int,
  label           text,
  note            text,
  schema_version  int,
  issued_by       uuid,
  issued_by_name  text,
  issued_at       timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select v.version_id, v.seq, v.label, v.note, v.schema_version,
         v.issued_by, public.design_user_name(v.team_id, v.issued_by), v.issued_at
  from public.design_room_versions v
  where v.room_id = p_room_id
  order by v.seq desc;
$$;

-- =======================================================================================
-- 5. Write RPCs (security definer; permission check first)
-- =======================================================================================

-- ---------------------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------------------

-- Put a project in the designer. Either attach an existing estimate project
-- (p_est_project_id) or create a new one from p_project
-- ({ est_project_name (required), est_client_name, street, city, state, zip }).
-- Optionally also creates the first phase, and a first room in it, in the same transaction.
create or replace function public.create_design_project(
  p_team_id         uuid,
  p_est_project_id  bigint default null,
  p_project         jsonb default null,
  p_phase_name      text default null,
  p_room_name       text default null,
  p_room_document   jsonb default null,
  p_schema_version  int default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_project_id bigint := p_est_project_id;
  v_ep_team    uuid;
  v_phase_id   uuid;
  v_room_id    uuid;
begin
  perform public.design_require(p_team_id, 'can_create_estimates');

  if v_project_id is not null then
    select ep.team_id into v_ep_team
    from public.estimate_projects ep
    where ep.est_project_id = v_project_id;
    if not found then
      raise exception 'Project not found' using errcode = 'P0002';
    end if;
    if v_ep_team is distinct from p_team_id then
      raise exception 'That project belongs to another team' using errcode = '42501';
    end if;
    if exists (select 1 from public.design_projects where est_project_id = v_project_id) then
      raise exception 'That project is already in the designer' using errcode = '23505';
    end if;
  else
    if p_project is null or jsonb_typeof(p_project) <> 'object' then
      raise exception 'Project details are required' using errcode = '22023';
    end if;
    insert into public.estimate_projects
      (est_project_name, est_client_name, street, city, state, zip, team_id)
    values (
      public.design_required_text(p_project ->> 'est_project_name', 'Project name'),
      nullif(trim(p_project ->> 'est_client_name'), ''),
      nullif(trim(p_project ->> 'street'), ''),
      nullif(trim(p_project ->> 'city'), ''),
      nullif(trim(p_project ->> 'state'), ''),
      nullif(trim(p_project ->> 'zip'), ''),
      p_team_id
    )
    returning est_project_id into v_project_id;
  end if;

  insert into public.design_projects (est_project_id, team_id, created_by, updated_by)
  values (v_project_id, p_team_id, v_uid, v_uid);

  if nullif(trim(p_phase_name), '') is not null then
    insert into public.design_phases (team_id, est_project_id, name, sort, created_by, updated_by)
    values (p_team_id, v_project_id, trim(p_phase_name), 0, v_uid, v_uid)
    returning phase_id into v_phase_id;
  end if;

  if nullif(trim(p_room_name), '') is not null then
    if v_phase_id is null then
      raise exception 'A first room needs a first phase' using errcode = '22023';
    end if;
    if p_schema_version is null then
      raise exception 'Schema version is required' using errcode = '22023';
    end if;
    insert into public.design_rooms
      (team_id, phase_id, name, sort, document, schema_version, created_by, updated_by)
    values (
      p_team_id, v_phase_id, trim(p_room_name), 0,
      public.design_required_object(p_room_document, 'Room document'),
      p_schema_version, v_uid, v_uid
    )
    returning room_id into v_room_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'est_project_id', v_project_id,
    'phase_id', v_phase_id,
    'room_id', v_room_id
  );
end;
$$;

-- Edit the project's name/client/address (the estimate_projects row). Only keys present
-- in p_info change; est_project_name can't be blanked.
create or replace function public.update_design_project_info(
  p_est_project_id bigint,
  p_info jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team uuid;
begin
  select dp.team_id into v_team from public.design_projects dp
  where dp.est_project_id = p_est_project_id;
  if not found then
    raise exception 'Project not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_create_estimates');
  perform public.design_required_object(p_info, 'Project details');

  update public.estimate_projects ep set
    est_project_name = case when p_info ? 'est_project_name'
      then public.design_required_text(p_info ->> 'est_project_name', 'Project name')
      else ep.est_project_name end,
    est_client_name = case when p_info ? 'est_client_name'
      then nullif(trim(p_info ->> 'est_client_name'), '') else ep.est_client_name end,
    street = case when p_info ? 'street' then nullif(trim(p_info ->> 'street'), '') else ep.street end,
    city   = case when p_info ? 'city'   then nullif(trim(p_info ->> 'city'), '')   else ep.city end,
    state  = case when p_info ? 'state'  then nullif(trim(p_info ->> 'state'), '')  else ep.state end,
    zip    = case when p_info ? 'zip'    then nullif(trim(p_info ->> 'zip'), '')    else ep.zip end,
    updated_at = now()
  where ep.est_project_id = p_est_project_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- Hide (or unhide) a project in the designer list. Nothing is deleted.
create or replace function public.archive_design_project(
  p_est_project_id bigint,
  p_archived boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team uuid;
begin
  select dp.team_id into v_team from public.design_projects dp
  where dp.est_project_id = p_est_project_id;
  if not found then
    raise exception 'Project not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_create_estimates');

  update public.design_projects
  set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
  where est_project_id = p_est_project_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- Project-level setting overrides (version-checked).
create or replace function public.save_project_overrides(
  p_est_project_id   bigint,
  p_overrides        jsonb,
  p_expected_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_projects%rowtype;
begin
  select * into r from public.design_projects where est_project_id = p_est_project_id;
  if not found then
    raise exception 'Project not found' using errcode = 'P0002';
  end if;
  perform public.design_require(r.team_id, 'can_create_estimates');
  perform public.design_required_object(p_overrides, 'Overrides');

  update public.design_projects
  set overrides = p_overrides, version = version + 1, updated_by = v_uid, updated_at = now()
  where est_project_id = p_est_project_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_projects where est_project_id = p_est_project_id;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'version', r.version, 'updated_at', r.updated_at);
end;
$$;

-- ---------------------------------------------------------------------------------------
-- Phases
-- ---------------------------------------------------------------------------------------

create or replace function public.create_design_phase(p_est_project_id bigint, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_team  uuid;
  v_sort  int;
  v_id    uuid;
begin
  select dp.team_id into v_team from public.design_projects dp
  where dp.est_project_id = p_est_project_id;
  if not found then
    raise exception 'Project not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_create_estimates');

  select coalesce(max(sort) + 1, 0) into v_sort
  from public.design_phases where est_project_id = p_est_project_id;

  insert into public.design_phases (team_id, est_project_id, name, sort, created_by, updated_by)
  values (v_team, p_est_project_id, public.design_required_text(p_name, 'Phase name'),
          v_sort, v_uid, v_uid)
  returning phase_id into v_id;

  return jsonb_build_object('ok', true, 'phase_id', v_id, 'sort', v_sort, 'version', 1);
end;
$$;

-- Rename / reorder / archive a phase. Null = leave as is. Does not bump `version`
-- (that counter guards the overrides).
create or replace function public.update_design_phase(
  p_phase_id uuid,
  p_name     text default null,
  p_sort     int default null,
  p_archived boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team uuid;
begin
  select ph.team_id into v_team from public.design_phases ph where ph.phase_id = p_phase_id;
  if not found then
    raise exception 'Phase not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_create_estimates');

  update public.design_phases set
    name = case when p_name is null then name
                else public.design_required_text(p_name, 'Phase name') end,
    sort = coalesce(p_sort, sort),
    archived_at = case when p_archived is null then archived_at
                       when p_archived then coalesce(archived_at, now())
                       else null end
  where phase_id = p_phase_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- Phase-level setting overrides (version-checked).
create or replace function public.save_phase_overrides(
  p_phase_id         uuid,
  p_overrides        jsonb,
  p_expected_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_phases%rowtype;
begin
  select * into r from public.design_phases where phase_id = p_phase_id;
  if not found then
    raise exception 'Phase not found' using errcode = 'P0002';
  end if;
  perform public.design_require(r.team_id, 'can_create_estimates');
  perform public.design_required_object(p_overrides, 'Overrides');

  update public.design_phases
  set overrides = p_overrides, version = version + 1, updated_by = v_uid, updated_at = now()
  where phase_id = p_phase_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_phases where phase_id = p_phase_id;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'version', r.version, 'updated_at', r.updated_at);
end;
$$;

-- ---------------------------------------------------------------------------------------
-- Rooms
-- ---------------------------------------------------------------------------------------

create or replace function public.create_design_room(
  p_phase_id       uuid,
  p_name           text,
  p_document       jsonb,
  p_schema_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_team uuid;
  v_sort int;
  v_id   uuid;
begin
  select ph.team_id into v_team from public.design_phases ph where ph.phase_id = p_phase_id;
  if not found then
    raise exception 'Phase not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_create_estimates');
  if p_schema_version is null then
    raise exception 'Schema version is required' using errcode = '22023';
  end if;

  select coalesce(max(sort) + 1, 0) into v_sort
  from public.design_rooms where phase_id = p_phase_id;

  insert into public.design_rooms
    (team_id, phase_id, name, sort, document, schema_version, created_by, updated_by)
  values (
    v_team, p_phase_id, public.design_required_text(p_name, 'Room name'), v_sort,
    public.design_required_object(p_document, 'Room document'), p_schema_version, v_uid, v_uid
  )
  returning room_id into v_id;

  return jsonb_build_object('ok', true, 'room_id', v_id, 'sort', v_sort, 'version', 1);
end;
$$;

-- Copy a room's current draft into a phase (same or another project, same team).
-- The copy starts in Drafting with copied_from_room_id set. Pass p_document (and
-- p_schema_version) to store a JS-adjusted document instead of the source's verbatim.
create or replace function public.copy_design_room(
  p_room_id        uuid,
  p_to_phase_id    uuid,
  p_name           text default null,
  p_document       jsonb default null,
  p_schema_version int default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  src       public.design_rooms%rowtype;
  v_to_team uuid;
  v_sort    int;
  v_id      uuid;
begin
  select * into src from public.design_rooms where room_id = p_room_id;
  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
  select ph.team_id into v_to_team from public.design_phases ph where ph.phase_id = p_to_phase_id;
  if not found then
    raise exception 'Phase not found' using errcode = 'P0002';
  end if;
  perform public.design_require(src.team_id, 'can_create_estimates');
  if v_to_team is distinct from src.team_id then
    raise exception 'Rooms can only be copied within the same team' using errcode = '42501';
  end if;
  if p_document is not null and p_schema_version is null then
    raise exception 'Schema version is required with a document' using errcode = '22023';
  end if;

  select coalesce(max(sort) + 1, 0) into v_sort
  from public.design_rooms where phase_id = p_to_phase_id;

  insert into public.design_rooms
    (team_id, phase_id, name, sort, document, schema_version, copied_from_room_id,
     created_by, updated_by)
  values (
    src.team_id, p_to_phase_id,
    coalesce(nullif(trim(p_name), ''), src.name),
    v_sort,
    case when p_document is null then src.document
         else public.design_required_object(p_document, 'Room document') end,
    coalesce(p_schema_version, src.schema_version),
    src.room_id, v_uid, v_uid
  )
  returning room_id into v_id;

  return jsonb_build_object('ok', true, 'room_id', v_id, 'sort', v_sort, 'version', 1);
end;
$$;

-- Rename / reorder / move / archive a room. Null = leave as is. Does not bump `version`,
-- so an open editor's next autosave isn't treated as a conflict.
create or replace function public.update_design_room_info(
  p_room_id  uuid,
  p_name     text default null,
  p_sort     int default null,
  p_archived boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team uuid;
begin
  select r.team_id into v_team from public.design_rooms r where r.room_id = p_room_id;
  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_create_estimates');

  update public.design_rooms set
    name = case when p_name is null then name
                else public.design_required_text(p_name, 'Room name') end,
    sort = coalesce(p_sort, sort),
    archived_at = case when p_archived is null then archived_at
                       when p_archived then coalesce(archived_at, now())
                       else null end
  where room_id = p_room_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- Autosave the draft. Saves only when p_expected_version matches.
-- An Approved or Released room is only saved with p_demote = true (the client warned the
-- user first); that save also drops it back to Drafting.
-- Replies:
--   { ok: true, version, updated_at, status }
--   { ok: false, reason: 'conflict', version, updated_by, updated_by_name, updated_at }
--   { ok: false, reason: 'status', status, status_by_name, status_at, version }
--   { ok: false, reason: 'archived' }
create or replace function public.save_room_document(
  p_room_id          uuid,
  p_document         jsonb,
  p_schema_version   int,
  p_expected_version int,
  p_demote           boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_rooms%rowtype;
begin
  select * into r from public.design_rooms where room_id = p_room_id;
  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
  perform public.design_require(r.team_id, 'can_create_estimates');
  perform public.design_required_object(p_document, 'Room document');
  if p_schema_version is null then
    raise exception 'Schema version is required' using errcode = '22023';
  end if;
  if r.archived_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'archived');
  end if;

  update public.design_rooms set
    document       = p_document,
    schema_version = p_schema_version,
    version        = version + 1,
    updated_by     = v_uid,
    updated_at     = now(),
    status_by      = case when status <> 'drafting' then v_uid else status_by end,
    status_at      = case when status <> 'drafting' then now() else status_at end,
    status         = 'drafting'
  where room_id = p_room_id
    and version = p_expected_version
    and (status = 'drafting' or coalesce(p_demote, false))
  returning * into r;

  if found then
    return jsonb_build_object('ok', true, 'version', r.version,
                              'updated_at', r.updated_at, 'status', r.status);
  end if;

  select * into r from public.design_rooms where room_id = p_room_id;
  if r.version <> p_expected_version then
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object(
    'ok', false, 'reason', 'status', 'status', r.status,
    'status_by_name', public.design_user_name(r.team_id, r.status_by),
    'status_at', r.status_at, 'version', r.version
  );
end;
$$;

-- Drafting / Approved / Released. p_expected_version makes sure the status is set on the
-- document the user is looking at. Does not bump `version`.
create or replace function public.set_room_status(
  p_room_id          uuid,
  p_status           text,
  p_expected_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_rooms%rowtype;
begin
  select * into r from public.design_rooms where room_id = p_room_id;
  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
  perform public.design_require(r.team_id, 'can_create_estimates');
  if p_status is null or p_status not in ('drafting', 'approved', 'released') then
    raise exception 'Unknown status %', p_status using errcode = '22023';
  end if;

  update public.design_rooms
  set status = p_status, status_by = v_uid, status_at = now()
  where room_id = p_room_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_rooms where room_id = p_room_id;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'status', r.status, 'status_at', r.status_at,
                            'version', r.version);
end;
$$;

-- Issue: freeze the current draft as the next version (seq 1, 2, 3… per room).
-- JS supplies the label (prefilled "KC 10/13/26"), an optional note and the resolved
-- team + project + phase settings snapshot. p_expected_version makes sure the frozen
-- document is the one the user saw.
create or replace function public.issue_room_version(
  p_room_id           uuid,
  p_label             text,
  p_note              text,
  p_settings_snapshot jsonb,
  p_expected_version  int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_rooms%rowtype;
  v_seq int;
  v_id  uuid;
  v_at  timestamptz;
begin
  select * into r from public.design_rooms where room_id = p_room_id for update;
  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
  perform public.design_require(r.team_id, 'can_create_estimates');
  perform public.design_required_object(p_settings_snapshot, 'Settings snapshot');

  if r.version <> p_expected_version then
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq
  from public.design_room_versions where room_id = p_room_id;

  insert into public.design_room_versions
    (room_id, team_id, seq, label, note, document, schema_version, settings_snapshot, issued_by)
  values (
    r.room_id, r.team_id, v_seq,
    public.design_required_text(p_label, 'Version label'),
    nullif(trim(p_note), ''),
    r.document, r.schema_version, p_settings_snapshot, v_uid
  )
  returning version_id, issued_at into v_id, v_at;

  return jsonb_build_object('ok', true, 'version_id', v_id, 'seq', v_seq,
                            'label', trim(p_label), 'issued_at', v_at);
end;
$$;

-- ---------------------------------------------------------------------------------------
-- Shop standard
-- ---------------------------------------------------------------------------------------

-- p_expected_version = 0 creates the team's row (first save); otherwise version-checked.
create or replace function public.save_team_settings(
  p_team_id          uuid,
  p_settings         jsonb,
  p_expected_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_team_settings%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_settings, 'Settings');

  if p_expected_version = 0 then
    insert into public.design_team_settings (team_id, settings, version, updated_by)
    values (p_team_id, p_settings, 1, v_uid)
    on conflict (team_id) do nothing
    returning * into r;
  else
    update public.design_team_settings
    set settings = p_settings, version = version + 1, updated_by = v_uid, updated_at = now()
    where team_id = p_team_id and version = p_expected_version
    returning * into r;
  end if;

  if not found then
    select * into r from public.design_team_settings where team_id = p_team_id;
    if not found then
      raise exception 'No shop standard saved yet (use expected version 0)' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'version', r.version, 'updated_at', r.updated_at);
end;
$$;

-- ---------------------------------------------------------------------------------------
-- Library (profiles, door designs). Archive, never delete (DB8).
-- ---------------------------------------------------------------------------------------

-- p_expected_version = 0 inserts (p_profile_id optional; JS may supply its own uuid);
-- otherwise updates that profile if the version matches. Null p_sort = end of list /
-- unchanged.
create or replace function public.save_profile(
  p_team_id          uuid,
  p_profile_id       uuid,
  p_kind             text,
  p_name             text,
  p_data             jsonb,
  p_sort             int,
  p_expected_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_profiles%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_data, 'Profile data');

  if p_expected_version = 0 then
    insert into public.design_profiles
      (profile_id, team_id, kind, name, data, sort, created_by, updated_by)
    values (
      coalesce(p_profile_id, public.design_uuidv7()), p_team_id,
      public.design_required_text(p_kind, 'Profile kind'),
      public.design_required_text(p_name, 'Profile name'),
      p_data,
      coalesce(p_sort, (select coalesce(max(sort) + 1, 0) from public.design_profiles
                        where team_id = p_team_id)),
      v_uid, v_uid
    )
    returning * into r;
    return jsonb_build_object('ok', true, 'profile_id', r.profile_id, 'version', r.version,
                              'updated_at', r.updated_at);
  end if;

  update public.design_profiles set
    kind = public.design_required_text(p_kind, 'Profile kind'),
    name = public.design_required_text(p_name, 'Profile name'),
    data = p_data,
    sort = coalesce(p_sort, sort),
    version = version + 1, updated_by = v_uid, updated_at = now()
  where profile_id = p_profile_id and team_id = p_team_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_profiles
    where profile_id = p_profile_id and team_id = p_team_id;
    if not found then
      raise exception 'Profile not found' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'profile_id', r.profile_id, 'version', r.version,
                            'updated_at', r.updated_at);
end;
$$;

-- Same contract as save_profile. A live design with the same code (ignoring case)
-- raises 23505.
create or replace function public.save_door_design(
  p_team_id          uuid,
  p_design_id        uuid,
  p_code             text,
  p_data             jsonb,
  p_sort             int,
  p_expected_version int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_door_designs%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_data, 'Door design data');

  if p_expected_version = 0 then
    insert into public.design_door_designs
      (design_id, team_id, code, data, sort, created_by, updated_by)
    values (
      coalesce(p_design_id, public.design_uuidv7()), p_team_id,
      public.design_required_text(p_code, 'Door design code'),
      p_data,
      coalesce(p_sort, (select coalesce(max(sort) + 1, 0) from public.design_door_designs
                        where team_id = p_team_id)),
      v_uid, v_uid
    )
    returning * into r;
    return jsonb_build_object('ok', true, 'design_id', r.design_id, 'version', r.version,
                              'updated_at', r.updated_at);
  end if;

  update public.design_door_designs set
    code = public.design_required_text(p_code, 'Door design code'),
    data = p_data,
    sort = coalesce(p_sort, sort),
    version = version + 1, updated_by = v_uid, updated_at = now()
  where design_id = p_design_id and team_id = p_team_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_door_designs
    where design_id = p_design_id and team_id = p_team_id;
    if not found then
      raise exception 'Door design not found' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'design_id', r.design_id, 'version', r.version,
                            'updated_at', r.updated_at);
end;
$$;

-- Archive (or restore) a library item. p_kind: 'profile' | 'door_design'.
-- Restoring a door design whose code is now taken raises 23505.
create or replace function public.archive_library_item(
  p_kind     text,
  p_id       uuid,
  p_archived boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team uuid;
begin
  if p_kind = 'profile' then
    select team_id into v_team from public.design_profiles where profile_id = p_id;
  elsif p_kind = 'door_design' then
    select team_id into v_team from public.design_door_designs where design_id = p_id;
  else
    raise exception 'Unknown library kind %', p_kind using errcode = '22023';
  end if;
  if v_team is null then
    raise exception 'Library item not found' using errcode = 'P0002';
  end if;
  perform public.design_require(v_team, 'can_manage_teams');

  if p_kind = 'profile' then
    update public.design_profiles
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where profile_id = p_id;
  else
    update public.design_door_designs
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where design_id = p_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------
-- Import (round D7): the localStorage document in one transaction.
-- ---------------------------------------------------------------------------------------
-- JS does the thinking (validates, maps old string ids to new uuids and rewrites the room
-- documents); this only writes. Any error rolls back everything.
--
-- p_bundle = {
--   "settings": { ... } | null,              -- shop standard (needs can_manage_teams)
--   "settingsExpectedVersion": 0 | n,        -- required with settings; 0 = team has none yet
--   "profiles":    [{ "profile_id", "kind", "name", "data", "sort" }],      -- optional
--   "doorDesigns": [{ "design_id", "code", "data", "sort" }],               -- optional
--   "project": { "est_project_name", "est_client_name", ... },  -- required with rooms
--   "phaseName": "Imported",                                    -- default "Imported"
--   "rooms": [{ "room_id"?, "name", "document", "schema_version" }]         -- optional
-- }
-- Returns { ok, settings_version, profile_ids, design_ids, est_project_id, phase_id, room_ids }.
create or replace function public.import_design_bundle(p_team_id uuid, p_bundle jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_item         jsonb;
  v_ord          int;
  v_expected     int;
  v_settings_ver int;
  v_profile_ids  jsonb := '[]'::jsonb;
  v_design_ids   jsonb := '[]'::jsonb;
  v_room_ids     jsonb := '[]'::jsonb;
  v_project_id   bigint;
  v_phase_id     uuid;
  v_id           uuid;
  v_has_library  boolean;
  v_has_rooms    boolean;
begin
  perform public.design_required_object(p_bundle, 'Import bundle');

  v_has_library := coalesce(jsonb_typeof(p_bundle -> 'settings'), '') = 'object'
    or jsonb_array_length(coalesce(p_bundle -> 'profiles', '[]'::jsonb)) > 0
    or jsonb_array_length(coalesce(p_bundle -> 'doorDesigns', '[]'::jsonb)) > 0;
  v_has_rooms := jsonb_array_length(coalesce(p_bundle -> 'rooms', '[]'::jsonb)) > 0;

  if v_has_library then
    perform public.design_require(p_team_id, 'can_manage_teams');
  end if;
  if v_has_rooms or not v_has_library then
    perform public.design_require(p_team_id, 'can_create_estimates');
  end if;

  -- Shop standard
  if jsonb_typeof(p_bundle -> 'settings') = 'object' then
    v_expected := (p_bundle ->> 'settingsExpectedVersion')::int;
    if v_expected is null then
      raise exception 'settingsExpectedVersion is required with settings' using errcode = '22023';
    end if;
    if v_expected = 0 then
      insert into public.design_team_settings (team_id, settings, version, updated_by)
      values (p_team_id, p_bundle -> 'settings', 1, v_uid)
      on conflict (team_id) do nothing
      returning version into v_settings_ver;
    else
      update public.design_team_settings
      set settings = p_bundle -> 'settings', version = version + 1,
          updated_by = v_uid, updated_at = now()
      where team_id = p_team_id and version = v_expected
      returning version into v_settings_ver;
    end if;
    if v_settings_ver is null then
      raise exception 'The shop standard changed since the import was prepared; nothing was imported'
        using errcode = '40001';
    end if;
  end if;

  -- Profiles
  for v_item, v_ord in
    select value, ordinality::int
    from jsonb_array_elements(coalesce(p_bundle -> 'profiles', '[]'::jsonb)) with ordinality
  loop
    insert into public.design_profiles
      (profile_id, team_id, kind, name, data, sort, created_by, updated_by)
    values (
      coalesce((v_item ->> 'profile_id')::uuid, public.design_uuidv7()), p_team_id,
      public.design_required_text(v_item ->> 'kind', 'Profile kind'),
      public.design_required_text(v_item ->> 'name', 'Profile name'),
      public.design_required_object(v_item -> 'data', 'Profile data'),
      coalesce((v_item ->> 'sort')::int, v_ord - 1),
      v_uid, v_uid
    )
    returning profile_id into v_id;
    v_profile_ids := v_profile_ids || to_jsonb(v_id);
  end loop;

  -- Door designs
  for v_item, v_ord in
    select value, ordinality::int
    from jsonb_array_elements(coalesce(p_bundle -> 'doorDesigns', '[]'::jsonb)) with ordinality
  loop
    insert into public.design_door_designs
      (design_id, team_id, code, data, sort, created_by, updated_by)
    values (
      coalesce((v_item ->> 'design_id')::uuid, public.design_uuidv7()), p_team_id,
      public.design_required_text(v_item ->> 'code', 'Door design code'),
      public.design_required_object(v_item -> 'data', 'Door design data'),
      coalesce((v_item ->> 'sort')::int, v_ord - 1),
      v_uid, v_uid
    )
    returning design_id into v_id;
    v_design_ids := v_design_ids || to_jsonb(v_id);
  end loop;

  -- Project, phase, rooms
  if v_has_rooms then
    if coalesce(jsonb_typeof(p_bundle -> 'project'), '') <> 'object' then
      raise exception 'Project details are required to import rooms' using errcode = '22023';
    end if;
    insert into public.estimate_projects
      (est_project_name, est_client_name, street, city, state, zip, team_id)
    values (
      public.design_required_text(p_bundle -> 'project' ->> 'est_project_name', 'Project name'),
      nullif(trim(p_bundle -> 'project' ->> 'est_client_name'), ''),
      nullif(trim(p_bundle -> 'project' ->> 'street'), ''),
      nullif(trim(p_bundle -> 'project' ->> 'city'), ''),
      nullif(trim(p_bundle -> 'project' ->> 'state'), ''),
      nullif(trim(p_bundle -> 'project' ->> 'zip'), ''),
      p_team_id
    )
    returning est_project_id into v_project_id;

    insert into public.design_projects (est_project_id, team_id, created_by, updated_by)
    values (v_project_id, p_team_id, v_uid, v_uid);

    insert into public.design_phases (team_id, est_project_id, name, sort, created_by, updated_by)
    values (p_team_id, v_project_id,
            coalesce(nullif(trim(p_bundle ->> 'phaseName'), ''), 'Imported'), 0, v_uid, v_uid)
    returning phase_id into v_phase_id;

    for v_item, v_ord in
      select value, ordinality::int
      from jsonb_array_elements(p_bundle -> 'rooms') with ordinality
    loop
      if (v_item ->> 'schema_version') is null then
        raise exception 'Room % has no schema_version', v_ord using errcode = '22023';
      end if;
      insert into public.design_rooms
        (room_id, team_id, phase_id, name, sort, document, schema_version, created_by, updated_by)
      values (
        coalesce((v_item ->> 'room_id')::uuid, public.design_uuidv7()), p_team_id, v_phase_id,
        public.design_required_text(v_item ->> 'name', 'Room name'),
        v_ord - 1,
        public.design_required_object(v_item -> 'document', 'Room document'),
        (v_item ->> 'schema_version')::int,
        v_uid, v_uid
      )
      returning room_id into v_id;
      v_room_ids := v_room_ids || to_jsonb(v_id);
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'settings_version', v_settings_ver,
    'profile_ids', v_profile_ids,
    'design_ids', v_design_ids,
    'est_project_id', v_project_id,
    'phase_id', v_phase_id,
    'room_ids', v_room_ids
  );
end;
$$;

-- =======================================================================================
-- 6. Function privileges
-- =======================================================================================

-- Internal helpers: not callable through the API.
revoke all on function public.design_require(uuid, text) from public, anon, authenticated;
revoke all on function public.design_conflict(uuid, int, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.design_required_text(text, text) from public, anon, authenticated;
revoke all on function public.design_required_object(jsonb, text) from public, anon, authenticated;
revoke all on function public.design_versions_frozen() from public, anon, authenticated;

-- Used inside RLS-invoker read functions and column defaults, so signed-in users need them.
revoke all on function public.design_user_name(uuid, uuid) from public, anon;
grant execute on function public.design_user_name(uuid, uuid) to authenticated;
revoke all on function public.design_uuidv7() from public, anon;
grant execute on function public.design_uuidv7() to authenticated;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.list_design_projects(uuid, boolean)',
    'public.list_attachable_estimate_projects(uuid, text)',
    'public.get_design_project(bigint)',
    'public.list_design_room_versions(uuid)',
    'public.create_design_project(uuid, bigint, jsonb, text, text, jsonb, int)',
    'public.update_design_project_info(bigint, jsonb)',
    'public.archive_design_project(bigint, boolean)',
    'public.save_project_overrides(bigint, jsonb, int)',
    'public.create_design_phase(bigint, text)',
    'public.update_design_phase(uuid, text, int, boolean)',
    'public.save_phase_overrides(uuid, jsonb, int)',
    'public.create_design_room(uuid, text, jsonb, int)',
    'public.copy_design_room(uuid, uuid, text, jsonb, int)',
    'public.update_design_room_info(uuid, text, int, boolean)',
    'public.save_room_document(uuid, jsonb, int, int, boolean)',
    'public.set_room_status(uuid, text, int)',
    'public.issue_room_version(uuid, text, text, jsonb, int)',
    'public.save_team_settings(uuid, jsonb, int)',
    'public.save_profile(uuid, uuid, text, text, jsonb, int, int)',
    'public.save_door_design(uuid, uuid, text, jsonb, int, int)',
    'public.archive_library_item(text, uuid, boolean)',
    'public.import_design_bundle(uuid, jsonb)'
  ]
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

commit;

-- =======================================================================================
-- Checks (run after applying)
-- =======================================================================================
-- a) Seven tables, RLS on, one SELECT policy each and nothing else:
--    select tablename, policyname, cmd from pg_policies
--    where schemaname = 'public' and tablename like 'design\_%' order by 1;
--    -> 7 rows, all cmd = SELECT
--
-- b) No direct writes for signed-in users:
--    select table_name, privilege_type from information_schema.role_table_grants
--    where grantee = 'authenticated' and table_name like 'design\_%' order by 1, 2;
--    -> only SELECT (plus REFERENCES/TRIGGER if Supabase granted them by default)
--
-- c) UUIDv7 looks right (13th hex digit is 7; values sort by time):
--    select public.design_uuidv7() from generate_series(1, 3);
--
-- d) In the designer or ff-job-schedule browser console, signed in:
--      await supabase.rpc('list_design_projects', { p_team_id: '<your team id>' })
--    -> { data: [], error: null }
--      await supabase.from('design_rooms').insert({})
--    -> an error (permission denied), nothing inserted
--
-- e) The estimator still lists, opens and saves estimates as before.
