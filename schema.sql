-- ============================================================================
-- Blogger Check-in — Supabase schema
-- Paste this whole file into the Supabase SQL editor (SQL → New query → Run).
-- Safe to re-run: everything is IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================================

create extension if not exists pgcrypto;

-- 1. The pre-registered numbers (your "spreadsheet"). PRIVATE — never readable
--    by the public check-in page. Phone is stored normalized (see norm_phone).
create table if not exists public.blogger_allowlist (
  id         uuid primary key default gen_random_uuid(),
  phone      text not null,               -- normalized: last 9 digits (KSA mobile)
  name       text,
  note       text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists blogger_allowlist_phone_idx on public.blogger_allowlist(phone);

-- 2. Every successful check-in (who came, when).
create table if not exists public.blogger_checkins (
  id           uuid primary key default gen_random_uuid(),
  phone        text not null,
  name         text,
  allowlist_id uuid references public.blogger_allowlist(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists blogger_checkins_created_idx on public.blogger_checkins(created_at desc);

-- Which branch the poster that was scanned belongs to (from the QR's ?branch=).
alter table public.blogger_checkins add column if not exists branch text;
create index if not exists blogger_checkins_branch_idx on public.blogger_checkins(branch);

-- What the blogger picked from the menu (2 coffees + 1 sweet), e.g.
-- [{"category":"COFFEE","name":"Espresso Freddo","name_ar":"..."}, ...]
alter table public.blogger_checkins add column if not exists picks jsonb;

-- 2b. The campaign menu — items available to bloggers, shown on the success
--     screen right after check-in. Managed from the admin console; delivered
--     to the public page only through blogger_checkin() (never direct reads).
create table if not exists public.blogger_menu (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_ar    text,
  note       text,
  category   text,             -- 'COFFEE' | 'SWEET' (null = uncategorized, shown last)
  sort_order int  not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.blogger_menu add column if not exists category text;   -- legacy fixed tag, superseded by category_id

-- 2c. Dynamic menu categories (V60, Milk Coffee, Espresso, Sweet, ...) with a
--     dropdown of items each. kind drives the campaign rule: the blogger picks
--     from 2 different COFFEE-kind categories + 1 SWEET-kind category.
create table if not exists public.blogger_menu_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_ar    text,
  kind       text not null default 'COFFEE' check (kind in ('COFFEE','SWEET')),
  sort_order int  not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.blogger_menu add column if not exists category_id uuid references public.blogger_menu_categories(id) on delete set null;

-- One-time backfill from the old fixed COFFEE/SWEET text tags.
insert into public.blogger_menu_categories(name, name_ar, kind, sort_order)
select 'Coffee', 'قهوة', 'COFFEE', 0
 where exists (select 1 from public.blogger_menu where category = 'COFFEE' and category_id is null)
   and not exists (select 1 from public.blogger_menu_categories where kind = 'COFFEE');
insert into public.blogger_menu_categories(name, name_ar, kind, sort_order)
select 'Sweet', 'حلى', 'SWEET', 100
 where exists (select 1 from public.blogger_menu where category = 'SWEET' and category_id is null)
   and not exists (select 1 from public.blogger_menu_categories where kind = 'SWEET');
update public.blogger_menu
   set category_id = (select id from public.blogger_menu_categories where kind = 'COFFEE' order by sort_order limit 1)
 where category = 'COFFEE' and category_id is null;
update public.blogger_menu
   set category_id = (select id from public.blogger_menu_categories where kind = 'SWEET' order by sort_order limit 1)
 where category = 'SWEET' and category_id is null;

-- 3. Phone normaliser: strip non-digits, keep the last 9 (so "0551234567",
--    "+966551234567" and "551234567" all match the same blogger).
create or replace function public.norm_phone(p text)
returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p,''), '\D', '', 'g'), 9)
$$;

-- 4. The ONLY thing the public page can call. Runs as the owner (security
--    definer), checks the list, records the visit, and returns just a
--    yes/no + the name — the number list itself is never exposed.
-- Older signatures must be dropped (not replaced) so PostgREST doesn't see
-- multiple overloads and refuse the call. New args default to null, so older
-- cached pages that send fewer args still work.
drop function if exists public.blogger_checkin(text, text);
drop function if exists public.blogger_checkin(text, text, text);

create or replace function public.blogger_checkin(p_phone text, p_name text, p_branch text default null, p_picks jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.blogger_allowlist; v_norm text; v_branch text; v_picks jsonb;
begin
  v_norm := public.norm_phone(p_phone);
  v_branch := nullif(upper(left(trim(coalesce(p_branch, '')), 40)), '');
  if length(v_norm) < 6 then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  select * into v_row from public.blogger_allowlist
    where phone = v_norm and active limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_registered');
  end if;
  -- One check-in per blogger: if this number has already checked in, don't
  -- record another — tell them they're already in.
  if exists (select 1 from public.blogger_checkins where phone = v_norm) then
    return jsonb_build_object('ok', false, 'reason', 'already',
      'name', v_row.name);
  end if;
  -- Resolve the picked ids against the ACTIVE menu, server-side: max 2
  -- COFFEE-kind + 1 SWEET-kind items survive — same category (or even the
  -- same item twice) is allowed. Names come from the tables; the client only
  -- ever sends ids, so it can't invent items or inflate consumption numbers.
  if p_picks is not null and jsonb_typeof(p_picks) = 'array' then
    with req as (
      select value as item_id, ordinality
        from jsonb_array_elements_text(p_picks) with ordinality
       limit 6
    ), matched as (
      select m.id, m.name, m.name_ar, c.name as cname, c.kind,
             c.sort_order as csort, r.ordinality
        from req r
        join public.blogger_menu m on m.id::text = r.item_id and m.active
        join public.blogger_menu_categories c on c.id = m.category_id and c.active
    ), kept as (
      (select * from matched where kind = 'COFFEE' order by ordinality limit 2)
      union all
      (select * from matched where kind = 'SWEET' order by ordinality limit 1)
    )
    select jsonb_agg(jsonb_build_object('item_id', id, 'category', cname,
                                        'name', name, 'name_ar', name_ar)
                     order by case kind when 'COFFEE' then 0 else 1 end, csort, ordinality)
      into v_picks
      from kept;
  end if;
  insert into public.blogger_checkins(phone, name, allowlist_id, branch, picks)
    values (v_norm, coalesce(nullif(trim(p_name), ''), v_row.name), v_row.id, v_branch, v_picks);
  return jsonb_build_object('ok', true,
    'name', coalesce(v_row.name, nullif(trim(p_name), '')),
    'picks', coalesce(v_picks, '[]'::jsonb));
end $$;

-- 4b. The menu the form shows BEFORE check-in: active categories with their
--     active items nested (coffee categories first). Security definer so the
--     tables themselves stay locked to anon.
create or replace function public.blogger_menu_public()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'name_ar', c.name_ar, 'kind', c.kind,
           'items', (select coalesce(jsonb_agg(jsonb_build_object(
                              'id', m.id, 'name', m.name, 'name_ar', m.name_ar, 'note', m.note)
                            order by m.sort_order, m.created_at), '[]'::jsonb)
                       from public.blogger_menu m
                      where m.active and m.category_id = c.id))
         order by case c.kind when 'COFFEE' then 0 else 1 end, c.sort_order, c.created_at), '[]'::jsonb)
    from public.blogger_menu_categories c
   where c.active
     and exists (select 1 from public.blogger_menu m where m.active and m.category_id = c.id);
$$;

-- 5. Lock the tables down. RLS on, no anon policies → the public page cannot
--    read or write them directly; it can only call blogger_checkin() above.
--    The admin console signs in (Supabase Auth) and gets full access.
alter table public.blogger_allowlist       enable row level security;
alter table public.blogger_checkins        enable row level security;
alter table public.blogger_menu            enable row level security;
alter table public.blogger_menu_categories enable row level security;

do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname='public' and tablename in ('blogger_allowlist','blogger_checkins','blogger_menu','blogger_menu_categories')
  loop execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

create policy allowlist_admin on public.blogger_allowlist
  for all to authenticated using (true) with check (true);
create policy checkins_admin on public.blogger_checkins
  for all to authenticated using (true) with check (true);
create policy menu_admin on public.blogger_menu
  for all to authenticated using (true) with check (true);
create policy menu_cats_admin on public.blogger_menu_categories
  for all to authenticated using (true) with check (true);

-- anon can execute the check-in + menu functions, nothing else.
grant execute on function public.blogger_checkin(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.blogger_menu_public()                    to anon, authenticated;
grant execute on function public.norm_phone(text)                         to anon, authenticated;

-- ============================================================================
-- Diagnostic — should return true / true / true:
--   select
--     (select count(*) from pg_proc where proname='blogger_checkin')>0 as fn_exists,
--     (select relrowsecurity from pg_class where relname='blogger_allowlist') as allowlist_rls,
--     (select relrowsecurity from pg_class where relname='blogger_checkins')  as checkins_rls;
-- ============================================================================
