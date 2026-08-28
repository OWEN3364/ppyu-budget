-- Run with: supabase db query --linked --file supabase/tests/0008_calendar_events_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- a household's calendar events are invisible to a non-member
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_event_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_a, '병원 예약', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select count(*) into v_count from calendar_events where id = v_event_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: household B could see household A''s calendar event';
  end if;
end $$;
rollback to savepoint sp1;

-- any member of the SAME household can update/delete an event created by another member
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_a uuid;
  v_invite_code text;
  v_event_id uuid;
  v_title text;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_id and user_id = auth.uid();
  v_invite_code := create_invite_code(v_household_id);
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_id, '원래 제목', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  perform join_household(v_invite_code);
  update calendar_events set title = '수정된 제목' where id = v_event_id;

  select title into v_title from calendar_events where id = v_event_id;
  if v_title != '수정된 제목' then
    raise exception 'TEST FAILED: expected a household-mate to be able to update the event, got %', v_title;
  end if;
end $$;
rollback to savepoint sp2;

rollback;
