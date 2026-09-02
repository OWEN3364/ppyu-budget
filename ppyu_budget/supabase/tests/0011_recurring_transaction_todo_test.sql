-- supabase/tests/0011_recurring_transaction_todo_test.sql
-- Run with: supabase db query --linked --file supabase/tests/0011_recurring_transaction_todo_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- insert policy rejects an owner_member_id from a DIFFERENT household
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
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
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
    values (v_household_a, v_account_a, v_category_a, v_member_a, v_member_b, 'expense', 50000, 'MONTHLY', now());
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: insert should have been rejected for an owner_member_id from a different household';
  end if;
end $$;
rollback to savepoint sp1;

-- insert policy still allows a legitimate same-household owner_member_id,
-- and start_at (the renamed column) round-trips correctly
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_a uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
  v_start_at timestamptz;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at, auto_register)
  values (v_household_id, v_account_id, v_category_id, v_member_a, v_member_a, 'expense', 50000, 'MONTHLY', '2026-09-01'::timestamptz, true)
  returning id, start_at into v_template_id, v_start_at;

  if v_template_id is null or v_start_at != '2026-09-01'::timestamptz then
    raise exception 'TEST FAILED: a legitimate insert with a same-household owner_member_id was rejected or start_at did not round-trip';
  end if;
end $$;
rollback to savepoint sp2;

-- the unique index blocks a second transaction for the same
-- (recurring_transaction_id, occurred_at) pair, but allows a different
-- occurred_at for the same template, and never constrains manual
-- transactions (recurring_transaction_id is null)
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
  v_raised boolean := false;
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
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-09-01'::timestamptz, v_template_id);

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
    values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-09-01'::timestamptz, v_template_id);
  exception when unique_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a duplicate (recurring_transaction_id, occurred_at) pair was allowed';
  end if;

  -- a different occurred_at for the same template is fine
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-10-01'::timestamptz, v_template_id);

  -- two manual transactions (recurring_transaction_id null) on the same
  -- occurred_at are never constrained by the partial index
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual', '2026-09-01'::timestamptz);
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual', '2026-09-01'::timestamptz);
end $$;
rollback to savepoint sp3;

-- confirmed defaults to true for an ordinary insert that doesn't specify it
savepoint sp4;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_confirmed boolean;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual')
  returning confirmed into v_confirmed;

  if v_confirmed is not true then
    raise exception 'TEST FAILED: confirmed did not default to true';
  end if;
end $$;
rollback to savepoint sp4;

-- update policy rejects an owner_member_id that belongs to a DIFFERENT household
savepoint sp5;
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
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_a, v_account_a, v_category_a, v_member_a, v_member_a, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  begin
    update recurring_transactions set owner_member_id = v_member_b where id = v_template_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: update should have been rejected for an owner_member_id from a different household';
  end if;
end $$;
rollback to savepoint sp5;

rollback;
