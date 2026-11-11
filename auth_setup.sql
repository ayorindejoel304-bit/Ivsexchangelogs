-- IVs EXCHANGE Logs: admin check used by the website login.
-- Run once in Supabase SQL Editor. Then add YOUR admin email at the bottom.
create table if not exists public.admin_emails (email text primary key);
alter table public.admin_emails enable row level security;
revoke all on public.admin_emails from anon, authenticated;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.admin_emails
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- REPLACE with your real admin email, then run:
insert into public.admin_emails (email) values ('YOUR_ADMIN_EMAIL@example.com') on conflict do nothing;
