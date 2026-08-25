-- Run with: supabase db query --linked --file supabase/tests/0003_ledger_schema_test.sql
begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999999', 'z@test.com')
  on conflict do nothing;

-- postgres (the role `supabase db query --linked` connects as) has bypassrls,
-- so RLS is never actually enforced unless we switch role. `set local` is
-- scoped to this transaction and resets at the final `rollback;`.
set local role authenticated;

-- default categories are seeded on household creation
savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_count int;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  select count(*) into v_count from categories where household_id = v_household_id;
  if v_count != 10 then
    raise exception 'TEST FAILED: expected 10 default categories, got %', v_count;
  end if;
end $$;
rollback to savepoint sp1;

-- a non-member cannot see or insert into another household's accounts (RLS)
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_account_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_id, '현금')
    returning id into v_account_id;

  perform set_config('request.jwt.claims', '{"sub":"99999999-9999-9999-9999-999999999999"}', true);
  if exists (select 1 from accounts where id = v_account_id) then
    raise exception 'TEST FAILED: a non-member could see another household''s account';
  end if;

  begin
    insert into accounts (household_id, name) values (v_household_id, 'hijacked');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a non-member inserted an account into another household';
  end if;
end $$;
rollback to savepoint sp2;

-- a member can create a transaction referencing their own household's account/category
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  select id into v_account_id from accounts where household_id = v_household_id limit 1;
  if v_account_id is null then
    insert into accounts (household_id, name) values (v_household_id, '현금') returning id into v_account_id;
  end if;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, memo)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 12000, '점심');

  if (select count(*) from transactions where household_id = v_household_id) != 1 then
    raise exception 'TEST FAILED: transaction was not inserted';
  end if;
end $$;
rollback to savepoint sp3;

-- only one "overall" (null category_id) budget per household per month
savepoint sp4;
do $$
declare
  v_household_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  insert into budgets (household_id, category_id, month, amount) values (v_household_id, null, '2026-09-01', 1000000);
  begin
    insert into budgets (household_id, category_id, month, amount) values (v_household_id, null, '2026-09-01', 2000000);
  exception when unique_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a second overall budget for the same household/month was allowed';
  end if;
end $$;
rollback to savepoint sp4;

rollback;
