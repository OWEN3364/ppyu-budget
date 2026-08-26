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
    and date_trunc('month', t.occurred_at) = date_trunc('month', p_month::timestamptz)
  where c.household_id = p_household_id
    and is_household_member(p_household_id)
  group by c.id, c.name, c.type
  having coalesce(sum(t.amount), 0) > 0;
$$;
revoke execute on function get_monthly_category_summary(uuid, date) from public, anon;

create or replace function get_spending_recommendations(p_household_id uuid, p_month date)
returns table (category_id uuid, category_name text, current_amount bigint, previous_amount bigint, change_ratio double precision)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  with current_month as (
    select * from get_monthly_category_summary(p_household_id, p_month) where type = 'expense'
  ), previous_month as (
    select * from get_monthly_category_summary(p_household_id, (p_month - interval '1 month')::date) where type = 'expense'
  )
  select cm.category_id, cm.category_name, cm.total_amount, coalesce(pm.total_amount, 0),
    round((cm.total_amount - pm.total_amount)::numeric / pm.total_amount * 100, 1)::double precision
  from current_month cm
  join previous_month pm on pm.category_id = cm.category_id
  where pm.total_amount > 0
    and (cm.total_amount - pm.total_amount)::numeric / pm.total_amount > 0.2
  order by (cm.total_amount - pm.total_amount)::numeric / pm.total_amount desc
  limit 3;
$$;
revoke execute on function get_spending_recommendations(uuid, date) from public, anon;
