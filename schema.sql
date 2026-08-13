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

-- 3. Phone normaliser: strip non-digits, keep the last 9 (so "0551234567",
--    "+966551234567" and "551234567" all match the same blogger).
create or replace function public.norm_phone(p text)
returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p,''), '\D', '', 'g'), 9)
$$;

-- 4. The ONLY thing the public page can call. Runs as the owner (security
--    definer), checks the list, records the visit, and returns just a
--    yes/no + the name — the number list itself is never exposed.
-- The old 2-arg version must be dropped (not replaced) so PostgREST doesn't
-- see two overloads and refuse the call. The 3-arg version defaults
-- p_branch to null, so older cached pages that send only 2 args still work.
drop function if exists public.blogger_checkin(text, text);

create or replace function public.blogger_checkin(p_phone text, p_name text, p_branch text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.blogger_allowlist; v_norm text; v_branch text;
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
  insert into public.blogger_checkins(phone, name, allowlist_id, branch)
    values (v_norm, coalesce(nullif(trim(p_name), ''), v_row.name), v_row.id, v_branch);
  return jsonb_build_object('ok', true, 'name', coalesce(v_row.name, nullif(trim(p_name), '')));
end $$;

-- 5. Lock the tables down. RLS on, no anon policies → the public page cannot
--    read or write them directly; it can only call blogger_checkin() above.
--    The admin console signs in (Supabase Auth) and gets full access.
alter table public.blogger_allowlist enable row level security;
alter table public.blogger_checkins  enable row level security;

do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname='public' and tablename in ('blogger_allowlist','blogger_checkins')
  loop execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

create policy allowlist_admin on public.blogger_allowlist
  for all to authenticated using (true) with check (true);
create policy checkins_admin on public.blogger_checkins
  for all to authenticated using (true) with check (true);

-- anon can execute the check-in function, nothing else.
grant execute on function public.blogger_checkin(text, text, text) to anon, authenticated;
grant execute on function public.norm_phone(text)                   to anon, authenticated;

-- ============================================================================
-- Diagnostic — should return true / true / true:
--   select
--     (select count(*) from pg_proc where proname='blogger_checkin')>0 as fn_exists,
--     (select relrowsecurity from pg_class where relname='blogger_allowlist') as allowlist_rls,
--     (select relrowsecurity from pg_class where relname='blogger_checkins')  as checkins_rls;
-- ============================================================================
