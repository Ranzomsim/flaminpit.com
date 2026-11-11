-- =====================================================================
--  Flamin' Pit — shared accounts (Supabase)
--  Run this ONCE in Supabase > SQL Editor > New query > paste > Run.
--  It is safe to run again later (it only adds / updates things).
-- =====================================================================
--  STEP 1 (REQUIRED): choose YOUR owner login below. Change v_user and
--  v_pass (password at least 10 characters). The script refuses to run
--  until you do, so nobody can use a default password.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists fp_private;

-- ---------- tables (kept in a private schema, never exposed to the web) ----------
create table if not exists fp_private.owners (
  id         uuid primary key default gen_random_uuid(),
  username   text not null,
  pw_hash    text not null,
  created_at timestamptz not null default now(),
  last_login timestamptz
);
create unique index if not exists fp_owners_username_key on fp_private.owners (lower(username));

create table if not exists fp_private.customers (
  id                 uuid primary key default gen_random_uuid(),
  phone              text not null unique,           -- normalised, e.g. +639171234567
  name               text not null,
  pw_hash            text not null,
  must_change        boolean not null default false, -- true after the owner sets a temporary password
  disabled           boolean not null default false,
  reset_requested_at timestamptz,
  note               text not null default '',
  created_at         timestamptz not null default now(),
  last_login         timestamptz
);

create table if not exists fp_private.sessions (
  token_hash text primary key,
  kind       text not null check (kind in ('c','o')),
  subject    uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists fp_sessions_subject on fp_private.sessions (subject);

create table if not exists fp_private.throttle (
  key          text primary key,
  fails        int not null default 0,
  locked_until timestamptz,
  updated_at   timestamptz not null default now()
);

alter table fp_private.owners    enable row level security;
alter table fp_private.customers enable row level security;
alter table fp_private.sessions  enable row level security;
alter table fp_private.throttle  enable row level security;

-- ---------- first owner account ----------
do $$
declare
  v_user text := 'owner';                    -- <<< CHANGE ME
  v_pass text := 'CHANGE-THIS-PASSWORD';     -- <<< CHANGE ME (10+ characters)
begin
  if not exists (select 1 from fp_private.owners) then
    if v_pass = 'CHANGE-THIS-PASSWORD' or length(v_pass) < 10 then
      raise exception 'STOP: edit v_user and v_pass at the top of this script (password 10+ characters), then run it again.';
    end if;
    insert into fp_private.owners (username, pw_hash)
    values (v_user, extensions.crypt(v_pass, extensions.gen_salt('bf', 10)));
  end if;
end $$;

-- ---------- private helpers ----------
create or replace function fp_private.norm_phone(p text) returns text
language plpgsql immutable as $$
declare s text := regexp_replace(coalesce(p,''), '[\s().\-]', '', 'g');
begin
  if s ~ '^\+63' then
    return case when s ~ '^\+639[0-9]{9}$' then s else null end;   -- PH mobile only
  end if;
  if s ~ '^\+[0-9]{8,15}$' then return s; end if;                  -- other countries
  if s ~ '^09[0-9]{9}$'    then return '+63' || substr(s, 2); end if;
  if s ~ '^9[0-9]{9}$'     then return '+63' || s; end if;
  if s ~ '^639[0-9]{9}$'   then return '+' || s; end if;
  return null;
end $$;

create or replace function fp_private.tok_hash(t text) returns text
language sql immutable as $$ select encode(extensions.digest(coalesce(t,''), 'sha256'), 'hex') $$;

create or replace function fp_private.new_session(k text, s uuid, days int) returns text
language plpgsql as $$
declare t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from fp_private.sessions where expires_at < now();
  insert into fp_private.sessions (token_hash, kind, subject, expires_at)
  values (fp_private.tok_hash(t), k, s, now() + make_interval(days => days));
  return t;
end $$;

create or replace function fp_private.who(k text, t text) returns uuid
language sql stable as $$
  select subject from fp_private.sessions
  where token_hash = fp_private.tok_hash(t) and kind = k and expires_at > now()
$$;

-- returns seconds still locked (0 = free)
create or replace function fp_private.locked_for(k text) returns int
language sql stable as $$
  select coalesce((select greatest(0, ceil(extract(epoch from locked_until - now()))::int)
                   from fp_private.throttle where key = k), 0)
$$;

create or replace function fp_private.fail(k text, max_fails int, lock_minutes int) returns void
language plpgsql as $$
begin
  insert into fp_private.throttle as t (key, fails) values (k, 1)
  on conflict (key) do update
    set fails = case when t.locked_until is not null and t.locked_until < now() then 1 else t.fails + 1 end,
        updated_at = now();
  update fp_private.throttle
     set locked_until = now() + make_interval(mins => lock_minutes), fails = 0
   where key = k and fails >= max_fails;
end $$;

create or replace function fp_private.clear(k text) returns void
language sql as $$ delete from fp_private.throttle where key = k $$;

create or replace function fp_private.cust_json(c fp_private.customers) returns jsonb
language sql immutable as $$
  select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'must_change', c.must_change,
                            'disabled', c.disabled, 'reset_requested_at', c.reset_requested_at,
                            'note', c.note, 'created_at', c.created_at, 'last_login', c.last_login)
$$;

-- =====================================================================
--  PUBLIC FUNCTIONS (these are what the website calls)
-- =====================================================================

-- ---------- customers ----------
create or replace function public.fp_register(p_phone text, p_name text, p_password text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare ph text := fp_private.norm_phone(p_phone); nm text := btrim(coalesce(p_name,'')); c fp_private.customers;
begin
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  if char_length(nm) < 2 or char_length(nm) > 60 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if char_length(coalesce(p_password,'')) < 8 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  if (select count(*) from fp_private.customers where created_at > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  if exists (select 1 from fp_private.customers where phone = ph) then return jsonb_build_object('ok', false, 'error', 'phone_taken'); end if;
  begin
    insert into fp_private.customers (phone, name, pw_hash, last_login)
    values (ph, nm, crypt(p_password, gen_salt('bf', 10)), now()) returning * into c;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'phone_taken');
  end;
  return jsonb_build_object('ok', true, 'token', fp_private.new_session('c', c.id, 60), 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_login(p_phone text, p_password text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare ph text := fp_private.norm_phone(p_phone); k text; c fp_private.customers; secs int; good boolean;
begin
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  k := 'c:' || ph; secs := fp_private.locked_for(k);
  if secs > 0 then return jsonb_build_object('ok', false, 'error', 'locked', 'seconds', secs); end if;
  select * into c from fp_private.customers where phone = ph;
  good := (c.id is not null) and c.pw_hash = crypt(coalesce(p_password,''), c.pw_hash);
  if c.id is null then perform crypt(coalesce(p_password,''), gen_salt('bf', 10)); end if;  -- same timing either way
  if not good then
    perform fp_private.fail(k, 5, 5);
    return jsonb_build_object('ok', false, 'error', 'bad_credentials');
  end if;
  if c.disabled then return jsonb_build_object('ok', false, 'error', 'disabled'); end if;
  perform fp_private.clear(k);
  update fp_private.customers set last_login = now() where id = c.id returning * into c;
  return jsonb_build_object('ok', true, 'token', fp_private.new_session('c', c.id, 60), 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_me(p_token text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare v_id uuid := fp_private.who('c', p_token); c fp_private.customers;
begin
  select * into c from fp_private.customers where customers.id = v_id and not disabled;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  return jsonb_build_object('ok', true, 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_logout(p_token text) returns jsonb
language sql security definer set search_path = extensions, public, pg_temp as $$
  with d as (delete from fp_private.sessions where token_hash = fp_private.tok_hash(p_token) returning 1)
  select jsonb_build_object('ok', true)
$$;

create or replace function public.fp_update_profile(p_token text, p_name text, p_phone text, p_password text default null) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare v_id uuid := fp_private.who('c', p_token); c fp_private.customers; nm text := btrim(coalesce(p_name,'')); ph text := fp_private.norm_phone(p_phone); k text; secs int;
begin
  select * into c from fp_private.customers where customers.id = v_id and not disabled;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if char_length(nm) < 2 or char_length(nm) > 60 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  if ph <> c.phone then
    k := 'c:' || c.phone; secs := fp_private.locked_for(k);
    if secs > 0 then return jsonb_build_object('ok', false, 'error', 'locked', 'seconds', secs); end if;
    if c.pw_hash <> crypt(coalesce(p_password,''), c.pw_hash) then
      perform fp_private.fail(k, 5, 5);
      return jsonb_build_object('ok', false, 'error', 'bad_password');
    end if;
    if exists (select 1 from fp_private.customers x where x.phone = ph) then return jsonb_build_object('ok', false, 'error', 'phone_taken'); end if;
  end if;
  update fp_private.customers set name = nm, phone = ph where customers.id = c.id returning * into c;
  return jsonb_build_object('ok', true, 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_change_password(p_token text, p_current text, p_new text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare v_id uuid := fp_private.who('c', p_token); c fp_private.customers; k text; secs int;
begin
  select * into c from fp_private.customers where customers.id = v_id and not disabled;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  k := 'c:' || c.phone; secs := fp_private.locked_for(k);
  if secs > 0 then return jsonb_build_object('ok', false, 'error', 'locked', 'seconds', secs); end if;
  if c.pw_hash <> crypt(coalesce(p_current,''), c.pw_hash) then
    perform fp_private.fail(k, 5, 5);
    return jsonb_build_object('ok', false, 'error', 'bad_password');
  end if;
  if char_length(coalesce(p_new,'')) < 8 or char_length(p_new) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  update fp_private.customers set pw_hash = crypt(p_new, gen_salt('bf', 10)), must_change = false where customers.id = c.id returning * into c;
  delete from fp_private.sessions where subject = c.id and token_hash <> fp_private.tok_hash(p_token);  -- sign out other devices
  perform fp_private.clear(k);
  return jsonb_build_object('ok', true, 'user', fp_private.cust_json(c));
end $$;

-- "Forgot password": flags the account so the owner sees it. Never reveals whether the number exists.
create or replace function public.fp_request_reset(p_phone text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare ph text := fp_private.norm_phone(p_phone); k text;
begin
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  k := 'r:' || ph;
  if fp_private.locked_for(k) > 0 then return jsonb_build_object('ok', true); end if;
  perform fp_private.fail(k, 3, 60);
  update fp_private.customers set reset_requested_at = now() where phone = ph and not disabled;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- owners ----------
create or replace function public.fp_owner_login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare u text := btrim(coalesce(p_username,'')); k text := 'o:' || lower(btrim(coalesce(p_username,''))); o fp_private.owners; secs int; good boolean;
begin
  secs := fp_private.locked_for(k);
  if secs > 0 then return jsonb_build_object('ok', false, 'error', 'locked', 'seconds', secs); end if;
  select * into o from fp_private.owners where lower(username) = lower(u);
  good := (o.id is not null) and o.pw_hash = crypt(coalesce(p_password,''), o.pw_hash);
  if o.id is null then perform crypt(coalesce(p_password,''), gen_salt('bf', 10)); end if;
  if not good then
    perform fp_private.fail(k, 6, 10);
    return jsonb_build_object('ok', false, 'error', 'bad_credentials');
  end if;
  perform fp_private.clear(k);
  update fp_private.owners set last_login = now() where id = o.id;
  return jsonb_build_object('ok', true, 'token', fp_private.new_session('o', o.id, 1), 'owner', jsonb_build_object('id', o.id, 'username', o.username));
end $$;

create or replace function public.fp_owner_logout(p_token text) returns jsonb
language sql security definer set search_path = extensions, public, pg_temp as $$
  with d as (delete from fp_private.sessions where token_hash = fp_private.tok_hash(p_token) returning 1)
  select jsonb_build_object('ok', true)
$$;

create or replace function public.fp_owner_me(p_token text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare o fp_private.owners;
begin
  select * into o from fp_private.owners where id = fp_private.who('o', p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  return jsonb_build_object('ok', true, 'owner', jsonb_build_object('id', o.id, 'username', o.username));
end $$;

create or replace function public.fp_owner_change_password(p_token text, p_current text, p_new text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare o fp_private.owners; k text; secs int;
begin
  select * into o from fp_private.owners where id = fp_private.who('o', p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  k := 'o:' || lower(o.username); secs := fp_private.locked_for(k);
  if secs > 0 then return jsonb_build_object('ok', false, 'error', 'locked', 'seconds', secs); end if;
  if o.pw_hash <> crypt(coalesce(p_current,''), o.pw_hash) then
    perform fp_private.fail(k, 6, 10);
    return jsonb_build_object('ok', false, 'error', 'bad_password');
  end if;
  if char_length(coalesce(p_new,'')) < 10 or char_length(p_new) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  update fp_private.owners set pw_hash = crypt(p_new, gen_salt('bf', 10)) where id = o.id;
  delete from fp_private.sessions where subject = o.id and token_hash <> fp_private.tok_hash(p_token);
  perform fp_private.clear(k);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- owner admin: customers ----------
create or replace function public.fp_admin_customers(p_token text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  return jsonb_build_object('ok', true, 'customers',
    coalesce((select jsonb_agg(fp_private.cust_json(c) order by c.created_at desc) from fp_private.customers c), '[]'::jsonb));
end $$;

create or replace function public.fp_admin_customer_create(p_token text, p_phone text, p_name text, p_password text, p_must_change boolean default true) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare ph text := fp_private.norm_phone(p_phone); nm text := btrim(coalesce(p_name,'')); c fp_private.customers;
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  if char_length(nm) < 2 or char_length(nm) > 60 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if char_length(coalesce(p_password,'')) < 8 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  begin
    insert into fp_private.customers (phone, name, pw_hash, must_change)
    values (ph, nm, crypt(p_password, gen_salt('bf', 10)), coalesce(p_must_change, true)) returning * into c;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'phone_taken');
  end;
  return jsonb_build_object('ok', true, 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_admin_customer_save(p_token text, p_id uuid, p_name text, p_phone text, p_note text, p_disabled boolean) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare ph text := fp_private.norm_phone(p_phone); nm text := btrim(coalesce(p_name,'')); c fp_private.customers;
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if ph is null then return jsonb_build_object('ok', false, 'error', 'bad_phone'); end if;
  if char_length(nm) < 2 or char_length(nm) > 60 then return jsonb_build_object('ok', false, 'error', 'bad_name'); end if;
  if exists (select 1 from fp_private.customers x where x.phone = ph and x.id <> p_id) then return jsonb_build_object('ok', false, 'error', 'phone_taken'); end if;
  update fp_private.customers set name = nm, phone = ph, note = left(btrim(coalesce(p_note,'')), 500), disabled = coalesce(p_disabled, false)
   where id = p_id returning * into c;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if c.disabled then delete from fp_private.sessions where subject = c.id; end if;
  return jsonb_build_object('ok', true, 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_admin_customer_reset(p_token text, p_id uuid, p_password text, p_must_change boolean default true) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare c fp_private.customers;
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if char_length(coalesce(p_password,'')) < 8 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  update fp_private.customers
     set pw_hash = crypt(p_password, gen_salt('bf', 10)), must_change = coalesce(p_must_change, true), reset_requested_at = null
   where id = p_id returning * into c;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  delete from fp_private.sessions where subject = c.id;
  perform fp_private.clear('c:' || c.phone);
  return jsonb_build_object('ok', true, 'user', fp_private.cust_json(c));
end $$;

create or replace function public.fp_admin_customer_delete(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  delete from fp_private.sessions where subject = p_id;
  delete from fp_private.customers where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- owner admin: owner accounts ----------
create or replace function public.fp_admin_owners(p_token text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare me uuid := fp_private.who('o', p_token);
begin
  if me is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  return jsonb_build_object('ok', true, 'me', me, 'owners',
    coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'username', o.username, 'created_at', o.created_at, 'last_login', o.last_login) order by o.created_at) from fp_private.owners o), '[]'::jsonb));
end $$;

create or replace function public.fp_admin_owner_create(p_token text, p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare u text := btrim(coalesce(p_username,''));
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if u !~ '^[A-Za-z0-9._-]{3,32}$' then return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  if char_length(coalesce(p_password,'')) < 10 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  begin
    insert into fp_private.owners (username, pw_hash) values (u, crypt(p_password, gen_salt('bf', 10)));
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'username_taken');
  end;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.fp_admin_owner_rename(p_token text, p_id uuid, p_username text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare u text := btrim(coalesce(p_username,'')); n int;
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if u !~ '^[A-Za-z0-9._-]{3,32}$' then return jsonb_build_object('ok', false, 'error', 'bad_username'); end if;
  begin
    update fp_private.owners set username = u where id = p_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'username_taken');
  end;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.fp_admin_owner_reset(p_token text, p_id uuid, p_password text) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare n int; o fp_private.owners;
begin
  if fp_private.who('o', p_token) is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if char_length(coalesce(p_password,'')) < 10 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'weak_password'); end if;
  update fp_private.owners set pw_hash = crypt(p_password, gen_salt('bf', 10)) where id = p_id returning * into o;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if o.id <> fp_private.who('o', p_token) then delete from fp_private.sessions where subject = o.id; end if;
  perform fp_private.clear('o:' || lower(o.username));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.fp_admin_owner_delete(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = extensions, public, pg_temp as $$
declare me uuid := fp_private.who('o', p_token);
begin
  if me is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  if p_id = me then return jsonb_build_object('ok', false, 'error', 'cannot_delete_self'); end if;
  if (select count(*) from fp_private.owners) <= 1 then return jsonb_build_object('ok', false, 'error', 'last_owner'); end if;
  delete from fp_private.sessions where subject = p_id;
  delete from fp_private.owners where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- permissions: the website (anon key) may call ONLY the fp_* functions ----------
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'fp\_%'
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('grant execute on function %s to anon, authenticated', r.sig);
  end loop;
end $$;

-- Done. Your tables live in the private schema "fp_private": the website can never read them directly,
-- only through the functions above (which check the owner/customer session first).
