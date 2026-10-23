-- Migration: designer shapes library (SPEC-SH1, 2026-10-23)
--
-- Adds design_shapes: the drawn shapes the designer places for things that aren't box parts
-- (SHAPES-PLAN SD1): accessories (closet rods and brackets, hooks, baskets...), appliances, and
-- leg/column profiles. A library row that is drawn (an accessory now; appliances and legs later)
-- points at a shape by its shape_id inside its own data (data.shapeId). No foreign key: the
-- pointing rows keep their data in jsonb, and an archived shape still draws (below).
--
-- Same rules as the other library tables (20261014000000_design_tables.sql, ..._design_pulls.sql,
-- ..._design_slides.sql, ..._design_accessories.sql):
--   - RLS with a SELECT policy only; writes go through save_shape / archive_library_item.
--   - view = can_read_estimate_team, manage = can_manage_teams.
--   - `version` counter (row concurrency); a stale version saves nothing and returns the
--     conflict reply.
--   - Archive, never delete. Names are unique per team among live shapes, ignoring case and
--     outer spaces.
--   - The designer lists every shape, archived ones too (like design_profiles): an accessory
--     that points at an archived shape still draws it in old rooms.
--   - No rows are seeded. Not in the import bundle.
--
-- data (validated in the designer, only "is an object" here; shape in SPEC-SH2 §1), inches:
--   { version,                      -- geometry version (P7): bumps when views, box or stretch
--                                   --   change, not on a rename. Separate from the row version.
--     kind: 'accessory' | 'appliance' | 'leg' | 'other',
--     box: { x, y, z, w, h, d },    -- nominal size W x H x D; x, y, z = its left / front /
--                                   --   bottom corner from the attach point 0,0,0
--     views: { front, plan?, side? },   -- each a profile geometry { units: 'in', points, loops }
--                                   --   front: x right, z up; plan: x right, y back;
--                                   --   side (seen from the right): y back, z up
--     stretch: { x?, y?, z? },      -- per axis, shared by every view: sorted [from, to] zones
--     notes? }
--   builder (SH5) and label (SH3) keys are added later, inside data, with no migration.
--
-- Run the whole file once in the Supabase SQL editor (one transaction). Safe to re-run.

begin;

-- =======================================================================================
-- 1. Table
-- =======================================================================================

create table if not exists public.design_shapes (
  shape_id       uuid primary key default public.design_uuidv7(),
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
create index if not exists design_shapes_team_idx on public.design_shapes (team_id, sort);
create unique index if not exists design_shapes_name_idx
  on public.design_shapes (team_id, lower(trim(name)))
  where archived_at is null;

-- =======================================================================================
-- 2. RLS: select only
-- =======================================================================================

alter table public.design_shapes enable row level security;

drop policy if exists "View with estimate permission" on public.design_shapes;
create policy "View with estimate permission" on public.design_shapes
  for select to authenticated using (public.can_read_estimate_team(team_id));

revoke insert, update, delete, truncate on public.design_shapes from anon, authenticated;
revoke all on public.design_shapes from anon;

-- =======================================================================================
-- 3. RPCs
-- =======================================================================================

-- Same contract as save_accessory: p_expected_version = 0 inserts (p_shape_id optional; JS may
-- supply its own uuid); otherwise updates that shape if the version matches. Null p_sort = end
-- of list / unchanged. A live shape with the same name (ignoring case and outer spaces) raises
-- 23505. Saving an archived shape keeps it archived.
create or replace function public.save_shape(
  p_team_id           uuid,
  p_shape_id          uuid,
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
  r     public.design_shapes%rowtype;
begin
  perform public.design_require(p_team_id, 'can_manage_teams');
  perform public.design_required_object(p_data, 'Shape data');

  if p_expected_version = 0 then
    insert into public.design_shapes
      (shape_id, team_id, name, data, sort, created_by, updated_by)
    values (
      coalesce(p_shape_id, public.design_uuidv7()), p_team_id,
      public.design_required_text(p_name, 'Shape name'),
      p_data,
      coalesce(p_sort, (select coalesce(max(sort) + 1, 0) from public.design_shapes
                        where team_id = p_team_id)),
      v_uid, v_uid
    )
    returning * into r;
    return jsonb_build_object('ok', true, 'shape_id', r.shape_id, 'version', r.version,
                              'updated_at', r.updated_at);
  end if;

  update public.design_shapes set
    name = public.design_required_text(p_name, 'Shape name'),
    data = p_data,
    sort = coalesce(p_sort, sort),
    version = version + 1, updated_by = v_uid, updated_at = now()
  where shape_id = p_shape_id and team_id = p_team_id and version = p_expected_version
  returning * into r;

  if not found then
    select * into r from public.design_shapes
    where shape_id = p_shape_id and team_id = p_team_id;
    if not found then
      raise exception 'Shape not found' using errcode = 'P0002';
    end if;
    return public.design_conflict(r.team_id, r.version, r.updated_by, r.updated_at);
  end if;
  return jsonb_build_object('ok', true, 'shape_id', r.shape_id, 'version', r.version,
                            'updated_at', r.updated_at);
end;
$$;

-- Replaces the IN12a version: adds p_kind 'shape'. 'profile', 'door_design', 'pull', 'slide'
-- and 'accessory' are unchanged. Restoring a door design, pull, slide, accessory or shape whose
-- code/name is now taken raises 23505.
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
  elsif p_kind = 'shape' then
    select team_id into v_team from public.design_shapes where shape_id = p_id;
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
  elsif p_kind = 'accessory' then
    update public.design_accessories
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where accessory_id = p_id;
  else
    update public.design_shapes
    set archived_at = case when p_archived then coalesce(archived_at, now()) else null end
    where shape_id = p_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.save_shape(uuid, uuid, text, jsonb, int, int) from public, anon;
grant execute on function public.save_shape(uuid, uuid, text, jsonb, int, int) to authenticated;
revoke all on function public.archive_library_item(text, uuid, boolean) from public, anon;
grant execute on function public.archive_library_item(text, uuid, boolean) to authenticated;

commit;

-- =======================================================================================
-- Checks (run after applying)
-- =======================================================================================
-- a) One SELECT policy, RLS on:
--    select policyname, cmd from pg_policies where tablename = 'design_shapes';
--    -> 1 row, cmd = SELECT
--
-- b) No direct writes for signed-in users:
--    select privilege_type from information_schema.role_table_grants
--    where grantee = 'authenticated' and table_name = 'design_shapes';
--    -> only SELECT (plus REFERENCES/TRIGGER if Supabase granted them by default)
--
-- c) In the designer browser console, signed in as a team manager:
--      await supabase.rpc('save_shape', { p_team_id: '<team id>', p_shape_id: null,
--        p_name: 'Test shape', p_data: { kind: 'other' },
--        p_sort: null, p_expected_version: 0 })
--    -> { ok: true, shape_id, version: 1, ... }
--      await supabase.rpc('archive_library_item', { p_kind: 'shape', p_id: '<shape_id>' })
--    -> { ok: true }
--
-- d) Accessories, slides and pulls still archive: archive_library_item('accessory' / 'slide' /
--    'pull', ...) as before.
