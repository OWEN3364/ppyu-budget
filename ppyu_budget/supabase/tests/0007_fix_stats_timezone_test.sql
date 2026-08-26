-- Run with: supabase db query --linked --file supabase/tests/0007_fix_stats_timezone_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- a transaction at 03:00 KST on Sep 1 (= Aug 31 18:00 UTC) belongs to the
-- September bucket, matching what the Dart side shows via .toLocal()
savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_sep_amount bigint;
  v_aug_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and name = '식비';

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 33000, '2026-09-01 03:00:00+09'::timestamptz);

  select total_amount into v_sep_amount from get_monthly_category_summary(v_household_id, '2026-09-01'::date)
    where category_id = v_category_id;
  if v_sep_amount is distinct from 33000 then
    raise exception 'TEST FAILED: KST-September transaction missing from the September bucket, got %', v_sep_amount;
  end if;

  select count(*) into v_aug_count from get_monthly_category_summary(v_household_id, '2026-08-01'::date)
    where category_id = v_category_id;
  if v_aug_count != 0 then
    raise exception 'TEST FAILED: KST-September transaction leaked into the UTC-August bucket';
  end if;
end $$;
rollback to savepoint sp1;

-- transaction_tags insert requires the tag to belong to the caller's household
-- too, not just the transaction
savepoint sp2;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_foreign_tag uuid;
  v_own_tag uuid;
  v_member_b uuid;
  v_account_b uuid;
  v_category_b uuid;
  v_txn_b uuid;
  v_raised boolean := false;
  v_own_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  insert into tags (household_id, name) values (v_household_a, '남의태그') returning id into v_foreign_tag;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_b, '카드B') returning id into v_account_b;
  select id into v_category_b from categories where household_id = v_household_b and name = '식비';
  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_b, v_account_b, v_category_b, v_member_b, 'expense', 1000) returning id into v_txn_b;

  -- own transaction + another household's tag must be rejected
  begin
    insert into transaction_tags (transaction_id, tag_id) values (v_txn_b, v_foreign_tag);
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: member attached another household''s tag to their own transaction';
  end if;

  -- and the ordinary same-household case still works
  insert into tags (household_id, name) values (v_household_b, '내태그') returning id into v_own_tag;
  insert into transaction_tags (transaction_id, tag_id) values (v_txn_b, v_own_tag);
  select count(*) into v_own_count from transaction_tags where transaction_id = v_txn_b and tag_id = v_own_tag;
  if v_own_count != 1 then
    raise exception 'TEST FAILED: same-household tag insert was rejected';
  end if;
end $$;
rollback to savepoint sp2;

rollback;
