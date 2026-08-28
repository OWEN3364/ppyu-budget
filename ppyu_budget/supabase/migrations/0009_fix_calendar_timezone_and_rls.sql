-- The original insert policy checked that household_id belongs to the
-- caller's household but not created_by, so a member could attach a
-- household_members.id from a DIFFERENT household to their own event
-- (foreign keys bypass RLS). Same gap class 0007 closed for
-- transaction_tags's insert policy.
drop policy "members can insert calendar_events" on calendar_events;
create policy "members can insert calendar_events" on calendar_events for insert with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = calendar_events.household_id)
);
