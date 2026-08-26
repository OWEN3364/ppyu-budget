-- Run with: supabase db query --linked --file supabase/tests/0005_tags_nickname_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- tags are scoped to the creating household; another household can't see them
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_tag_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  insert into tags (household_id, name) values (v_household_a, '배달') returning id into v_tag_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select count(*) into v_count from tags where id = v_tag_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: household B could see household A''s tag';
  end if;
end $$;
rollback to savepoint sp1;

-- set_my_nickname only updates the caller's own row, never another member's
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_invite_code text;
  v_nickname text;
  v_other_nickname text;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  v_invite_code := create_invite_code(v_household_id);

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  perform join_household(v_invite_code);

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  perform set_my_nickname(v_household_id, '민수');

  select nickname into v_nickname from household_members
    where household_id = v_household_id and user_id = '11111111-1111-1111-1111-111111111111';
  if v_nickname != '민수' then
    raise exception 'TEST FAILED: expected own nickname to be set, got %', v_nickname;
  end if;

  select nickname into v_other_nickname from household_members
    where household_id = v_household_id and user_id = '22222222-2222-2222-2222-222222222222';
  if v_other_nickname is not null then
    raise exception 'TEST FAILED: set_my_nickname must not touch other members'' rows, but got %', v_other_nickname;
  end if;
end $$;
rollback to savepoint sp2;

-- set_my_nickname raises for a non-member household
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  begin
    perform set_my_nickname(v_household_id, '해킹시도');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: non-member should not be able to set a nickname';
  end if;
end $$;
rollback to savepoint sp3;

rollback;
