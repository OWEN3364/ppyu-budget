create or replace function is_household_member(p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = auth.uid() and left_at is null
  );
$$;
revoke execute on function is_household_member(uuid) from public, anon;

-- fix pre-existing infinite recursion (0001): the old policy's `using` clause
-- subqueried household_members from within a policy on household_members
-- itself, which recurses under a real (non-bypassrls) role. is_household_member()
-- is security definer (owned by postgres, which bypasses RLS), so routing
-- through it breaks the recursion using the standard Postgres pattern.
-- Dropping the `security definer` qualifier from is_household_member() would
-- silently reintroduce that infinite recursion, since the function body's
-- select on household_members would then be RLS-checked by this very policy.
drop policy "members can view household members" on household_members;
create policy "members can view household members" on household_members
  for select using (is_household_member(household_id));

-- same DRY/recursion-avoidance fix for the other two 0001 policies that still
-- hand-rolled the EXISTS subquery: route them through is_household_member()
-- too, so they're a single function call instead of a nested RLS evaluation
-- on household_members. households' own id IS the household_id for that
-- table, so it's is_household_member(id), not is_household_member(household_id).
drop policy if exists "members can view own household" on households;
create policy "members can view own household" on households
  for select using (is_household_member(id));

drop policy if exists "members can view own household invite codes" on invite_codes;
create policy "members can view own household invite codes" on invite_codes
  for select using (is_household_member(household_id));

create table accounts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  owner_member_id uuid references household_members(id) on delete set null,
  name text not null,
  type text not null default 'card' check (type in ('card', 'bank', 'cash')),
  created_at timestamptz not null default now()
);

create table categories (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name text not null,
  icon text,
  type text not null default 'expense' check (type in ('income', 'expense')),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete restrict,
  category_id uuid not null references categories(id) on delete restrict,
  member_id uuid not null references household_members(id) on delete restrict,
  type text not null check (type in ('income', 'expense')),
  amount integer not null check (amount > 0),
  memo text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table budgets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  category_id uuid references categories(id) on delete cascade,
  month date not null check (month = date_trunc('month', month)::date),
  amount integer not null check (amount >= 0),
  unique (household_id, category_id, month)
);
-- the composite unique constraint above doesn't stop two "overall" (null
-- category_id) budgets in the same month, since SQL unique constraints treat
-- NULL as distinct from every other NULL — this partial index closes that gap.
create unique index budgets_household_month_overall_unique
  on budgets (household_id, month) where category_id is null;

create table savings_goals (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name text not null,
  target_amount integer not null check (target_amount > 0),
  current_amount integer not null default 0 check (current_amount >= 0),
  target_date date,
  created_at timestamptz not null default now()
);

alter table accounts enable row level security;
alter table categories enable row level security;
alter table transactions enable row level security;
alter table budgets enable row level security;
alter table savings_goals enable row level security;

create policy "members can select accounts" on accounts for select using (is_household_member(household_id));
create policy "members can insert accounts" on accounts for insert with check (is_household_member(household_id));
create policy "members can update accounts" on accounts for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete accounts" on accounts for delete using (is_household_member(household_id));

create policy "members can select categories" on categories for select using (is_household_member(household_id));
create policy "members can insert categories" on categories for insert with check (is_household_member(household_id));
create policy "members can update categories" on categories for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete categories" on categories for delete using (is_household_member(household_id));

create policy "members can select transactions" on transactions for select using (is_household_member(household_id));
create policy "members can insert transactions" on transactions for insert with check (is_household_member(household_id));
create policy "members can update transactions" on transactions for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete transactions" on transactions for delete using (is_household_member(household_id));

create policy "members can select budgets" on budgets for select using (is_household_member(household_id));
create policy "members can insert budgets" on budgets for insert with check (is_household_member(household_id));
create policy "members can update budgets" on budgets for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete budgets" on budgets for delete using (is_household_member(household_id));

create policy "members can select savings goals" on savings_goals for select using (is_household_member(household_id));
create policy "members can insert savings goals" on savings_goals for insert with check (is_household_member(household_id));
create policy "members can update savings goals" on savings_goals for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete savings goals" on savings_goals for delete using (is_household_member(household_id));

-- widen create_household_and_owner (from 0002) to seed default categories
create or replace function create_household_and_owner()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_household_id uuid;
begin
  if get_my_household() is not null then
    raise exception 'already_in_household';
  end if;

  insert into households default values returning id into new_household_id;
  begin
    insert into household_members (household_id, user_id, role)
    values (new_household_id, auth.uid(), 'owner');
  exception when unique_violation then
    raise exception 'already_in_household';
  end;

  insert into categories (household_id, name, type, is_default) values
    (new_household_id, '식비', 'expense', true),
    (new_household_id, '교통비', 'expense', true),
    (new_household_id, '주거/공과금', 'expense', true),
    (new_household_id, '생활/쇼핑', 'expense', true),
    (new_household_id, '문화/여가', 'expense', true),
    (new_household_id, '의료/건강', 'expense', true),
    (new_household_id, '기타', 'expense', true),
    (new_household_id, '급여', 'income', true),
    (new_household_id, '용돈', 'income', true),
    (new_household_id, '기타수입', 'income', true);

  return new_household_id;
end;
$$;
