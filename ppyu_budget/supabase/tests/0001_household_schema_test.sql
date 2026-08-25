-- Run with: supabase db query --linked --file supabase/tests/0001_household_schema_test.sql
begin;

-- simulate user A
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;
insert into auth.users (id, email) values ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;
insert into auth.users (id, email) values ('33333333-3333-3333-3333-333333333333', 'c@test.com')
  on conflict do nothing;

savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_code text;
begin
  v_household_id := create_household_and_owner();
  if v_household_id is null then
    raise exception 'TEST FAILED: household not created';
  end if;

  v_code := create_invite_code(v_household_id);
  if length(v_code) != 6 then
    raise exception 'TEST FAILED: invite code is not 6 digits';
  end if;
end $$;
rollback to savepoint sp1;

-- 2-member cap: A creates household, B joins, C is rejected with household_full
-- (each block below rolls back to a savepoint afterward so the same three
-- simulated users can freely create/join households again in later blocks,
-- as required once a user is limited to one household at a time)
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_code_b text;
  v_code_c text;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  v_code_b := create_invite_code(v_household_id);

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  if join_household(v_code_b) != v_household_id then
    raise exception 'TEST FAILED: second member did not join the expected household';
  end if;

  -- A issues a second, still-valid code; the household is now at the 2-member cap
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_code_c := create_invite_code(v_household_id);

  perform set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333"}', true);
  begin
    perform join_household(v_code_c);
  exception when others then
    v_raised := true;
    if sqlerrm != 'household_full' then
      raise exception 'TEST FAILED: expected household_full, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: third member joined a household already at the 2-member cap';
  end if;
end $$;
rollback to savepoint sp2;

-- already_member wins over household_full: an existing member of a full household
-- redeeming a second valid code hears already_member
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_code_b text;
  v_code_2 text;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  v_code_b := create_invite_code(v_household_id);

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  perform join_household(v_code_b);

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_code_2 := create_invite_code(v_household_id);
  begin
    perform join_household(v_code_2);
  exception when others then
    v_raised := true;
    if sqlerrm != 'already_member' then
      raise exception 'TEST FAILED: expected already_member, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: an existing member joined their own household again';
  end if;
end $$;
rollback to savepoint sp3;

-- expiry: a code past expires_at is rejected with invalid_or_expired_code
savepoint sp4;
do $$
declare
  v_household_id uuid;
  v_code text;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  v_code := create_invite_code(v_household_id);

  -- force-expire rather than waiting out the real 10-minute window
  update invite_codes set expires_at = now() - interval '1 minute' where code = v_code;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  begin
    perform join_household(v_code);
  exception when others then
    v_raised := true;
    if sqlerrm != 'invalid_or_expired_code' then
      raise exception 'TEST FAILED: expected invalid_or_expired_code for an expired code, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: an expired invite code was accepted';
  end if;
end $$;
rollback to savepoint sp4;

-- single-use: a code that already set used_at is rejected with invalid_or_expired_code
savepoint sp5;
do $$
declare
  v_household_id uuid;
  v_code text;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  v_code := create_invite_code(v_household_id);

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  perform join_household(v_code);

  -- a different user reusing the same, now-consumed code
  perform set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333"}', true);
  begin
    perform join_household(v_code);
  exception when others then
    v_raised := true;
    if sqlerrm != 'invalid_or_expired_code' then
      raise exception 'TEST FAILED: expected invalid_or_expired_code for a used code, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a single-use invite code was accepted twice';
  end if;
end $$;
rollback to savepoint sp5;

rollback;
