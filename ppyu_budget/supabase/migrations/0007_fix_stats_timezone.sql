-- date_trunc on a timestamptz evaluates in the session TimeZone GUC (UTC on
-- Supabase), but every Dart-side month decision uses .toLocal(). For a KST
-- user a 00:00-09:00 KST transaction on the 1st landed in the previous UTC
-- month, so the pie chart and the CSV export disagreed about which month a
-- transaction belongs to. Bucket by Seoul wall time to match the client.
create or replace function get_monthly_category_summary(p_household_id uuid, p_month date)
returns table (category_id uuid, category_name text, type text, total_amount bigint)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select c.id, c.name, c.type, coalesce(sum(t.amount), 0)
  from categories c
  left join transactions t
    on t.category_id = c.id
    and t.household_id = p_household_id
    and date_trunc('month', t.occurred_at at time zone 'Asia/Seoul') = date_trunc('month', p_month::timestamp)
  where c.household_id = p_household_id
    and is_household_member(p_household_id)
  group by c.id, c.name, c.type
  having coalesce(sum(t.amount), 0) > 0;
$$;
revoke execute on function get_monthly_category_summary(uuid, date) from public, anon;

-- get_spending_recommendations only calls get_monthly_category_summary, so it
-- inherits the fix and needs no change.

-- The original insert policy checked that the transaction belongs to the
-- caller's household but not the tag, so a member could attach another
-- household's tag id to their own transaction. Defense-in-depth: check both.
drop policy "members can insert transaction_tags" on transaction_tags;
create policy "members can insert transaction_tags" on transaction_tags for insert with check (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
  and exists (select 1 from tags g where g.id = tag_id and is_household_member(g.household_id))
);
