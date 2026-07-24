-- Prod baseline (seed data): real game_config values + starter sound catalog,
-- realtime publication, storage buckets. Captured from production 2026-07-24.
-- The flat keys from 002 (energy_max, energy_costs, …) are NOT what production
-- uses — prod configures per-action objects read by the RPCs; 002's keys are
-- removed here.

do $$ begin
begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end;
end $$;

insert into storage.buckets (id, name, public) values
  ('song-audio', 'song-audio', true),
  ('producer-sounds', 'producer-sounds', true)
on conflict (id) do nothing;

delete from public.game_config where key in ('energy_max','energy_regen_seconds','xp_per_level','energy_costs','xp_daily_caps');
insert into public.game_config (key, value) values
  ('artist_boost',        '{"daily_cap_energy": 25, "energy_per_endorsement": 5}'),
  ('claim_sound',         '{"early_claim_slots": 5, "early_claim_bonus_xp": 20, "early_claim_threshold": 10, "producer_daily_xp_cap": 60, "producer_xp_per_claim": 3, "producer_milestone_bonus_xp": 50, "trending_min_claims_per_week": 5}'),
  ('early_ear_threshold', '{"bonus_xp": 25, "min_ratings": 10, "min_avg_stars": 4, "min_endorsements": 5}'),
  ('publish_song',        '{"xp": 25, "energy_cost": 40, "daily_cap_l1_5": 1, "daily_cap_l6_15": 2, "daily_cap_l16_30": 3, "daily_cap_l31_plus": 5}'),
  ('publish_sound',       '{"xp": 12, "energy_cost": 15, "daily_cap_l1_5": 3, "daily_cap_l6_15": 5, "daily_cap_l16_30": 8, "daily_cap_l31_plus": 12}'),
  ('publish_template',    '{"xp": 20, "energy_cost": 25, "daily_cap_l1_5": 1, "daily_cap_l6_15": 2, "daily_cap_l16_30": 3, "daily_cap_l31_plus": 5, "usage_xp_per_publish": 5}')
on conflict (key) do update set value = excluded.value, updated_at = now();

insert into public.sound_catalog (id, kind, variant, display_name, glyph, audio_url, bpm, key_root, category) values
  ('b-long','808','long','woooooom','🌌',null,null,null,'starter'),
  ('b-move','808','move','wub-wub','🌊',null,null,null,'starter'),
  ('b-root','808','root','wooom','🛸',null,null,null,'starter'),
  ('h-eighths','hat','eighths','tss-tss','✨',null,null,null,'starter'),
  ('h-sixteenths','hat','sixteenths','ttttt','🧨',null,null,null,'starter'),
  ('h-skip','hat','skip','skrrr','💨',null,null,null,'starter'),
  ('h-trills','hat','trills','trrrr','🌀',null,null,null,'starter'),
  ('k-boom','kick','boom','boom','💥',null,null,null,'starter'),
  ('k-bounce','kick','bounce','bounce','🦘',null,null,null,'starter'),
  ('k-halftime','kick','halftime','thhump','🫀',null,null,null,'starter'),
  ('k-trap','kick','trap','doof','🪩',null,null,null,'starter'),
  ('m-bell','melody','bell','bells','🔔',null,null,null,'starter'),
  ('m-flute','melody','flute','flute','🎶',null,null,null,'starter'),
  ('m-pluck','melody','pluck','pluck','🪕',null,null,null,'starter'),
  ('r-808-144-Em','808','move','hound','🐺','/sounds/808/808_144_Em.wav',144,'Em','starter'),
  ('r-808-144-Fm','808','long','werk','💜','/sounds/808/808_144_Fm.wav',144,'Fm','starter'),
  ('r-808-150-Dsm','808','root','jump','🛸','/sounds/808/808_150_Dsm.wav',150,'D#m','starter'),
  ('r-bells-Fm','sample','soul-chop','paradise','☁️','/sounds/samples/bells_100_Fm.wav',100,'Fm','starter'),
  ('r-drums-150','drums','boom','vanessa','🥁','/sounds/drums/drums_150.wav',150,null,'starter'),
  ('r-drums-160','drums','trap','magic','✨','/sounds/drums/drums_160.wav',160,null,'starter'),
  ('r-drums-165-Fm','drums','halftime','told u so','🔥','/sounds/drums/drums_165_Fm.wav',165,'Fm','starter'),
  ('r-hat-128','hat','skip','segway','🛴','/sounds/hihat/hat_128.wav',128,null,'starter'),
  ('r-hat-150','hat','eighths','organic','🌿','/sounds/hihat/hat_150.wav',150,null,'starter'),
  ('r-hat-160','hat','sixteenths','monitor','📡','/sounds/hihat/hat_160.wav',160,null,'starter'),
  ('r-melodic-Gm','sample','dreamy','melodic','🎹','/sounds/samples/melodic_140_Gm.wav',140,'Gm','starter'),
  ('r-sample-Bm','sample','dark-keys','without','🖤','/sounds/samples/sample_85_Bm.wav',85,'Bm','starter'),
  ('r-vinyl-Em','sample','neon','vinyl cut','🎙️','/sounds/samples/vinyl_90_Em.wav',90,'Em','starter'),
  ('s-clap','snare','clap','clap','👏',null,null,null,'starter'),
  ('s-halftime','snare','halftime','kraaa','🔊',null,null,null,'starter'),
  ('s-rim','snare','rim','tik','🥢',null,null,null,'starter'),
  ('sam-dark','sample','dark-keys','dark keys','🖤',null,null,null,'starter'),
  ('sam-dream','sample','dreamy','dream pad','☁️',null,null,null,'starter'),
  ('sam-neon','sample','neon','neon stab','🟣',null,null,null,'starter'),
  ('sam-soul','sample','soul-chop','soul loop','🎷',null,null,null,'starter')
on conflict (id) do nothing;

-- Backfill starter sounds for users created before trg_grant_starter_sounds
insert into public.user_sounds (user_id, sound_id, source)
select u.id, c.id, 'starter'
from auth.users u cross join public.sound_catalog c
where c.category = 'starter'
on conflict (user_id, sound_id) do nothing;
