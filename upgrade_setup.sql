-- IVs EXCHANGE Logs v10 upgrade. Run once in Supabase SQL Editor.
-- Needs auth_setup.sql (is_admin) and the members/profiles SQL to be run first.

-- Product categories + extra photos/videos
alter table public.media_items add column if not exists category text;
alter table public.media_items add column if not exists extra jsonb not null default '[]'::jsonb;

-- Orders (recorded when a customer presses Purchase)
create table if not exists public.orders (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid(),
  email text, full_name text, product_title text, price text, referral_code text,
  status text not null default 'new', amount numeric,
  created_at timestamptz not null default now()
);
alter table public.orders enable row level security;
drop policy if exists "member add order" on public.orders;
drop policy if exists "member read own orders" on public.orders;
drop policy if exists "admin read orders" on public.orders;
drop policy if exists "admin update orders" on public.orders;
create policy "member add order" on public.orders for insert to authenticated with check (user_id = auth.uid());
create policy "member read own orders" on public.orders for select to authenticated using (user_id = auth.uid());
create policy "admin read orders" on public.orders for select to authenticated using (public.is_admin());
create policy "admin update orders" on public.orders for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Reviews
create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid(),
  name text not null, rating int not null check (rating between 1 and 5), text text not null,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.reviews enable row level security;
drop policy if exists "public read approved reviews" on public.reviews;
drop policy if exists "member add review" on public.reviews;
drop policy if exists "admin manage reviews" on public.reviews;
create policy "public read approved reviews" on public.reviews for select to anon, authenticated using (approved = true);
create policy "member add review" on public.reviews for insert to authenticated with check (user_id = auth.uid() and approved = false);
create policy "admin manage reviews" on public.reviews for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Announcement banner
create table if not exists public.site_settings (key text primary key, value text);
alter table public.site_settings enable row level security;
drop policy if exists "public read settings" on public.site_settings;
drop policy if exists "admin write settings" on public.site_settings;
create policy "public read settings" on public.site_settings for select to anon, authenticated using (true);
create policy "admin write settings" on public.site_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Referral earnings for the logged-in referrer (10% of completed sales)
create or replace function public.my_referral_stats(p_code text)
returns json language plpgsql security definer set search_path = '' as $$
declare ok boolean; r int; c int; s numeric;
begin
  select exists (select 1 from auth.users u where u.id = auth.uid()
    and upper(u.raw_user_meta_data ->> 'referral_code') = upper(p_code)) into ok;
  if not ok then return json_build_object('referred',0,'completed',0,'commission',0); end if;
  select count(*) into r from public.profiles where upper(referred_by_code) = upper(p_code);
  select count(*), coalesce(sum(amount),0) * 0.10 into c, s from public.orders
    where upper(referral_code) = upper(p_code) and status = 'completed';
  return json_build_object('referred',r,'completed',c,'commission',s);
end; $$;
revoke all on function public.my_referral_stats(text) from public;
grant execute on function public.my_referral_stats(text) to authenticated;
