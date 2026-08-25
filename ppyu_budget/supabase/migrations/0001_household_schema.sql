create table households (
  id uuid primary key default gen_random_uuid(),
  name text not null default '우리집',
  created_at timestamptz not null default now()
);

create table household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  unique (household_id, user_id)
);

create table invite_codes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  code text not null unique,
  created_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users(id)
);

alter table households enable row level security;
alter table household_members enable row level security;
alter table invite_codes enable row level security;

create policy "members can view own household"
  on households for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = households.id
        and hm.user_id = auth.uid()
        and hm.left_at is null
    )
  );

create policy "members can view household members"
  on household_members for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = household_members.household_id
        and hm.user_id = auth.uid()
        and hm.left_at is null
    )
  );

create policy "members can view own household invite codes"
  on invite_codes for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = invite_codes.household_id
        and hm.user_id = auth.uid()
        and hm.left_at is null
    )
  );

create or replace function create_household_and_owner()
returns uuid
language plpgsql
security definer
as $$
declare
  new_household_id uuid;
begin
  insert into households default values returning id into new_household_id;
  insert into household_members (household_id, user_id, role)
  values (new_household_id, auth.uid(), 'owner');
  return new_household_id;
end;
$$;

create or replace function create_invite_code(p_household_id uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_code text;
  v_is_member boolean;
begin
  select exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = auth.uid() and left_at is null
  ) into v_is_member;

  if not v_is_member then
    raise exception 'not a member of this household';
  end if;

  v_code := lpad(floor(random() * 1000000)::text, 6, '0');

  insert into invite_codes (household_id, code, created_by, expires_at)
  values (p_household_id, v_code, auth.uid(), now() + interval '10 minutes');

  return v_code;
end;
$$;

create or replace function join_household(p_code text)
returns uuid
language plpgsql
security definer
as $$
declare
  v_invite invite_codes%rowtype;
  v_member_count int;
begin
  select * into v_invite from invite_codes
  where code = p_code and used_at is null and expires_at > now()
  for update;

  if not found then
    raise exception 'invalid_or_expired_code';
  end if;

  perform 1 from households where id = v_invite.household_id for update;

  select count(*) into v_member_count
  from household_members
  where household_id = v_invite.household_id and left_at is null;

  if v_member_count >= 2 then
    raise exception 'household_full';
  end if;

  if exists (
    select 1 from household_members
    where household_id = v_invite.household_id and user_id = auth.uid() and left_at is null
  ) then
    raise exception 'already_member';
  end if;

  insert into household_members (household_id, user_id, role)
  values (v_invite.household_id, auth.uid(), 'member');

  update invite_codes set used_at = now(), used_by = auth.uid() where id = v_invite.id;

  return v_invite.household_id;
end;
$$;
