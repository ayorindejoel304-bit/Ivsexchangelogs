-- IVs EXCHANGE Logs visitor counter fix
-- Run this in the SAME Supabase project connected to your Vercel website.
create table if not exists public.site_visitor_counter (
  id integer primary key check (id = 1),
  total bigint not null default 0 check (total >= 0)
);
insert into public.site_visitor_counter (id, total) values (1, 0) on conflict (id) do nothing;
alter table public.site_visitor_counter enable row level security;
revoke all on public.site_visitor_counter from anon, authenticated;

create or replace function public.record_site_visit()
returns bigint language plpgsql security definer set search_path = '' as $$
declare new_total bigint;
begin
  update public.site_visitor_counter set total = total + 1 where id = 1 returning total into new_total;
  return coalesce(new_total, 0);
end; $$;

create or replace function public.get_site_visit_count()
returns bigint language sql security definer set search_path = '' as $$
  select coalesce((select total from public.site_visitor_counter where id = 1), 0);
$$;

revoke all on function public.record_site_visit() from public;
revoke all on function public.get_site_visit_count() from public;
grant execute on function public.record_site_visit() to anon, authenticated;
grant execute on function public.get_site_visit_count() to anon, authenticated;
