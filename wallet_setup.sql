-- IVs EXCHANGE Logs v24: WALLET + SUPPLIER API + PAGA FUNDING
-- Run ONCE in Supabase SQL Editor (after auth_setup.sql, upgrade_setup.sql, upgrade2_setup.sql, media_setup.sql).
-- Safe to re-run.

-- ============ WALLET ============
create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance numeric(14,2) not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);
alter table public.wallets enable row level security;
drop policy if exists "own wallet read" on public.wallets;
drop policy if exists "admin wallet read" on public.wallets;
create policy "own wallet read" on public.wallets for select to authenticated using (user_id = auth.uid());
create policy "admin wallet read" on public.wallets for select to authenticated using (public.is_admin());

create table if not exists public.wallet_tx (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  kind text not null,                -- deposit | purchase | refund | adjust
  amount numeric(14,2) not null,     -- signed
  balance_after numeric(14,2) not null,
  ref text, note text,
  created_at timestamptz not null default now()
);
create index if not exists wallet_tx_user on public.wallet_tx(user_id, created_at desc);
alter table public.wallet_tx enable row level security;
drop policy if exists "own tx read" on public.wallet_tx;
drop policy if exists "admin tx read" on public.wallet_tx;
create policy "own tx read" on public.wallet_tx for select to authenticated using (user_id = auth.uid());
create policy "admin tx read" on public.wallet_tx for select to authenticated using (public.is_admin());

-- Paga deposits (created only by the Edge Functions)
create table if not exists public.deposits (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  email text,
  amount numeric(14,2) not null check (amount > 0),
  reference text not null unique,
  provider text not null default 'paga',
  status text not null default 'pending',   -- pending | approved | failed
  created_at timestamptz not null default now(),
  credited_at timestamptz
);
alter table public.deposits enable row level security;
drop policy if exists "own deposits read" on public.deposits;
drop policy if exists "admin deposits read" on public.deposits;
create policy "own deposits read" on public.deposits for select to authenticated using (user_id = auth.uid());
create policy "admin deposits read" on public.deposits for select to authenticated using (public.is_admin());

-- ============ SUPPLIER PRODUCTS ============
create table if not exists public.supplier_products (
  id bigint primary key,                 -- the supplier's product id
  category_id bigint,
  category_name text,
  name text not null,
  supplier_price numeric(14,2) not null default 0,
  stock int not null default 0,
  in_stock boolean not null default false,
  active boolean not null default true,  -- admin can hide a product
  custom_price numeric(14,2),            -- admin can override the selling price
  updated_at timestamptz not null default now()
);
alter table public.supplier_products enable row level security;
drop policy if exists "admin manage supplier products" on public.supplier_products;
create policy "admin manage supplier products" on public.supplier_products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

insert into public.site_settings(key, value) values ('markup_percent', '20') on conflict (key) do nothing;

create or replace function public.sell_price(p public.supplier_products)
returns numeric language sql stable set search_path = '' as $$
  select coalesce(p.custom_price,
    round(p.supplier_price * (1 + coalesce(
      (select nullif(s.value,'')::numeric from public.site_settings s where s.key = 'markup_percent'), 20) / 100), 2));
$$;

-- Customers see selling price only (never the supplier cost)
create or replace view public.market_products as
  select p.id, p.category_id, p.category_name, p.name, public.sell_price(p) as price, p.stock, p.in_stock
  from public.supplier_products p where p.active;
revoke all on public.market_products from anon;
grant select on public.market_products to authenticated;

-- ============ ORDERS ============
create table if not exists public.wallet_orders (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  kind text not null,                  -- supplier | own
  product_ref text,
  product_name text not null,
  quantity int not null default 1,
  charge numeric(14,2) not null,
  supplier_charge numeric(14,2),
  supplier_order_id text,
  status text not null default 'pending',  -- pending | processing | completed | failed | refunded
  keys jsonb not null default '[]'::jsonb,
  delivery text,
  error text,
  created_at timestamptz not null default now()
);
create index if not exists wallet_orders_user on public.wallet_orders(user_id, created_at desc);
alter table public.wallet_orders enable row level security;
drop policy if exists "own wallet orders read" on public.wallet_orders;
drop policy if exists "admin wallet orders read" on public.wallet_orders;
create policy "own wallet orders read" on public.wallet_orders for select to authenticated using (user_id = auth.uid());
create policy "admin wallet orders read" on public.wallet_orders for select to authenticated using (public.is_admin());

-- ============ INTERNAL HELPERS ============
create or replace function public._wallet_apply(p_user uuid, p_delta numeric, p_kind text, p_ref text, p_note text)
returns numeric language plpgsql security definer set search_path = '' as $$
declare nb numeric;
begin
  insert into public.wallets(user_id, balance) values (p_user, 0) on conflict (user_id) do nothing;
  update public.wallets set balance = balance + p_delta, updated_at = now()
    where user_id = p_user and balance + p_delta >= 0 returning balance into nb;
  if nb is null then raise exception 'insufficient_balance'; end if;
  insert into public.wallet_tx(user_id, kind, amount, balance_after, ref, note)
    values (p_user, p_kind, p_delta, nb, p_ref, p_note);
  return nb;
end; $$;
revoke all on function public._wallet_apply(uuid, numeric, text, text, text) from public, anon, authenticated;

-- Keeps the 10% referral programme working: a completed sale is recorded in public.orders
create or replace function public._record_sale(p_order bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.orders(user_id, email, full_name, product_title, price, referral_code, status, amount)
  select o.user_id, p.email, p.full_name, o.product_name || ' x' || o.quantity, '₦' || o.charge || ' (wallet)',
         p.referred_by_code, 'completed', o.charge
  from public.wallet_orders o left join public.profiles p on p.id = o.user_id where o.id = p_order;
end; $$;
revoke all on function public._record_sale(bigint) from public, anon, authenticated;

-- ============ MEMBER FUNCTIONS ============
create or replace function public.my_balance()
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select balance from public.wallets where user_id = auth.uid()), 0);
$$;
revoke all on function public.my_balance() from public, anon;
grant execute on function public.my_balance() to authenticated;

-- Buy one of YOUR OWN products (added in Admin) from the wallet. You deliver it, then mark it delivered.
create or replace function public.buy_own_item(p_media_id bigint, p_qty int default 1)
returns json language plpgsql security definer set search_path = '' as $$
declare m public.media_items; unit numeric; total numeric; oid bigint; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 20 then raise exception 'bad_quantity'; end if;
  select * into m from public.media_items where id = p_media_id;
  if not found then raise exception 'product_not_found'; end if;
  if (to_jsonb(m) ->> 'in_stock') = 'false' then raise exception 'out_of_stock'; end if;
  unit := substring(replace(coalesce(m.price, ''), ',', '') from '[0-9]+(?:\.[0-9]+)?')::numeric;
  if unit is null or unit <= 0 then raise exception 'no_price'; end if;
  total := unit * p_qty;
  insert into public.wallet_orders(user_id, kind, product_ref, product_name, quantity, charge, status)
    values (uid, 'own', p_media_id::text, m.title, p_qty, total, 'processing') returning id into oid;
  perform public._wallet_apply(uid, -total, 'purchase', 'order:' || oid, m.title || ' x' || p_qty);
  return json_build_object('order_id', oid, 'charge', total);
end; $$;
revoke all on function public.buy_own_item(bigint, int) from public, anon;
grant execute on function public.buy_own_item(bigint, int) to authenticated;

-- ============ ADMIN FUNCTIONS ============
create or replace function public.admin_credit(p_email text, p_amount numeric, p_note text default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare uid uuid; nb numeric;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No member with that email'; end if;
  nb := public._wallet_apply(uid, p_amount, 'adjust', 'admin', coalesce(p_note, 'Admin adjustment'));
  return nb;
end; $$;
revoke all on function public.admin_credit(text, numeric, text) from public, anon;
grant execute on function public.admin_credit(text, numeric, text) to authenticated;

create or replace function public.admin_deliver_order(p_order bigint, p_text text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.wallet_orders set status = 'completed', delivery = p_text
    where id = p_order and status = 'processing';
  if found then perform public._record_sale(p_order); end if;
end; $$;
revoke all on function public.admin_deliver_order(bigint, text) from public, anon;
grant execute on function public.admin_deliver_order(bigint, text) to authenticated;

create or replace function public.admin_refund_order(p_order bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.wallet_orders;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into o from public.wallet_orders where id = p_order for update;
  if not found or o.status not in ('pending', 'processing') then raise exception 'Order cannot be refunded'; end if;
  perform public._wallet_apply(o.user_id, o.charge, 'refund', 'order:' || o.id, 'Refund: ' || o.product_name);
  update public.wallet_orders set status = 'refunded' where id = o.id;
end; $$;
revoke all on function public.admin_refund_order(bigint) from public, anon;
grant execute on function public.admin_refund_order(bigint) to authenticated;

-- ============ SERVICE-ONLY FUNCTIONS (called by Edge Functions) ============
create or replace function public.svc_create_deposit(p_user uuid, p_amount numeric, p_ref text, p_email text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_amount < 100 or p_amount > 2000000 then raise exception 'bad_amount'; end if;
  if (select count(*) from public.deposits where user_id = p_user and status = 'pending'
        and created_at > now() - interval '1 hour') >= 10 then raise exception 'too_many_pending'; end if;
  insert into public.deposits(user_id, email, amount, reference) values (p_user, p_email, p_amount, p_ref);
end; $$;

-- Credits a deposit exactly once. Safe to call repeatedly (callback + verify).
create or replace function public.svc_credit_deposit(p_ref text, p_paid numeric)
returns json language plpgsql security definer set search_path = '' as $$
declare d public.deposits; nb numeric;
begin
  select * into d from public.deposits where reference = p_ref for update;
  if not found then raise exception 'unknown_reference'; end if;
  if d.status = 'approved' then return json_build_object('already', true, 'amount', d.amount); end if;
  if p_paid < d.amount then raise exception 'amount_mismatch'; end if;
  nb := public._wallet_apply(d.user_id, d.amount, 'deposit', 'paga:' || d.reference, 'Wallet funding via Paga');
  update public.deposits set status = 'approved', credited_at = now() where id = d.id;
  return json_build_object('already', false, 'amount', d.amount, 'balance', nb);
end; $$;

create or replace function public.svc_deposit_owner(p_ref text)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('user_id', user_id, 'amount', amount, 'status', status) from public.deposits where reference = p_ref;
$$;

create or replace function public.svc_reserve(p_user uuid, p_product bigint, p_qty int)
returns json language plpgsql security definer set search_path = '' as $$
declare sp public.supplier_products; total numeric; oid bigint;
begin
  if p_qty is null or p_qty < 1 or p_qty > 100 then raise exception 'bad_quantity'; end if;
  select * into sp from public.supplier_products where id = p_product and active;
  if not found then raise exception 'product_not_found'; end if;
  if not sp.in_stock or sp.stock < p_qty then raise exception 'out_of_stock'; end if;
  total := public.sell_price(sp) * p_qty;
  insert into public.wallet_orders(user_id, kind, product_ref, product_name, quantity, charge, status)
    values (p_user, 'supplier', p_product::text, sp.name, p_qty, total, 'pending') returning id into oid;
  perform public._wallet_apply(p_user, -total, 'purchase', 'order:' || oid, sp.name || ' x' || p_qty);
  return json_build_object('order_id', oid, 'charge', total);
end; $$;

create or replace function public.svc_finalize(p_order bigint, p_keys jsonb, p_supplier_order text, p_supplier_charge numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.wallet_orders;
begin
  update public.wallet_orders set status = 'completed', keys = coalesce(p_keys, '[]'::jsonb),
    supplier_order_id = p_supplier_order, supplier_charge = p_supplier_charge
    where id = p_order and status = 'pending' returning * into o;
  if not found then return; end if;
  update public.supplier_products set stock = greatest(stock - o.quantity, 0),
    in_stock = (stock - o.quantity) > 0 where id = o.product_ref::bigint;
  perform public._record_sale(p_order);
end; $$;

create or replace function public.svc_fail(p_order bigint, p_error text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.wallet_orders;
begin
  select * into o from public.wallet_orders where id = p_order for update;
  if not found or o.status <> 'pending' then return; end if;
  perform public._wallet_apply(o.user_id, o.charge, 'refund', 'order:' || o.id, 'Refund: ' || o.product_name);
  update public.wallet_orders set status = 'failed', error = left(p_error, 300) where id = o.id;
end; $$;

revoke all on function public.svc_create_deposit(uuid, numeric, text, text) from public, anon, authenticated;
revoke all on function public.svc_credit_deposit(text, numeric) from public, anon, authenticated;
revoke all on function public.svc_deposit_owner(text) from public, anon, authenticated;
revoke all on function public.svc_reserve(uuid, bigint, int) from public, anon, authenticated;
revoke all on function public.svc_finalize(bigint, jsonb, text, numeric) from public, anon, authenticated;
revoke all on function public.svc_fail(bigint, text) from public, anon, authenticated;
grant execute on function public.svc_create_deposit(uuid, numeric, text, text) to service_role;
grant execute on function public.svc_credit_deposit(text, numeric) to service_role;
grant execute on function public.svc_deposit_owner(text) to service_role;
grant execute on function public.svc_reserve(uuid, bigint, int) to service_role;
grant execute on function public.svc_finalize(bigint, jsonb, text, numeric) to service_role;
grant execute on function public.svc_fail(bigint, text) to service_role;
