-- game_config seed — canonical economy constants.
-- The table + admin_set_game_config RPC already exist in the live DB.
-- Values mirror src/store/useStore.ts in grvd-daw (the playtested numbers);
-- once seeded, clients read these instead of trusting hardcoded copies.
-- Idempotent: safe to re-run.

insert into public.game_config (key, value) values
  ('energy_max',             '100'),
  ('energy_regen_seconds',   '300'),                -- 1 unit / 5 min
  ('xp_per_level',           '300'),
  ('energy_costs',           '{"endorse": 15, "publishSong": 40, "publishSound": 15, "publishTemplate": 40, "visitCrib": 3, "inviteToCrib": 5}'),
  ('xp_daily_caps',          '{"rate": 40, "listen": 30}')  -- 2XP×20 ratings, 1XP×30 listens
on conflict (key) do update
  set value = excluded.value, updated_at = now();
