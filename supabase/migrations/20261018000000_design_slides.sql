-- Migration: designer drawer slide library (SPEC-IN4a, 2026-10-18)
--
-- Adds design_slides: the drawer slides (drawer guides) the designer sizes drawer boxes and
-- roll-outs from (INTERIORS-PLAN ID10). The estimator's hardware_slides is NOT changed. It keeps
-- its slides for pricing; a design slide may point at the one it is priced as
-- (hardware_slide_id). Later, once the designer and estimator are connected, the estimator
-- moves onto design_slides and hardware_slides is retired (same path as pulls).
--
-- Same rules as the other library tables (20261014000000_design_tables.sql, ..._design_pulls.sql):
--   - RLS with a SELECT policy only; writes go through save_slide / archive_library_item.
--   - view = can_read_estimate_team, manage = can_manage_teams.
--   - `version` counter; a stale version saves nothing and returns the conflict reply.
--   - Archive, never delete. Names are unique per team among live slides, ignoring case.
--   - No rows are seeded here: the designer seeds its built-in slides (Blum Tandem 562H,
--     Accuride 3832, Accuride 4034) on first load (data.seedId), as it does for pulls (IN4b).
--
-- data (validated in the designer, only "is an object" here), sizes in inches:
--   { brand?, model?, description?, cvName?,
--     mount: 'undermount' | 'side',
--     lengths: [{ nominal, length?, extension? }, ...],
--     sideClearance,            -- per side; box width = opening - 2 x sideClearance
--     minBelow, minAbove,       -- clear space the slide needs below / above the box
--     height,                   -- slide height (side-mount boxes shorter than this warn)
--     clips, softClose, heavyDuty,   -- booleans
--     seedId? }
--
-- Run the whole file once in the Supabase SQL editor (one transaction). Safe to re-run.

begin;

-- =======================================================================================
-- 1. Table
-- =======================================================================================

create table if not exists public.design_slides (
  slide_id           uuid primary key default public.design_uuidv7(),
  team_id            uuid not null references public.teams (team_id) on delete restrict,
  name               text not null check (trim(name) <> ''),
  data               jsonb not null check (jsonb_typeof(data) = 'object'),
  -- The estimator slide this one is priced as. The estimator still hard-deletes its slides,
  -- so a delete there just clears the link.
  hardware_slide_id  bigint references public.hardware_slides (id) on delete set null,
  version            int not null default 1,
  sort               int not null default 0,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_by         uuid,
  updated_at         timestamptz not null default now(),
  archived_at        timestamptz
);
create index if not exists design_slides_team_idx on public.design_slides (team_id, sort);
create unique index if not exists design_slides_name_idx
  on public.design_slides (team_id, lower(trim(name)))
  where archived_at is null;
create index if not exists design_slides_hardware_idx
  on public.design_slides (hardware_slide_id) where hardware_slide_id is not null;

-- =======================================================================================
-- 2. RLS: select only
-- =======================================================================================

alter table public.design_slides enable row level security;

drop policy if exists "View with estimate permission" on public.design_slides;
create policy "View with estimate permission" on public.design_slides
  for select to authenticated using (public.can_read_estimate_team(team_id));

revoke insert, update, delete, truncate on public.design_slides from anon, authenticated;
revoke all on public.design_slides from anon;

-- =======================================================================================
-- 3. RPCs
-- =======================================================================================

-- Same contract as save_pull: p_expected_version = 0 inserts (p_slide_id optional; JS may
-- supply its own uuid); otherwise updates that slide if the version matches. Null p_sort =
-- end of list / unchanged. p_hardware_slide_id is written as given (null clears it) and must
-- be one of the team's estimator slides. A live slide with the same name (ignoring case and
-- outer spaces) raises 23505.
create or replace function public.save_slide(
  p_team_id           uuid,
  p_slide_id          uuid,
  p_name              text,
  p_data              jsonb,
  p_hardware_slide_id bigint,
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
  r     public.design_slides%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_data, 'Slide data');

  if p_hardware_slide_id is not null and not exists (
    select 1 from public.hardware_slides hs
    where hs.id = p_hardware_slide_id and hs.team_id = p_team_id
  ) then
    raise exception 'Estimating slide not found' using errcode = 'P0002';
  end if;

  if p_expected_version = 0 then
    insert into public.design_slides
      (slide_id, team_id, name, data, hardware_slide_id, sort, created_by, updated_by)
    values (
      coalesce(p_slide_id, public.design_uuidv7()), p_team_id,
      public.design_required_text(p_name, 'Slide name'),
      p_data,
      p_hardware_slide_id,
      coalesce(p_sort, (select coalesce(max(sort) + 1, 0) from public.design_slides
                        where team_id = p_team_id)),
      v_uid, v_uid
    )
    returning * into r;
    return jsonb_build_object('ok', true, 'slide_id', r.slide_id, 'version', r.version,
                              'updated_at', r.updated_at);
  end if;

  update public.design_slides set
    name = public.design_required_text(p_name, 'Slide name'),
    data = p_data,
    hardware_slide_id = p_hardware_slide_id,
    sort = coalesce(p_sort, sort),
    version = version + 1, updated_by = v_uid, updated_at = now()
  where slide_id = p_slide_id and team_id = p_team_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_slides
    where slide_id = p_slide_id and team_id = p_team_id;
    if not found then
      raise exception 'Slide not found' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'slide_id', r.slide_id, 'version', r.version,
                            'updated_at', r.updated_at);
end;
$$;

-- Replaces the HP3a version: adds p_kind 'slide'. 'profile', 'door_design' and 'pull' are
-- unchanged. Restoring a door design, pull or slide whose code/name is now taken raises 23505.
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
  else
    update public.design_slides
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where slide_id = p_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.save_slide(uuid, uuid, text, jsonb, bigint, int, int) from public, anon;
grant execute on function public.save_slide(uuid, uuid, text, jsonb, bigint, int, int) to authenticated;
revoke all on function public.archive_library_item(text, uuid, boolean) from public, anon;
grant execute on function public.archive_library_item(text, uuid, boolean) to authenticated;

commit;

-- =======================================================================================
-- Checks (run after applying)
-- =======================================================================================
-- a) One SELECT policy, RLS on:
--    select policyname, cmd from pg_policies where tablename = 'design_slides';
--    -> 1 row, cmd = SELECT
--
-- b) No direct writes for signed-in users:
--    select privilege_type from information_schema.role_table_grants
--    where grantee = 'authenticated' and table_name = 'design_slides';
--    -> only SELECT (plus REFERENCES/TRIGGER if Supabase granted them by default)
--
-- c) In the designer browser console, signed in as a team manager:
--      await supabase.rpc('save_slide', { p_team_id: '<team id>', p_slide_id: null,
--        p_name: 'Test slide', p_data: { mount: 'side', lengths: [{ nominal: 8 }],
--        sideClearance: 0.5, minBelow: 0.5625, minAbove: 0.25, height: 1.796875,
--        clips: false, softClose: false, heavyDuty: true },
--        p_hardware_slide_id: null, p_sort: null, p_expected_version: 0 })
--    -> { ok: true, slide_id, version: 1, ... }
--      await supabase.rpc('archive_library_item', { p_kind: 'slide', p_id: '<slide_id>' })
--    -> { ok: true }
--    (Archive the test slide before IN4b's first load; its name doesn't clash with the
--    built-ins, so leaving it is harmless too.)
--
-- d) Pulls still archive: archive_library_item('pull', ...) as before.
-- e) The estimator's Hardware settings still list, add and delete slides as before.
