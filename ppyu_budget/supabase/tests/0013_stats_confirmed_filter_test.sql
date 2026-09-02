-- Run with: supabase db query --linked --file supabase/tests/0013_stats_confirmed_filter_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

set local role authenticated;

-- an unconfirmed (pending notification-review) transaction is excluded from
-- the monthly summary; a confirmed one in the same category still counts
savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_total bigint;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and name = '식비';

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at, confirmed)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 5000, '2026-09-05 12:00:00+09'::timestamptz, true);

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at, source, confirmed)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 99000, '2026-09-05 13:00:00+09'::timestamptz, 'notification_auto', false);

  select total_amount into v_total from get_monthly_category_summary(v_household_id, '2026-09-01'::date)
    where category_id = v_category_id;

  if v_total is distinct from 5000 then
    raise exception 'TEST FAILED: expected only the confirmed 5000 to count, got %', v_total;
  end if;
end $$;
rollback to savepoint sp1;

-- a category whose only transaction is unconfirmed doesn't appear at all
-- (the function's `having sum(...) > 0` clause drops it, same as a
-- category with zero transactions)
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and name = '식비';

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at, source, confirmed)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 12000, '2026-09-05 12:00:00+09'::timestamptz, 'notification_auto', false);

  select count(*) into v_count from get_monthly_category_summary(v_household_id, '2026-09-01'::date)
    where category_id = v_category_id;

  if v_count != 0 then
    raise exception 'TEST FAILED: a category with only an unconfirmed transaction should not appear, got % rows', v_count;
  end if;
end $$;
rollback to savepoint sp2;

rollback;
