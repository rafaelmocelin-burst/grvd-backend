-- game_config: key → jsonb economy constants both clients load on boot.
-- Applied to grvd-staging 2026-07-24. Production already has this table;
-- values seeded from config/game_config.seed.sql.

create table if not exists public.game_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.game_config enable row level security;
create policy "config: public read" on public.game_config for select using (true);

insert into public.game_config (key, value) values
  ('energy_max',           '100'),
  ('energy_regen_seconds', '300'),
  ('xp_per_level',         '300'),
  ('energy_costs',         '{"endorse": 15, "publishSong": 40, "publishSound": 15, "publishTemplate": 40, "visitCrib": 3, "inviteToCrib": 5}'),
  ('xp_daily_caps',        '{"rate": 40, "listen": 30}')
on conflict (key) do update
  set value = excluded.value, updated_at = now();
