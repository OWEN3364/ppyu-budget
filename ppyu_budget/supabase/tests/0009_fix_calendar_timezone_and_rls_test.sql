-- Run with: supabase db query --linked --file supabase/tests/0009_fix_calendar_timezone_and_rls_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- the insert policy rejects a created_by from a DIFFERENT household
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_b uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();

  -- household_id is A's (so is_household_member passes) but created_by points
  -- at a real household_members row belonging to B.
  begin
    insert into calendar_events (household_id, title, start_at, end_at, created_by)
    values (v_household_a, '남의 집 멤버로 위장', now(), now() + interval '1 hour', v_member_b);
  exception when others then
    v_raised := true;
  end;

  if not v_raised then
    raise exception 'TEST FAILED: insert with a created_by from another household was allowed';
  end if;
end $$;
rollback to savepoint sp1;

-- the insert policy still allows a legitimate same-household created_by
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_a uuid;
  v_event_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_id, '정상 일정', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  if v_event_id is null then
    raise exception 'TEST FAILED: a legitimate same-household insert was rejected';
  end if;
end $$;
rollback to savepoint sp2;

-- a household-mate can DELETE an event they did not create
-- (0008's test comment claims update/delete coverage but only exercises update)
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_member_a uuid;
  v_invite_code text;
  v_event_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_id and user_id = auth.uid();
  v_invite_code := create_invite_code(v_household_id);
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_id, '삭제될 일정', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  perform join_household(v_invite_code);
  delete from calendar_events where id = v_event_id;

  select count(*) into v_count from calendar_events where id = v_event_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: a household-mate could not delete an event created by another member';
  end if;
end $$;
rollback to savepoint sp3;

rollback;
