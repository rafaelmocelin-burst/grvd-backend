-- SUPERSEDED 2026-07-24 by 004-007 (real prod baseline). Kept for staging migration history.
-- PROVISIONAL — staging-only bootstrap so UE P1 can log real server data.
-- Production's get_live_energy body will replace this once the prod restore
-- finishes and the schema is dumped here as the real baseline. Semantics
-- mirror the web client's computeLiveEnergy: base + floor(elapsed/regen),
-- clamped to max. DO NOT apply to production.

alter table public.user_stats
  add column if not exists energy integer not null default 100,
  add column if not exists energy_updated_at timestamptz not null default now(),
  add column if not exists level integer not null default 1;

create or replace function public.get_live_energy(
  p_energy_max integer default 100,
  p_regen_interval_seconds integer default 300
)
returns table (
  base_energy integer,
  live_energy integer,
  level integer,
  total_xp integer,
  energy_updated_at timestamptz
)
language plpgsql security definer
set search_path = public
as $$
declare
  v_stats public.user_stats%rowtype;
begin
  insert into public.user_stats (user_id)
  values (auth.uid())
  on conflict (user_id) do nothing;

  select * into v_stats from public.user_stats where user_id = auth.uid();

  return query select
    v_stats.energy,
    least(
      p_energy_max,
      v_stats.energy + floor(extract(epoch from (now() - v_stats.energy_updated_at)) / p_regen_interval_seconds)::integer
    ),
    v_stats.level,
    v_stats.total_xp,
    v_stats.energy_updated_at;
end;
$$;

