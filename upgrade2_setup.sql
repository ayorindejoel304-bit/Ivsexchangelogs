-- IVs EXCHANGE Logs v12. Run once in Supabase SQL Editor (after upgrade_setup.sql).

-- Admin: members list WITH the referrer's name
create or replace function public.admin_members()
returns table (id uuid, email text, full_name text, referred_by_code text, referrer_name text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    select p.id, p.email, p.full_name, p.referred_by_code,
      (select u.raw_user_meta_data ->> 'full_name' from auth.users u
        where upper(u.raw_user_meta_data ->> 'referral_code') = upper(p.referred_by_code) limit 1),
      p.created_at
    from public.profiles p order by p.created_at desc limit 500;
end; $$;
revoke all on function public.admin_members() from public;
grant execute on function public.admin_members() to authenticated;

-- Member: who referred me (code + name)
create or replace function public.my_referrer()
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'code', u.raw_user_meta_data ->> 'referred_by_code',
    'name', (select r.raw_user_meta_data ->> 'full_name' from auth.users r
             where upper(r.raw_user_meta_data ->> 'referral_code') = upper(u.raw_user_meta_data ->> 'referred_by_code') limit 1))
  from auth.users u where u.id = auth.uid();
$$;
revoke all on function public.my_referrer() from public;
grant execute on function public.my_referrer() to authenticated;

-- Referrer: people I referred (name + date)
create or replace function public.my_referrals(p_code text)
returns table (full_name text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from auth.users u where u.id = auth.uid()
      and upper(u.raw_user_meta_data ->> 'referral_code') = upper(p_code)) then return; end if;
  return query select p.full_name, p.created_at from public.profiles p
    where upper(p.referred_by_code) = upper(p_code) order by p.created_at desc limit 100;
end; $$;
revoke all on function public.my_referrals(text) from public;
grant execute on function public.my_referrals(text) to authenticated;
