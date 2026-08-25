create or replace function get_my_household()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select household_id from household_members
  where user_id = auth.uid() and left_at is null
  limit 1;
$$;

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
  insert into household_members (household_id, user_id, role)
  values (new_household_id, auth.uid(), 'owner');
  return new_household_id;
end;
$$;

create or replace function join_household(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
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

  -- already-member (of THIS household) is checked first: a member of a full
  -- household redeeming a second valid code should hear 'already_member', not
  -- 'household_full'.
  if exists (
    select 1 from household_members
    where household_id = v_invite.household_id and user_id = auth.uid() and left_at is null
  ) then
    raise exception 'already_member';
  end if;

  -- one household per user: block joining a DIFFERENT household too.
  if get_my_household() is not null then
    raise exception 'already_in_household';
  end if;

  select count(*) into v_member_count
  from household_members
  where household_id = v_invite.household_id and left_at is null;

  if v_member_count >= 2 then
    raise exception 'household_full';
  end if;

  insert into household_members (household_id, user_id, role)
  values (v_invite.household_id, auth.uid(), 'member');

  update invite_codes set used_at = now(), used_by = auth.uid() where id = v_invite.id;

  return v_invite.household_id;
end;
$$;

revoke execute on function get_my_household() from public, anon;
