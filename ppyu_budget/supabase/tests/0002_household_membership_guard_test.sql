-- Run with: supabase db query --linked --file supabase/tests/0002_household_membership_guard_test.sql
begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;
insert into auth.users (id, email) values ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;
insert into auth.users (id, email) values ('33333333-3333-3333-3333-333333333333', 'c@test.com')
  on conflict do nothing;

-- get_my_household: null before joining, correct id after
-- (each block below rolls back to a savepoint afterward so the same three
-- simulated users start each block with no household, since a user can now
-- only ever have one)
savepoint sp1;
do $$
declare
  v_household_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

  if get_my_household() is not null then
    raise exception 'TEST FAILED: get_my_household should be null before any membership';
  end if;

  v_household_id := create_household_and_owner();

  if get_my_household() != v_household_id then
    raise exception 'TEST FAILED: get_my_household should return the household just created';
  end if;
end $$;
rollback to savepoint sp1;

-- create_household_and_owner: a user with a household cannot create a second one
savepoint sp2;
do $$
declare
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  perform create_household_and_owner();

  begin
    perform create_household_and_owner();
  exception when others then
    v_raised := true;
    if sqlerrm != 'already_in_household' then
      raise exception 'TEST FAILED: expected already_in_household, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a user with a household created a second one';
  end if;
end $$;
rollback to savepoint sp2;

-- join_household: a user with a DIFFERENT household cannot join another
savepoint sp3;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_code text;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  v_code := create_invite_code(v_household_b);

  -- user A already owns household_a; try to also join household_b
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  begin
    perform join_household(v_code);
  exception when others then
    v_raised := true;
    if sqlerrm != 'already_in_household' then
      raise exception 'TEST FAILED: expected already_in_household, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a user in one household joined a second, different household';
  end if;
end $$;
rollback to savepoint sp3;

rollback;
