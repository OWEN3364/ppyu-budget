-- This repo has fixed the same bug class piecemeal five times now: a column
-- that's a foreign key into a household-scoped table (household_members,
-- accounts, categories, recurring_transactions) wasn't validated to belong
-- to the SAME household as the row being written, only that the writer is
-- *a* household member somewhere. A member of household A could then write
-- a row in A that points at household B's account/category/member/template
-- — invisible to B via SELECT RLS, but the reference itself would succeed.
--
-- Three small, reusable, null-safe predicates close every remaining known
-- instance in one pass, and give future policies a name to reach for
-- instead of hand-rolling `exists (select 1 from X where X.id = ... and
-- X.household_id = ...)` again. Null-safe (a null id always passes) so a
-- nullable column (accounts.owner_member_id, budgets.category_id) needs no
-- separate null-guard at the call site.

create or replace function is_household_account(p_account_id uuid, p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select p_account_id is null or exists (
    select 1 from accounts a where a.id = p_account_id and a.household_id = p_household_id
  );
$$;
revoke execute on function is_household_account(uuid, uuid) from public, anon;

create or replace function is_household_category(p_category_id uuid, p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select p_category_id is null or exists (
    select 1 from categories c where c.id = p_category_id and c.household_id = p_household_id
  );
$$;
revoke execute on function is_household_category(uuid, uuid) from public, anon;

-- Supersedes every hand-written `exists (select 1 from household_members m
-- where m.id = ... and m.household_id = ...)` this repo has written so far
-- (recurring_transactions' created_by/owner_member_id checks) — those are
-- rewritten below to call this instead, same semantics.
create or replace function is_household_member_row(p_member_id uuid, p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select p_member_id is null or exists (
    select 1 from household_members m where m.id = p_member_id and m.household_id = p_household_id
  );
$$;
revoke execute on function is_household_member_row(uuid, uuid) from public, anon;

-- transactions: account_id, category_id, member_id were never validated
-- (only recurring_transaction_id, fixed in 0012).
drop policy "members can insert transactions" on transactions;
create policy "members can insert transactions" on transactions for insert with check (
  is_household_member(household_id)
  and is_household_account(account_id, household_id)
  and is_household_category(category_id, household_id)
  and is_household_member_row(member_id, household_id)
  and (
    recurring_transaction_id is null
    or exists (select 1 from recurring_transactions rt where rt.id = recurring_transaction_id and rt.household_id = transactions.household_id)
  )
);

drop policy "members can update transactions" on transactions;
create policy "members can update transactions" on transactions for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and is_household_account(account_id, household_id)
  and is_household_category(category_id, household_id)
  and is_household_member_row(member_id, household_id)
  and (
    recurring_transaction_id is null
    or exists (select 1 from recurring_transactions rt where rt.id = recurring_transaction_id and rt.household_id = transactions.household_id)
  )
);

-- recurring_transactions: account_id/category_id were never validated;
-- created_by/owner_member_id are rewritten onto the shared helper (same
-- semantics as 0011/0012's hand-written exists checks).
drop policy "members can insert recurring_transactions" on recurring_transactions;
create policy "members can insert recurring_transactions" on recurring_transactions for insert with check (
  is_household_member(household_id)
  and is_household_account(account_id, household_id)
  and is_household_category(category_id, household_id)
  and is_household_member_row(created_by, household_id)
  and is_household_member_row(owner_member_id, household_id)
);

drop policy "members can update recurring_transactions" on recurring_transactions;
create policy "members can update recurring_transactions" on recurring_transactions for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and is_household_account(account_id, household_id)
  and is_household_category(category_id, household_id)
  and is_household_member_row(created_by, household_id)
  and is_household_member_row(owner_member_id, household_id)
);

-- budgets.category_id (nullable — a null category_id means "overall budget")
-- was never validated.
drop policy "members can insert budgets" on budgets;
create policy "members can insert budgets" on budgets for insert with check (
  is_household_member(household_id)
  and is_household_category(category_id, household_id)
);

drop policy "members can update budgets" on budgets;
create policy "members can update budgets" on budgets for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and is_household_category(category_id, household_id)
);

-- accounts.owner_member_id (nullable, not yet settable from the app — this
-- closes the RLS hole defensively, the same way calendar_events' created_by
-- was closed on insert in 0009 before the app ever exercised it).
drop policy "members can insert accounts" on accounts;
create policy "members can insert accounts" on accounts for insert with check (
  is_household_member(household_id)
  and is_household_member_row(owner_member_id, household_id)
);

drop policy "members can update accounts" on accounts;
create policy "members can update accounts" on accounts for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and is_household_member_row(owner_member_id, household_id)
);

-- calendar_events: created_by was validated on insert (0009) but not update
-- (the app never sends created_by on update either — defensive only, same
-- rationale as accounts above).
drop policy "members can update calendar_events" on calendar_events;
create policy "members can update calendar_events" on calendar_events for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and is_household_member_row(created_by, household_id)
);
