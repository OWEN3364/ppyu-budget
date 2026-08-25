-- Run with: supabase db execute --file supabase/tests/0001_household_schema_test.sql
begin;

-- simulate user A
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

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

rollback;
