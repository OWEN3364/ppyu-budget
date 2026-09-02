-- owner_member_id: who the spending is attributed to (separate from
-- created_by, who authored the template row). Backfilled from created_by
-- since every existing template's owner is presumed to be its creator.
alter table recurring_transactions
  add column owner_member_id uuid references household_members(id) on delete restrict,
  add column auto_register boolean not null default false;

update recurring_transactions set owner_member_id = created_by where owner_member_id is null;

alter table recurring_transactions alter column owner_member_id set not null;

-- start_at is no longer a pointer the catch-up service advances — it's a
-- fixed calculation anchor. "Done" is now derived from whether a matching
-- transaction exists (see the unique index below), not from this column.
alter table recurring_transactions rename column next_run_at to start_at;

drop policy "members can insert recurring_transactions" on recurring_transactions;
create policy "members can insert recurring_transactions" on recurring_transactions for insert with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = recurring_transactions.household_id)
  and exists (select 1 from household_members m where m.id = owner_member_id and m.household_id = recurring_transactions.household_id)
);

-- recurring_transaction_id + occurred_at identifies one occurrence.
-- confirmed defaults true so every existing row (manual, recurring_auto,
-- and today's notification_auto rows) is unaffected.
alter table transactions
  add column recurring_transaction_id uuid references recurring_transactions(id) on delete set null,
  add column confirmed boolean not null default true;

-- The core of the redesign: this index makes a duplicate occurrence
-- insert fail at the database, structurally, regardless of how many
-- sessions race to create it — no CAS/advance-tracking needed anywhere in
-- application code. Partial (where clause) so ordinary manual transactions
-- (recurring_transaction_id is null) are never constrained by it.
create unique index transactions_recurring_occurrence_unique
  on transactions (recurring_transaction_id, occurred_at)
  where recurring_transaction_id is not null;
