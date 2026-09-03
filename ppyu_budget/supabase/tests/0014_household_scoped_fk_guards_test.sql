-- Run with: supabase db query --linked --file supabase/tests/0014_household_scoped_fk_guards_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- transactions: rejects a cross-household account_id
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_b uuid;
  v_category_a uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_b, '남의 카드') returning id into v_account_b;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount)
    values (v_household_a, v_account_b, v_category_a, v_member_a, 'expense', 1000);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: transaction insert with a cross-household account_id was allowed';
  end if;
end $$;
rollback to savepoint sp1;

-- transactions: rejects a cross-household category_id
savepoint sp2;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_category_b uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_category_b from categories where household_id = v_household_b and type = 'expense' limit 1;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount)
    values (v_household_a, v_account_a, v_category_b, v_member_a, 'expense', 1000);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: transaction insert with a cross-household category_id was allowed';
  end if;
end $$;
rollback to savepoint sp2;

-- transactions: rejects a cross-household member_id
savepoint sp3;
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
    insert into transactions (household_id, account_id, category_id, member_id, type, amount)
    values (v_household_a, v_account_a, v_category_a, v_member_b, 'expense', 1000);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: transaction insert with a cross-household member_id was allowed';
  end if;
end $$;
rollback to savepoint sp3;

-- transactions: a fully same-household insert AND a same-household update
-- still succeed (regression guard on the new AND-chain)
savepoint sp4;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_txn_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000)
  returning id into v_txn_id;

  update transactions set amount = 2000 where id = v_txn_id;

  if v_txn_id is null then
    raise exception 'TEST FAILED: a legitimate same-household transaction insert/update was rejected';
  end if;
end $$;
rollback to savepoint sp4;

-- recurring_transactions: rejects a cross-household account_id and
-- category_id (created_by/owner_member_id's cross-household rejection is
-- already covered by 0011/0012's own tests, now routed through the shared
-- helper with identical semantics)
savepoint sp5;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_b uuid;
  v_category_a uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_b, '남의 카드') returning id into v_account_b;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
    values (v_household_a, v_account_b, v_category_a, v_member_a, v_member_a, 'expense', 1000, 'MONTHLY', now());
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: recurring_transactions insert with a cross-household account_id was allowed';
  end if;
end $$;
rollback to savepoint sp5;

savepoint sp6;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_category_b uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_category_b from categories where household_id = v_household_b and type = 'expense' limit 1;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;

  begin
    insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
    values (v_household_a, v_account_a, v_category_b, v_member_a, v_member_a, 'expense', 1000, 'MONTHLY', now());
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: recurring_transactions insert with a cross-household category_id was allowed';
  end if;
end $$;
rollback to savepoint sp6;

-- recurring_transactions: a fully same-household insert AND update still
-- succeed (regression guard — created_by/owner_member_id now routed
-- through is_household_member_row instead of the old inline exists checks)
savepoint sp7;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, v_member_id, 'expense', 1000, 'MONTHLY', now())
  returning id into v_template_id;

  update recurring_transactions set amount = 2000 where id = v_template_id;

  if v_template_id is null then
    raise exception 'TEST FAILED: a legitimate same-household recurring_transactions insert/update was rejected';
  end if;
end $$;
rollback to savepoint sp7;

-- budgets: rejects a cross-household category_id, but a null category_id
-- (overall budget) and a same-household category_id both still succeed
savepoint sp8;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_category_a uuid;
  v_category_b uuid;
  v_raised boolean := false;
  v_overall_id uuid;
  v_categorized_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_category_b from categories where household_id = v_household_b and type = 'expense' limit 1;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into budgets (household_id, category_id, month, amount) values (v_household_a, v_category_b, '2026-09-01', 100000);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: budget insert with a cross-household category_id was allowed';
  end if;

  insert into budgets (household_id, category_id, month, amount) values (v_household_a, null, '2026-09-01', 500000) returning id into v_overall_id;
  insert into budgets (household_id, category_id, month, amount) values (v_household_a, v_category_a, '2026-09-01', 100000) returning id into v_categorized_id;
  if v_overall_id is null or v_categorized_id is null then
    raise exception 'TEST FAILED: a legitimate overall or same-household-categorized budget insert was rejected';
  end if;
end $$;
rollback to savepoint sp8;

-- accounts: rejects a cross-household owner_member_id, but a null
-- owner_member_id (today's only real app behavior) still succeeds
savepoint sp9;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_b uuid;
  v_raised boolean := false;
  v_account_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();

  begin
    insert into accounts (household_id, owner_member_id, name) values (v_household_a, v_member_b, '남의 소유 카드');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: account insert with a cross-household owner_member_id was allowed';
  end if;

  insert into accounts (household_id, name) values (v_household_a, '내 카드') returning id into v_account_id;
  if v_account_id is null then
    raise exception 'TEST FAILED: a legitimate account insert with owner_member_id left null was rejected';
  end if;
end $$;
rollback to savepoint sp9;

-- calendar_events: an update setting created_by to a cross-household member
-- is rejected
savepoint sp10;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_member_b uuid;
  v_event_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_a, '정상 일정', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  begin
    update calendar_events set created_by = v_member_b where id = v_event_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: calendar_events update setting created_by to a cross-household member was allowed';
  end if;
end $$;
rollback to savepoint sp10;

-- UPDATE-side negative cases: the with check clause text is identical
-- between each table's insert and update policy, but the update path
-- itself was untested until now (one representative column per table is
-- enough — the insert scenarios above already covered every column
-- individually).

-- accounts: update rejects a cross-household owner_member_id
savepoint sp11;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_b uuid;
  v_account_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_a, '내 카드') returning id into v_account_id;

  begin
    update accounts set owner_member_id = v_member_b where id = v_account_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: account update setting owner_member_id to a cross-household member was allowed';
  end if;
end $$;
rollback to savepoint sp11;

-- budgets: update rejects a cross-household category_id
savepoint sp12;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_category_b uuid;
  v_budget_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_category_b from categories where household_id = v_household_b and type = 'expense' limit 1;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  insert into budgets (household_id, category_id, month, amount) values (v_household_a, null, '2026-09-01', 500000) returning id into v_budget_id;

  begin
    update budgets set category_id = v_category_b where id = v_budget_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: budget update setting category_id to a cross-household category was allowed';
  end if;
end $$;
rollback to savepoint sp12;

-- transactions: update rejects a cross-household account_id
savepoint sp13;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_account_b uuid;
  v_category_a uuid;
  v_txn_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_b, '남의 카드') returning id into v_account_b;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '내 카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_a, v_account_a, v_category_a, v_member_a, 'expense', 1000)
  returning id into v_txn_id;

  begin
    update transactions set account_id = v_account_b where id = v_txn_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: transaction update setting account_id to a cross-household account was allowed';
  end if;
end $$;
rollback to savepoint sp13;

-- recurring_transactions: update rejects a cross-household account_id
savepoint sp14;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_account_b uuid;
  v_category_a uuid;
  v_template_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_b, '남의 카드') returning id into v_account_b;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '내 카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_a, v_account_a, v_category_a, v_member_a, v_member_a, 'expense', 1000, 'MONTHLY', now())
  returning id into v_template_id;

  begin
    update recurring_transactions set account_id = v_account_b where id = v_template_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: recurring_transactions update setting account_id to a cross-household account was allowed';
  end if;
end $$;
rollback to savepoint sp14;

rollback;
