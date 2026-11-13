-- Designer presence (SPEC-DB6a.1): who has which room open, through Supabase Realtime Presence.
-- One private channel per project, topic `design-project:<est_project_id>`. Only people who can
-- view designs on that project's team can join it or share their presence there.
-- Nothing is stored: Presence lives in Realtime's memory. This file only adds the access check.
--
-- Also in the dashboard (once): Project Settings → Realtime → turn OFF "Allow public access",
-- so private channels are enforced. No app uses Realtime channels today, so nothing else breaks.

begin;

-- true when the topic is `design-project:<id>`, that project is in the designer, and the
-- current user can view designs on its team.
create or replace function public.design_can_use_project_topic(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_team uuid;
begin
  if p_topic is null or p_topic !~ '^design-project:[0-9]{1,18}$' then
    return false;
  end if;
  select dp.team_id into v_team
  from public.design_projects dp
  where dp.est_project_id = split_part(p_topic, ':', 2)::bigint;
  if v_team is null then
    return false;
  end if;
  return public.can_read_estimate_team(v_team);
end;
$$;

revoke all on function public.design_can_use_project_topic(text) from public, anon;
grant execute on function public.design_can_use_project_topic(text) to authenticated;

drop policy if exists "Designer presence: listen" on realtime.messages;
create policy "Designer presence: listen"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'presence'
    and public.design_can_use_project_topic((select realtime.topic()))
  );

drop policy if exists "Designer presence: share" on realtime.messages;
create policy "Designer presence: share"
  on realtime.messages
  for insert
  to authenticated
  with check (
    realtime.messages.extension = 'presence'
    and public.design_can_use_project_topic((select realtime.topic()))
  );

commit;

-- Checks (run after applying):
-- a) select public.design_can_use_project_topic('design-project:' || (select est_project_id from design_projects limit 1));
--    → true in the SQL editor only if run as a team member; as postgres it is false (no auth.uid()), which is expected.
-- b) select public.design_can_use_project_topic('design-project:abc'), public.design_can_use_project_topic('other:1');  → false, false
-- c) select polname from pg_policy where polrelid = 'realtime.messages'::regclass;  → includes both "Designer presence" policies
