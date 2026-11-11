-- Flamin' Pit: ORDERS add-on for the Supabase database.
-- Run this ONCE in Supabase > SQL Editor > New query (after supabase-setup.sql). Re-running is safe.
-- It adds a private "orders" table plus the functions the website uses to save orders
-- (customers) and to list / update / delete them (Owner mode > Orders).

create table if not exists fp_private.orders (
  id          uuid primary key default gen_random_uuid(),
  code        text not null,
  customer_id uuid references fp_private.customers(id) on delete set null,
  name        text not null,
  phone       text not null,
  note        text not null default '',
  method      text not null default '',
  ref         text not null default '',
  items       jsonb not null default '[]'::jsonb,
  total       numeric not null default 0,
  unpriced    int not null default 0,
  status      text not null default 'new' check (status in ('new','preparing','ready','done','cancelled')),
  paid        boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists fp_orders_created on fp_private.orders (created_at desc);
alter table fp_private.orders enable row level security;

create or replace function fp_private.order_json(o fp_private.orders) returns jsonb
language sql immutable as $$
  select jsonb_build_object('id', o.id, 'code', o.code, 'name', o.name, 'phone', o.phone, 'note', o.note,
                            'method', o.method, 'ref', o.ref, 'items', o.items, 'total', o.total,
                            'unpriced', o.unpriced, 'status', o.status, 'paid', o.paid, 'created_at', o.created_at)
$$;

-- customers (signed in or guests) place an order
create or replace function public.fp_place_order(
  p_token text, p_code text, p_name text, p_phone text, p_note text, p_method text, p_ref text,
  p_total numeric, p_unpriced int, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare
  nm text := btrim(coalesce(p_name,'')); ph text := fp_private.norm_phone(p_phone);
  items jsonb; tot numeric; cid uuid;
begin
  if char_length(nm) < 2 or char_length(nm) > 60 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then
    return jsonb_build_object('ok', false, 'error', 'bad_order'); end if;
  -- rebuild the item list so only expected, size-limited fields are stored
  select jsonb_agg(jsonb_build_object('n', left(btrim(i->>'n'), 120),
                                      'q', least(99, greatest(1, coalesce((i->>'q')::int, 1))),
                                      'p', greatest(0, coalesce((i->>'p')::numeric, 0)))),
         sum(least(99, greatest(1, coalesce((i->>'q')::int, 1))) * greatest(0, coalesce((i->>'p')::numeric, 0)))
    into items, tot
    from jsonb_array_elements(p_items) i;
  if (select count(*) from fp_private.orders where created_at > now() - interval '1 hour') >= 300
     or (select count(*) from fp_private.orders where phone = ph and created_at > now() - interval '1 hour') >= 15 then
    return jsonb_build_object('ok', false, 'error', 'busy'); end if;
  cid := fp_private.who('c', p_token);
  insert into fp_private.orders (code, customer_id, name, phone, note, method, ref, items, total, unpriced)
  values (left(btrim(coalesce(p_code,'')), 20), cid, nm, ph, left(btrim(coalesce(p_note,'')), 300),
          left(btrim(coalesce(p_method,'')), 40), left(btrim(coalesce(p_ref,'')), 40),
          items, coalesce(tot, 0), greatest(0, coalesce(p_unpriced, 0)));
  return jsonb_build_object('ok', true);
end $$;

-- owner: list orders (newest first, last 500)
create or replace function public.fp_admin_orders(p_token text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  return jsonb_build_object('ok', true, 'orders', coalesce((
    select jsonb_agg(fp_private.order_json(x) order by x.created_at desc)
    from (select * from fp_private.orders order by created_at desc limit 500) x), '[]'::jsonb));
end $$;

-- owner: change status / paid
create or replace function public.fp_admin_order_update(p_token text, p_id uuid, p_status text, p_paid boolean) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if p_status not in ('new','preparing','ready','done','cancelled') then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  update fp_private.orders set status = p_status, paid = coalesce(p_paid, false), updated_at = now() where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- owner: delete
create or replace function public.fp_admin_order_delete(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  delete from fp_private.orders where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- permissions: the website may call only these functions
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('fp_place_order','fp_admin_orders','fp_admin_order_update','fp_admin_order_delete')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('grant execute on function %s to anon, authenticated', r.sig);
  end loop;
end $$;
