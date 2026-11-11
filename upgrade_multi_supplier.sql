-- IVs EXCHANGE Logs: additive multi-supplier migration
-- Run once in the SAME Supabase project used by the website, after wallet_setup.sql.
-- Existing supplier_products rows remain the Lucy Lynx supplier by default.

alter table public.supplier_products
  add column if not exists supplier_key text not null default 'lucylynxsocials',
  add column if not exists supplier_product_id text,
  add column if not exists logo_key text;

update public.supplier_products
set supplier_product_id = id::text
where supplier_product_id is null;

create index if not exists supplier_products_supplier_key_idx
  on public.supplier_products(supplier_key);

-- The numeric primary key is namespaced by supplier in supplier-sync:
-- Lucy Lynx: original numeric product ID
-- Bestloghub: 2,000,000,000,000 + numeric Bestloghub product ID
-- This avoids collisions while preserving the existing wallet order/RPC shape.

create or replace view public.market_products as
  select p.id, p.category_id, p.category_name, p.name,
         public.sell_price(p) as price, p.stock, p.in_stock,
         p.supplier_key, p.logo_key
  from public.supplier_products p
  where p.active;

revoke all on public.market_products from anon;
grant select on public.market_products to authenticated;
