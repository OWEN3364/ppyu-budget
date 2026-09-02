-- Run with: supabase db query --linked --file supabase/tests/0010_recurring_transactions_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- a non-member household can't see a recurring_transactions row
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_template_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_a, v_account_a, v_category_a, v_member_a, v_member_a, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select count(*) into v_count from recurring_transactions where id = v_template_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: household B could see household A''s recurring transaction';
  end if;
end $$;
rollback to savepoint sp1;

-- insert policy rejects a created_by that belongs to a DIFFERENT household
-- than the one being inserted into
savepoint sp2;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_b uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
    values (v_household_a, v_account_a, v_category_a, v_member_b, v_member_b, 'expense', 50000, 'MONTHLY', now());
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: insert should have been rejected for a created_by from a different household';
  end if;
end $$;
rollback to savepoint sp2;

-- transactions.source now accepts 'recurring_auto' and still rejects garbage
savepoint sp3;
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

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 10000, 'recurring_auto');

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
    values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 10000, 'garbage_value');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: an invalid source value should still be rejected';
  end if;
end $$;
rollback to savepoint sp3;

rollback;
