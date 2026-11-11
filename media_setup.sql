-- IVs EXCHANGE Logs: product photos/videos. Run once in Supabase SQL Editor.
-- (auth_setup.sql must already be run, because this uses public.is_admin())
create table if not exists public.media_items (
  id bigint generated always as identity primary key,
  title text not null,
  price text,
  description text,
  media_type text not null check (media_type in ('image','video')),
  media_url text not null,
  storage_path text,
  created_at timestamptz not null default now()
);
alter table public.media_items enable row level security;
drop policy if exists "members read media" on public.media_items;
drop policy if exists "admin insert media" on public.media_items;
drop policy if exists "admin delete media" on public.media_items;
create policy "members read media" on public.media_items for select to authenticated using (true);
create policy "admin insert media" on public.media_items for insert to authenticated with check (public.is_admin());
create policy "admin delete media" on public.media_items for delete to authenticated using (public.is_admin());

insert into storage.buckets (id, name, public) values ('product-media','product-media',true)
  on conflict (id) do update set public = true;
drop policy if exists "public read product media" on storage.objects;
drop policy if exists "admin upload product media" on storage.objects;
drop policy if exists "admin delete product media" on storage.objects;
create policy "public read product media" on storage.objects for select using (bucket_id = 'product-media');
create policy "admin upload product media" on storage.objects for insert to authenticated with check (bucket_id = 'product-media' and public.is_admin());
create policy "admin delete product media" on storage.objects for delete to authenticated using (bucket_id = 'product-media' and public.is_admin());
