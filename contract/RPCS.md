# RPC catalog

All game rules run server-side in these Postgres functions (called via
PostgREST `/rest/v1/rpc/<name>` with the user's JWT). Exact arg/return shapes:
[`supabase.types.ts`](./supabase.types.ts) → `Database.public.Functions`.
Bodies live in the database; capturing them into `migrations/` is pending a
live dump (see `scripts/`).

## Economy core

| RPC | Does | Notes |
|---|---|---|
| `get_live_energy(p_energy_max?, p_regen_interval_seconds?)` | Returns base + regenerated energy, xp, level | Call on boot/focus |
| `spend_energy(p_cost, p_event_type, p_xp?, p_target_id?, …)` | Atomic spend-or-reject + XP + `player_events` row | The gate for all paid actions |
| `earn_xp_capped(p_xp, p_daily_xp_cap, p_event_type, p_target_id?)` | XP with per-event-type daily cap | rate=2XP cap 40, listen=1XP cap 30 |
| `admin_set_game_config(p_key, p_value)` | Guarded `game_config` write | Admin-only, raises otherwise |

## Publishing

| RPC | Cost |
|---|---|
| `publish_song(p_song_id, p_audio_url, p_collaborator_ids?)` | 40⚡, daily cap |
| `publish_sound(p_display_name, p_kind, p_audio_url, p_glyph, …)` | 15⚡, daily cap |
| `publish_template(p_name, p_bpm, p_key_root, p_bars, p_recipe, p_sound_ids, …)` | 40⚡, daily cap |

## Tastemaker actions

| RPC | Does |
|---|---|
| `rate_song(p_song_id, p_stars)` | Upsert star rating, capped XP |
| `endorse_song(p_song_id)` | 15⚡ endorsement, daily cap |
| `claim_sound(p_sound_id)` | Acquire a catalog sound |
| `sound_claim_counts(p_sound_ids?)` | Claim counts (total + weekly) |
| `award_early_ear_bonus_if_needed(p_current_user, p_song_id)` | Early-supporter bonus on threshold cross |
| `award_early_claim_bonus_if_needed(p_sound_id)` | Same for sounds |
| `weekly_producer_score()` | Producer leaderboard (function, not view) |

## Social

| RPC | Does |
|---|---|
| `send_friend_request(p_other_user_id)` / `respond_friend_request(p_other_user_id, p_accept)` / `remove_friend(p_other_user_id)` | Friendship lifecycle over ordered pairs (`_ordered_pair` helper) |
| `check_song_edit_lock(p_song_id, p_coop_session_id?)` | Can-edit gate: collaborators present, sounds owned |

## Coop

| RPC | Does |
|---|---|
| `create_coop_session(p_invite_user_id?)` | New room + join_code (`_coop_gen_code`) |
| `join_coop_by_code(p_code)` | Join as guest |
| `accept_coop_invite(p_session_id)` / `decline_coop_invite(p_session_id)` | Invite flow |
| `patch_coop_session_state(p_patch, p_session_id)` | Merge patch into shared `state` jsonb (drives Realtime) |
| `leave_coop_session(p_session_id)` | Leave/close |

## UE port notes

- Every RPC returns a **table** (array of one row) — UE code must index `[0]`.
- Auth: `Authorization: Bearer <user JWT>` + `apikey: <anon key>` headers;
  identical to what `BDatabaseManager` already does against the old project.
- `success/message` pattern: mutating RPCs return `success boolean` +
  `message text` instead of raising, so check the payload, not the HTTP status.
