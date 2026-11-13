-- Migration: designer accessory library (SPEC-IN12a, 2026-10-19)
--
-- Adds design_accessories: the cabinet accessories the designer places in interiors
-- (INTERIORS-PLAN ID22): section fills (organizers, inserts, closet items) and accessories
-- that live on a drawer box (a charging unit). The estimator's accessories_catalog and
-- accessory_time_anchors are NOT changed and NOT linked: a design accessory carries its own
-- pricing and labour in data (Kyle 2026-10-19: designer libraries are their own, more detailed
-- tables). Later, once the designer and estimator are connected, the estimator moves onto
-- design_accessories.
--
-- Same rules as the other library tables (20261014000000_design_tables.sql, ..._design_pulls.sql,
-- ..._design_slides.sql):
--   - RLS with a SELECT policy only; writes go through save_accessory / archive_library_item.
--   - view = can_read_estimate_team, manage = can_manage_teams.
--   - `version` counter; a stale version saves nothing and returns the conflict reply.
--   - Archive, never delete. Names are unique per team among live accessories, ignoring case
--     and outer spaces.
--   - No rows are seeded here (and the designer seeds none either: the library starts empty
--     and is filled from Kyle's list, SPEC-IN12b).
--
-- data (validated in the designer, only "is an object" here; shape in SPEC-IN12b §1), inches:
--   { brand, model, description, reportText,
--     attachesTo: 'section' | 'drawer_box',
--     wholeSection,                          -- boolean: takes the whole section
--     minOpening: { width, depth, height },  -- each a number or null
--     ownSlides,                             -- boolean: brings its own slides
--     effects: [],                           -- fixed vocabulary, IN12c
--     pricing: 'unit' | 'area' | 'length' | 'perimeter' | 'volume',   -- as calculation_type
--     price, actualCost,                     -- per pricing unit, number or null
--     labor: { "<team_service_id>": minutes per pricing unit } }
--   labor keys are team_services ids (the shop's services). No foreign key: a deleted service
--   just leaves a key the designer ignores and flags.
--
-- Run the whole file once in the Supabase SQL editor (one transaction). Safe to re-run.

begin;

-- =======================================================================================
-- 1. Table
-- =======================================================================================

create table if not exists public.design_accessories (
  accessory_id   uuid primary key default public.design_uuidv7(),
  team_id        uuid not null references public.teams (team_id) on delete restrict,
  name           text not null check (trim(name) <> ''),
  data           jsonb not null check (jsonb_typeof(data) = 'object'),
  version        int not null default 1,
  sort           int not null default 0,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_by     uuid,
  updated_at     timestamptz not null default now(),
  archived_at    timestamptz
);
create index if not exists design_accessories_team_idx on public.design_accessories (team_id, sort);
create unique index if not exists design_accessories_name_idx
  on public.design_accessories (team_id, lower(trim(name)))
  where archived_at is null;

-- =======================================================================================
-- 2. RLS: select only
-- =======================================================================================

alter table public.design_accessories enable row level security;

drop policy if exists "View with estimate permission" on public.design_accessories;
create policy "View with estimate permission" on public.design_accessories
  for select to authenticated using (public.can_read_estimate_team(team_id));

revoke insert, update, delete, truncate on public.design_accessories from anon, authenticated;
revoke all on public.design_accessories from anon;

-- =======================================================================================
-- 3. RPCs
-- =======================================================================================

-- Same contract as save_pull / save_slide (without an estimator link): p_expected_version = 0
-- inserts (p_accessory_id optional; JS may supply its own uuid); otherwise updates that
-- accessory if the version matches. Null p_sort = end of list / unchanged. A live accessory
-- with the same name (ignoring case and outer spaces) raises 23505.
create or replace function public.save_accessory(
  p_team_id           uuid,
  p_accessory_id      uuid,
  p_name              text,
  p_data              jsonb,
  p_sort              int,
  p_expected_version  int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r     public.design_accessories%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_data, 'Accessory data');

  if p_expected_version = 0 then
    insert into public.design_accessories
      (accessory_id, team_id, name, data, sort, created_by, updated_by)
    values (
      coalesce(p_accessory_id, public.design_uuidv7()), p_team_id,
      public.design_required_text(p_name, 'Accessory name'),
      p_data,
      coalesce(p_sort, (select coalesce(max(sort) + 1, 0) from public.design_accessories
                        where team_id = p_team_id)),
      v_uid, v_uid
    )
    returning * into r;
    return jsonb_build_object('ok', true, 'accessory_id', r.accessory_id, 'version', r.version,
                              'updated_at', r.updated_at);
  end if;

  update public.design_accessories set
    name = public.design_required_text(p_name, 'Accessory name'),
    data = p_data,
    sort = coalesce(p_sort, sort),
    version = version + 1, updated_by = v_uid, updated_at = now()
  where accessory_id = p_accessory_id and team_id = p_team_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_accessories
    where accessory_id = p_accessory_id and team_id = p_team_id;
    if not found then
      raise exception 'Accessory not found' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'accessory_id', r.accessory_id, 'version', r.version,
                            'updated_at', r.updated_at);
end;
$$;

-- Replaces the IN4a version: adds p_kind 'accessory'. 'profile', 'door_design', 'pull' and
-- 'slide' are unchanged. Restoring a door design, pull, slide or accessory whose code/name is
-- now taken raises 23505.
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
  elsif p_kind = 'slide' then
    select team_id into v_team from public.design_slides where slide_id = p_id;
  elsif p_kind = 'accessory' then
    select team_id into v_team from public.design_accessories where accessory_id = p_id;
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
  elsif p_kind = 'pull' then
    update public.design_pulls
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where pull_id = p_id;
  elsif p_kind = 'slide' then
    update public.design_slides
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where slide_id = p_id;
  else
    update public.design_accessories
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where accessory_id = p_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.save_accessory(uuid, uuid, text, jsonb, int, int) from public, anon;
grant execute on function public.save_accessory(uuid, uuid, text, jsonb, int, int) to authenticated;
revoke all on function public.archive_library_item(text, uuid, boolean) from public, anon;
grant execute on function public.archive_library_item(text, uuid, boolean) to authenticated;

commit;

-- =======================================================================================
-- Checks (run after applying)
-- =======================================================================================
-- a) One SELECT policy, RLS on:
--    select policyname, cmd from pg_policies where tablename = 'design_accessories';
--    -> 1 row, cmd = SELECT
--
-- b) No direct writes for signed-in users:
--    select privilege_type from information_schema.role_table_grants
--    where grantee = 'authenticated' and table_name = 'design_accessories';
--    -> only SELECT (plus REFERENCES/TRIGGER if Supabase granted them by default)
--
-- c) In the designer browser console, signed in as a team manager:
--      await supabase.rpc('save_accessory', { p_team_id: '<team id>', p_accessory_id: null,
--        p_name: 'Test accessory', p_data: { attachesTo: 'section' },
--        p_sort: null, p_expected_version: 0 })
--    -> { ok: true, accessory_id, version: 1, ... }
--      await supabase.rpc('archive_library_item', { p_kind: 'accessory', p_id: '<accessory_id>' })
--    -> { ok: true }
--
-- d) Slides and pulls still archive: archive_library_item('slide' / 'pull', ...) as before.
-- e) The estimator's Accessories settings (and their time anchors) still work as before.
