-- Run with: supabase db query --linked --file supabase/tests/0006_stats_functions_test.sql
begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

set local role authenticated;

-- category with >20% MoM increase is recommended; category with no prior-month
-- spending is excluded even though its "increase" is technically infinite
savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_food_category uuid;
  v_new_category uuid;
  v_rec_count integer;
  v_food_ratio double precision;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_food_category from categories where household_id = v_household_id and name = '식비';
  insert into categories (household_id, name, type) values (v_household_id, '신규카테고리', 'expense') returning id into v_new_category;

  -- last month: 식비 100,000
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_food_category, v_member_id, 'expense', 100000, date_trunc('month', now()) - interval '15 days');

  -- this month: 식비 150,000 (+50%), 신규카테고리 50,000 (no prior month)
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_food_category, v_member_id, 'expense', 150000, now());
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_new_category, v_member_id, 'expense', 50000, now());

  select count(*) into v_rec_count from get_spending_recommendations(v_household_id, now()::date)
    where category_id = v_new_category;
  if v_rec_count != 0 then
    raise exception 'TEST FAILED: category with no prior-month spending must not be recommended';
  end if;

  select change_ratio into v_food_ratio from get_spending_recommendations(v_household_id, now()::date)
    where category_id = v_food_category;
  if v_food_ratio is null or v_food_ratio != 50.0 then
    raise exception 'TEST FAILED: expected 식비 change_ratio 50.0, got %', v_food_ratio;
  end if;
end $$;
rollback to savepoint sp1;

-- another household's data never leaks into these functions
savepoint sp2;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_leak_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '카드A') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and name = '식비';
  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_a, v_account_a, v_category_a, v_member_a, 'expense', 999999);

  v_household_b := gen_random_uuid(); -- a household this session is not a member of
  select count(*) into v_leak_count from get_monthly_category_summary(v_household_b, now()::date);
  if v_leak_count != 0 then
    raise exception 'TEST FAILED: get_monthly_category_summary leaked data for a non-member household';
  end if;
end $$;
rollback to savepoint sp2;

rollback;
