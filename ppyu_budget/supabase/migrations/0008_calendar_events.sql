create table calendar_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  recurrence_rule text,
  created_by uuid not null references household_members(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table calendar_events enable row level security;

create policy "members can select calendar_events" on calendar_events for select using (is_household_member(household_id));
create policy "members can insert calendar_events" on calendar_events for insert with check (is_household_member(household_id));
create policy "members can update calendar_events" on calendar_events for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete calendar_events" on calendar_events for delete using (is_household_member(household_id));
