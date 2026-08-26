create table tags (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (household_id, name)
);

create table transaction_tags (
  transaction_id uuid not null references transactions(id) on delete cascade,
  tag_id uuid not null references tags(id) on delete cascade,
  primary key (transaction_id, tag_id)
);

alter table household_members add column nickname text;

alter table tags enable row level security;
alter table transaction_tags enable row level security;

create policy "members can select tags" on tags for select using (is_household_member(household_id));
create policy "members can insert tags" on tags for insert with check (is_household_member(household_id));
create policy "members can update tags" on tags for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete tags" on tags for delete using (is_household_member(household_id));

create policy "members can select transaction_tags" on transaction_tags for select using (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
);
create policy "members can insert transaction_tags" on transaction_tags for insert with check (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
);
create policy "members can delete transaction_tags" on transaction_tags for delete using (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
);

-- household_members has no update RLS policy today (writes only ever happened
-- via SECURITY DEFINER functions). A raw "user_id = auth.uid()" update policy
-- would let a client also overwrite `role` on their own row (self-promote to
-- 'owner') since RLS can't restrict which columns a payload touches — so
-- nickname writes go through this function instead, which only ever touches
-- the nickname column.
create or replace function set_my_nickname(p_household_id uuid, p_nickname text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_household_member(p_household_id) then
    raise exception 'not_a_household_member';
  end if;
  update household_members
  set nickname = p_nickname
  where household_id = p_household_id and user_id = auth.uid();
end;
$$;
revoke execute on function set_my_nickname(uuid, text) from public, anon;
