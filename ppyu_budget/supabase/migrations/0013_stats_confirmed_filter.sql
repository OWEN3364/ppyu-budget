-- get_monthly_category_summary summed every transaction regardless of the
-- `confirmed` flag (added in 0011 for notification-capture's "확인 후 저장"
-- mode). A pending (confirmed=false) transaction is invisible in the main
-- transaction list but was still moving the stats pie chart, the spending
-- recommendations, and the CSV export — silently skewing numbers for
-- something the user hasn't reviewed yet. Filter it out here, the one place
-- both stats functions and the CSV export ultimately depend on.
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
    and t.confirmed
    and date_trunc('month', t.occurred_at at time zone 'Asia/Seoul') = date_trunc('month', p_month::timestamp)
  where c.household_id = p_household_id
    and is_household_member(p_household_id)
  group by c.id, c.name, c.type
  having coalesce(sum(t.amount), 0) > 0;
$$;
revoke execute on function get_monthly_category_summary(uuid, date) from public, anon;

-- get_spending_recommendations only calls get_monthly_category_summary, so it
-- inherits the fix and needs no change (same note as 0007).
