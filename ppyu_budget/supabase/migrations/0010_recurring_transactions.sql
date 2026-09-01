create table recurring_transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete restrict,
  category_id uuid not null references categories(id) on delete restrict,
  created_by uuid not null references household_members(id) on delete restrict,
  type text not null check (type in ('income', 'expense')),
  amount integer not null check (amount > 0),
  memo text,
  interval_rule text not null,
  next_run_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table recurring_transactions enable row level security;

create policy "members can select recurring_transactions" on recurring_transactions for select using (is_household_member(household_id));
create policy "members can insert recurring_transactions" on recurring_transactions for insert with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = recurring_transactions.household_id)
);
create policy "members can update recurring_transactions" on recurring_transactions for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete recurring_transactions" on recurring_transactions for delete using (is_household_member(household_id));

-- widen transactions.source so recurring-transaction catch-up can tag what
-- it creates (transactions_source_check is the actual auto-generated
-- constraint name, confirmed via pg_constraint).
alter table transactions drop constraint transactions_source_check;
alter table transactions add constraint transactions_source_check
  check (source in ('manual', 'notification_auto', 'recurring_auto'));
