# Tables & views — live schema catalog

Source of truth for shapes: [`supabase.types.ts`](./supabase.types.ts)
(generated from the live `grvd-daw` project). This file is the narrative map.

## Core loop

| Table | Purpose | RLS (from 001 + dashboard) |
|---|---|---|
| `profiles` | Extends `auth.users`: username, emoji avatar. Auto-created by `handle_new_user` trigger on signup. | own read/update |
| `songs` | Saved songs: bpm, bars, key_root, template_id, `layers` jsonb, tags, collaborators, `vocal_blob_url`, `pitch_score`, `published_publication_id`. `created_at` is **epoch ms bigint** (JS `Date.now()`), not timestamptz. | owner all, public read |
| `tamagotchi_state` | Companion: `needs` jsonb (social/creativity/energy), mood, streaks, songs finished/abandoned. `last_seen_at` epoch ms. | owner only |
| `user_stats` | Gamification: `total_xp`, `level`, `energy` + `energy_updated_at` (server-side regen anchor), achievements, streaks, vocal_count. | owner only |
| `game_config` | key → jsonb economy constants. Written only via `admin_set_game_config`. Both clients load on boot. | public read |

## Tastemaker economy

| Table | Purpose |
|---|---|
| `song_publications` | Published drops (denormalized artist name/avatar, audio_url, waveform_url, collaborators, `retired_at`) |
| `song_ratings` | 1–5 stars per user per song |
| `song_endorsements` | Costed endorsements (15⚡) |
| `song_bonus_events` | Threshold-crossing bonuses (e.g. early-ear) |
| `sound_catalog` | Producer-published sounds (kind, category, glyph, audio_url, producer_id) |
| `user_sounds` | Sound ownership (user × sound, acquisition source) |
| `sound_acquisitions` | Acquisition event log |
| `sound_bonus_events` | Sound threshold bonuses |
| `template_publications` | Producer-published templates (recipe, sound_ids, sounds jsonb, usage_count) |
| `player_events` | Append-only XP/energy ledger (event_type, xp_delta, energy_delta, target_id) |

## Social

| Table | Purpose |
|---|---|
| `friend_relationships` | Ordered-pair (user_a < user_b) friendship with status + requested_by + blocked_by |
| `fan_relationships` | fan → artist follows |
| `crib_visits` | Visit log (host, visitor) |
| `notifications` | Per-user notification feed (kind, payload jsonb, seen_at) |
| `coop_sessions` | Live co-production rooms: join_code, host/guest, invited_user_id, `state` jsonb (shared DAW state), `available_sound_ids`. Realtime-enabled. |

## Views (read models)

| View | Feeds |
|---|---|
| `song_publication_stats` | Booth: publication + avg stars + counts |
| `weekly_song_score` | Song leaderboard (weekly window) |
| `weekly_artist_score` | Artist leaderboard |
| `weekly_tastemaker_score` | Tastemaker (rater) leaderboard |
| `my_friends` | Current user's friendships, flattened |

## Storage buckets (web)

- Vocal takes and published song audio should live in Supabase Storage
  (`vocal_blob_url` currently holds browser blob URLs on some rows — known
  web-side bug; UE cannot read those. Fix tracked as part of P0.)
