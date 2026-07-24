# Capturing the live schema as the migration baseline

The live `grvd-daw` project (`kpchlhxfsvonspyiikqs`) contains ~30 RPC bodies,
RLS policies, views, and triggers that were applied via the dashboard and never
committed. Until they're captured here, `migrations/001` is incomplete history.

Prerequisites: the project must be **restored** (it auto-pauses on the free
tier) and you need the database password (Dashboard → Settings → Database).

```bash
# 1. Login + link (from the repo root)
npx supabase login
npx supabase link --project-ref kpchlhxfsvonspyiikqs

# 2. Dump schema only (tables, views, functions, policies, triggers, grants)
npx supabase db dump -f migrations/002_live_baseline.sql

# 3. Also capture realtime publication + storage buckets if needed
npx supabase db dump -f migrations/003_storage_and_realtime.sql --schema storage
```

Then regenerate the types so `contract/supabase.types.ts` and the dump can
never disagree:

```bash
npx supabase gen types typescript --project-id kpchlhxfsvonspyiikqs > contract/supabase.types.ts
```

After the baseline lands, every future schema change is a new numbered file in
`migrations/` applied via `npx supabase db push` (or the MCP `apply_migration`),
and the same file is applied to the staging project used by UE development.
