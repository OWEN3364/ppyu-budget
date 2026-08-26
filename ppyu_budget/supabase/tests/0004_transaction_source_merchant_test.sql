-- Run with: supabase db query --linked --file supabase/tests/0004_transaction_source_merchant_test.sql
begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

set local role authenticated;

savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_source text;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  -- default source is 'manual' when omitted
  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 5000);

  select source into v_source from transactions where household_id = v_household_id;
  if v_source != 'manual' then
    raise exception 'TEST FAILED: expected default source manual, got %', v_source;
  end if;
end $$;
rollback to savepoint sp1;

-- an invalid source value is rejected
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
    values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 5000, 'bogus');
  exception when check_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: an invalid source value was accepted';
  end if;
end $$;
rollback to savepoint sp2;

rollback;
