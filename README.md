# grvd-backend

**The shared backend contract for GRVD.** Both clients — the web DAW
([grvd-daw](https://github.com/rafael-mocelin/grvd-daw), React/Tone.js) and the
Unreal Engine game ([BurstWorldGame](https://github.com/Burst-Live/BurstWorldGame)) —
are views over the same Supabase backend. This repo is the single source of
truth for that backend: schema, RPCs, RLS policies, and the `game_config`
economy constants.

**Rule: only migrations in this repo ever touch the database.** Neither client
repo applies schema changes directly. This is what keeps a web client and a UE
client from drifting apart.

## Live projects

| Project | Ref | Role |
|---|---|---|
| `grvd-daw` | `kpchlhxfsvonspyiikqs` | Production (web testers write here) |
| `grvd-staging` | `erqiyxakfdoemeskpygy` | UE development target — migrations 001–003 applied 2026-07-24 (003 is a provisional get_live_energy pending the prod dump) |

> Note: the UE game currently points at a separate, older Supabase project
> (`ihdrcftcmtyvaaabehbe`, not in the Burst org) with its own ad-hoc schema
> (drum presets / samples / recordings / cloud saves). Part of the UE5
> migration is retiring that in favor of this contract.

## Layout

```
migrations/   Ordered SQL migrations. 001–002 are the original web-app schema;
              004–008 are the FULL production baseline captured 2026-07-24
              (20 tables, 5 views, 34 function bodies, 36 policies, triggers,
              buckets, seed data) and applied to grvd-staging. Verified:
              staging's function fingerprint is byte-identical to production
              (md5 38849179d2f98780aae2d486ff78391f). 003 is superseded.
contract/     The wire contract as consumed by clients:
              - supabase.types.ts — generated types from the LIVE database
                (supabase gen types). Complete: 18 tables, 5 views, ~30 RPC
                signatures. This is the machine-readable contract; UE's
                GrvdTypes.h USTRUCTs must mirror these shapes.
              - TABLES.md / RPCS.md — human-readable catalog.
config/       game_config seed (economy constants both clients load on boot).
scripts/      How to capture the live schema as the real migration baseline.
```

## Consuming the contract

- **Web (grvd-daw):** already imports these exact types (`src/lib/supabase.types.ts`).
  When the schema changes, regenerate types here and copy/submodule into the web repo.
- **UE (BurstWorldGame):** hand-mirror the `Row` shapes into `USTRUCT`s and RPC
  argument/return structs. The types file is the reference; keep a comment in
  each USTRUCT naming the table/RPC it mirrors.

## Economy constants (`game_config`)

The `game_config` table (key → jsonb value) already exists in the live DB with
the `admin_set_game_config` RPC guarding writes. `config/game_config.seed.sql`
seeds the canonical values (energy max/regen, energy costs, XP caps,
XP-per-level). Clients read the table on boot instead of hardcoding — the
hardcoded copies in the web client are advisory (optimistic UI) only.
