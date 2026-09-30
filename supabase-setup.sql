-- PRECIO JUSTO · base compartida de precios reales
-- Ejecuta este archivo en Supabase > SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.real_prices (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  service_id text not null check (char_length(service_id) between 1 and 80),
  service_name text not null check (char_length(service_name) between 1 and 180),
  city text not null check (char_length(city) between 1 and 60),
  place text check (place is null or char_length(place) <= 80),
  price numeric(12,2) not null check (price >= 0.50 and price <= 1000000),
  paid_month date,
  details text check (details is null or char_length(details) <= 500),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  quality_flag text not null default 'normal' check (quality_flag in ('normal','outlier')),
  client_hash text not null check (char_length(client_hash) between 32 and 128),
  submission_hash text not null check (char_length(submission_hash) between 32 and 128),
  reference_min numeric(12,2) check (reference_min is null or reference_min >= 0),
  reference_max numeric(12,2) check (reference_max is null or reference_max >= 0),
  moderation_reason text check (moderation_reason is null or char_length(moderation_reason) <= 300)
);

create unique index if not exists real_prices_submission_hash_uidx
  on public.real_prices (submission_hash);

create index if not exists real_prices_public_lookup_idx
  on public.real_prices (status, service_id, city, created_at desc);

create index if not exists real_prices_client_rate_idx
  on public.real_prices (client_hash, created_at desc);

-- Anti-spam adicional en la propia base de datos: máximo 5 envíos por hora
-- para el mismo identificador de dispositivo. No sustituye una protección
-- avanzada de servidor, pero evita spam accidental y básico en este MVP.
create or replace function public.enforce_real_price_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (
    select count(*)
    from public.real_prices
    where client_hash = new.client_hash
      and created_at > now() - interval '1 hour'
  ) >= 5 then
    raise exception 'rate_limited';
  end if;
  return new;
end;
$$;

drop trigger if exists real_prices_rate_limit_trigger on public.real_prices;
create trigger real_prices_rate_limit_trigger
before insert on public.real_prices
for each row execute function public.enforce_real_price_rate_limit();

-- Seguridad: la web pública solo puede LEER aprobados e INSERTAR pendientes.
alter table public.real_prices enable row level security;

revoke all on table public.real_prices from anon, authenticated;
grant select, insert on table public.real_prices to anon, authenticated;

drop policy if exists "public can read approved prices" on public.real_prices;
create policy "public can read approved prices"
on public.real_prices
for select
to anon, authenticated
using (status = 'approved');

drop policy if exists "public can submit pending prices" on public.real_prices;
create policy "public can submit pending prices"
on public.real_prices
for insert
to anon, authenticated
with check (
  status = 'pending'
  and price >= 0.50
  and price <= 1000000
  and quality_flag in ('normal','outlier')
  and char_length(service_id) between 1 and 80
  and char_length(service_name) between 1 and 180
  and char_length(city) between 1 and 60
  and (details is null or char_length(details) <= 500)
  and (place is null or char_length(place) <= 80)
);

-- IMPORTANTE:
-- No se concede UPDATE ni DELETE a la web pública.
-- Aprueba/rechaza desde Supabase Table Editor o desde SQL Editor.
--
-- Ver pendientes:
-- select id, created_at, service_name, city, price, paid_month,
--        quality_flag, reference_min, reference_max, details
-- from public.real_prices
-- where status = 'pending'
-- order by created_at desc;
--
-- Aprobar uno:
-- update public.real_prices set status='approved' where id='PEGA_AQUI_EL_UUID';
--
-- Rechazar uno:
-- update public.real_prices
-- set status='rejected', moderation_reason='Duplicado o dato no verificable'
-- where id='PEGA_AQUI_EL_UUID';
