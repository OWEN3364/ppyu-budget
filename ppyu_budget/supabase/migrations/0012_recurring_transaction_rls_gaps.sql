-- Closes two RLS gaps found in the final whole-branch review of the
-- confirm/auto redesign — both are the same bug class this repo has
-- already fixed twice elsewhere (calendar_events 0008->0009; this
-- branch's own recurring_transactions update policy, fixed once already
-- in migration 0011's own fix round for owner_member_id, but that fix
-- dropped the created_by check the insert policy still has).

drop policy "members can insert transactions" on transactions;
create policy "members can insert transactions" on transactions for insert with check (
  is_household_member(household_id)
  and (
    recurring_transaction_id is null
    or exists (
      select 1 from recurring_transactions rt
      where rt.id = recurring_transaction_id and rt.household_id = transactions.household_id
    )
  )
);

drop policy "members can update transactions" on transactions;
create policy "members can update transactions" on transactions for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and (
    recurring_transaction_id is null
    or exists (
      select 1 from recurring_transactions rt
      where rt.id = recurring_transaction_id and rt.household_id = transactions.household_id
    )
  )
);

drop policy "members can update recurring_transactions" on recurring_transactions;
create policy "members can update recurring_transactions" on recurring_transactions for update using (is_household_member(household_id)) with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = recurring_transactions.household_id)
  and exists (select 1 from household_members m where m.id = owner_member_id and m.household_id = recurring_transactions.household_id)
);
