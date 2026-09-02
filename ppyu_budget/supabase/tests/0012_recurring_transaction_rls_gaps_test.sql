-- supabase/tests/0012_recurring_transaction_rls_gaps_test.sql
-- Run with: supabase db query --linked --file supabase/tests/0012_recurring_transaction_rls_gaps_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- transactions insert policy rejects a recurring_transaction_id belonging to
-- a DIFFERENT household
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_member_b uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_account_b uuid;
  v_category_b uuid;
  v_template_b uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_b, 'B카드') returning id into v_account_b;
  select id into v_category_b from categories where household_id = v_household_b and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_b, v_account_b, v_category_b, v_member_b, v_member_b, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_b;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, 'A카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
    values (v_household_a, v_account_a, v_category_a, v_member_a, 'expense', 50000, 'recurring_auto', '2026-09-01'::timestamptz, v_template_b);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: insert should have been rejected for a recurring_transaction_id from a different household';
  end if;
end $$;
rollback to savepoint sp1;

-- transactions insert policy still allows a same-household
-- recurring_transaction_id, and a null one (an ordinary manual transaction)
-- is unaffected
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
  v_txn_linked uuid;
  v_txn_manual uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, v_member_id, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-09-01'::timestamptz, v_template_id)
  returning id into v_txn_linked;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual', '2026-09-01'::timestamptz)
  returning id into v_txn_manual;

  if v_txn_linked is null or v_txn_manual is null then
    raise exception 'TEST FAILED: a legitimate same-household or manual transaction insert was rejected';
  end if;
end $$;
rollback to savepoint sp2;

-- transactions update policy rejects re-pointing recurring_transaction_id at
-- a DIFFERENT household's template
savepoint sp3;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_member_b uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_account_b uuid;
  v_category_b uuid;
  v_template_b uuid;
  v_txn_a uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_b, 'B카드') returning id into v_account_b;
  select id into v_category_b from categories where household_id = v_household_b and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_b, v_account_b, v_category_b, v_member_b, v_member_b, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_b;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, 'A카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at)
  values (v_household_a, v_account_a, v_category_a, v_member_a, 'expense', 1000, 'manual', '2026-09-01'::timestamptz)
  returning id into v_txn_a;

  begin
    update transactions set recurring_transaction_id = v_template_b where id = v_txn_a;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: update should have been rejected for a recurring_transaction_id from a different household';
  end if;
end $$;
rollback to savepoint sp3;

-- recurring_transactions update policy rejects a created_by that belongs to
-- a DIFFERENT household (the check 0011's update-policy fix round dropped)
savepoint sp4;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_member_b uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_template_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, 'A카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_a, v_account_a, v_category_a, v_member_a, v_member_a, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  begin
    update recurring_transactions set created_by = v_member_b where id = v_template_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: update should have been rejected for a created_by from a different household';
  end if;
end $$;
rollback to savepoint sp4;

-- a legitimate same-household update (amount only) still succeeds — the
-- added created_by check must not block ordinary edits
savepoint sp5;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
  v_amount int;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, v_member_id, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  update recurring_transactions set amount = 60000 where id = v_template_id
  returning amount into v_amount;

  if v_amount is distinct from 60000 then
    raise exception 'TEST FAILED: a legitimate same-household update was rejected';
  end if;
end $$;
rollback to savepoint sp5;

rollback;
