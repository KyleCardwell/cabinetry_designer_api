-- Migration: designer pull library (SPEC-HP3a, 2026-10-16)
--
-- Adds design_pulls: the specific pulls, knobs and tab pulls the designer draws.
-- The estimator's hardware_pulls is NOT changed. It keeps its few general pulls for pricing;
-- a design pull may point at the one it is priced as (hardware_pull_id). Later, once the
-- designer and estimator are connected, the estimator moves onto design_pulls and
-- hardware_pulls is retired (HINGES-PULLS-PLAN).
--
-- Same rules as the other library tables (20261014000000_design_tables.sql):
--   - RLS with a SELECT policy only; writes go through save_pull / archive_library_item.
--   - view = can_read_estimate_team, manage = can_manage_teams.
--   - `version` counter; a stale version saves nothing and returns the conflict reply.
--   - Archive, never delete. Names are unique per team among live pulls, ignoring case.
--   - No rows are seeded here: the designer seeds its built-in pulls on first load
--     (data.seedId), as it does for door designs.
--
-- data (validated in the designer, only "is an object" here):
--   { kind: 'pull' | 'knob' | 'tab', length?, diameter?, projection?, seedId? }   inches
--
-- Run the whole file once in the Supabase SQL editor (one transaction). Safe to re-run.

begin;

-- =======================================================================================
-- 1. Table
-- =======================================================================================

create table if not exists public.design_pulls (
  pull_id           uuid primary key default public.design_uuidv7(),
  team_id           uuid not null references public.teams (team_id) on delete restrict,
  name              text not null check (trim(name) <> ''),
  data              jsonb not null check (jsonb_typeof(data) = 'object'),
  -- The estimator pull this one is priced as. The estimator still hard-deletes its pulls,
  -- so a delete there just clears the link.
  hardware_pull_id  bigint references public.hardware_pulls (id) on delete set null,
  version           int not null default 1,
  sort              int not null default 0,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_by        uuid,
  updated_at        timestamptz not null default now(),
  archived_at       timestamptz
);
create index if not exists design_pulls_team_idx on public.design_pulls (team_id, sort);
create unique index if not exists design_pulls_name_idx
  on public.design_pulls (team_id, lower(trim(name)))
  where archived_at is null;
create index if not exists design_pulls_hardware_idx
  on public.design_pulls (hardware_pull_id) where hardware_pull_id is not null;

-- =======================================================================================
-- 2. RLS: select only
-- =======================================================================================

alter table public.design_pulls enable row level security;

drop policy if exists "View with estimate permission" on public.design_pulls;
create policy "View with estimate permission" on public.design_pulls
  for select to authenticated using (public.can_read_estimate_team(team_id));

revoke insert, update, delete, truncate on public.design_pulls from anon, authenticated;
revoke all on public.design_pulls from anon;

-- =======================================================================================
-- 3. RPCs
-- =======================================================================================

-- Same contract as save_door_design: p_expected_version = 0 inserts (p_pull_id optional;
-- JS may supply its own uuid); otherwise updates that pull if the version matches.
-- Null p_sort = end of list / unchanged. p_hardware_pull_id is written as given (null
-- clears it) and must be one of the team's estimator pulls. A live pull with the same
-- name (ignoring case and outer spaces) raises 23505.
create or replace function public.save_pull(
  p_team_id          uuid,
  p_pull_id          uuid,
  p_name             text,
  p_data             jsonb,
  p_hardware_pull_id bigint,
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
  r     public.design_pulls%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_data, 'Pull data');

  if p_hardware_pull_id is not null and not exists (
    select 1 from public.hardware_pulls hp
    where hp.id = p_hardware_pull_id and hp.team_id = p_team_id
  ) then
    raise exception 'Estimating pull not found' using errcode = 'P0002';
  end if;

  if p_expected_version = 0 then
    insert into public.design_pulls
      (pull_id, team_id, name, data, hardware_pull_id, sort, created_by, updated_by)
    values (
      coalesce(p_pull_id, public.design_uuidv7()), p_team_id,
      public.design_required_text(p_name, 'Pull name'),
      p_data,
      p_hardware_pull_id,
      coalesce(p_sort, (select coalesce(max(sort) + 1, 0) from public.design_pulls
                        where team_id = p_team_id)),
      v_uid, v_uid
    )
    returning * into r;
    return jsonb_build_object('ok', true, 'pull_id', r.pull_id, 'version', r.version,
                              'updated_at', r.updated_at);
  end if;

  update public.design_pulls set
    name = public.design_required_text(p_name, 'Pull name'),
    data = p_data,
    hardware_pull_id = p_hardware_pull_id,
    sort = coalesce(p_sort, sort),
    version = version + 1, updated_by = v_uid, updated_at = now()
  where pull_id = p_pull_id and team_id = p_team_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_pulls
    where pull_id = p_pull_id and team_id = p_team_id;
    if not found then
      raise exception 'Pull not found' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'pull_id', r.pull_id, 'version', r.version,
                            'updated_at', r.updated_at);
end;
$$;

-- Replaces the D3 version: adds p_kind 'pull'. 'profile' and 'door_design' are unchanged.
-- Restoring a door design or pull whose code/name is now taken raises 23505.
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
  elsif p_kind = 'pull' then
    select team_id into v_team from public.design_pulls where pull_id = p_id;
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
  elsif p_kind = 'door_design' then
    update public.design_door_designs
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where design_id = p_id;
  else
    update public.design_pulls
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where pull_id = p_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.save_pull(uuid, uuid, text, jsonb, bigint, int, int) from public, anon;
grant execute on function public.save_pull(uuid, uuid, text, jsonb, bigint, int, int) to authenticated;
revoke all on function public.archive_library_item(text, uuid, boolean) from public, anon;
grant execute on function public.archive_library_item(text, uuid, boolean) to authenticated;

commit;

-- =======================================================================================
-- Checks (run after applying)
-- =======================================================================================
-- a) One SELECT policy, RLS on:
--    select policyname, cmd from pg_policies where tablename = 'design_pulls';
--    -> 1 row, cmd = SELECT
--
-- b) No direct writes for signed-in users:
--    select privilege_type from information_schema.role_table_grants
--    where grantee = 'authenticated' and table_name = 'design_pulls';
--    -> only SELECT (plus REFERENCES/TRIGGER if Supabase granted them by default)
--
-- c) In the designer browser console, signed in as a team manager:
--      await supabase.rpc('save_pull', { p_team_id: '<team id>', p_pull_id: null,
--        p_name: 'Test 4" pull', p_data: { kind: 'pull', length: 4, projection: 1.25 },
--        p_hardware_pull_id: null, p_sort: null, p_expected_version: 0 })
--    -> { ok: true, pull_id, version: 1, ... }
--      await supabase.rpc('archive_library_item', { p_kind: 'pull', p_id: '<pull_id>' })
--    -> { ok: true }
--
-- d) The estimator's Hardware settings still list, add and delete pulls as before.
