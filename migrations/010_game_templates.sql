-- Built-in song templates.
--
-- These lived only in the web client (src/data/templates.ts), so the UE client
-- had no way to see them and the two clients could not have offered the same
-- starting points. Distinct from template_publications, which holds
-- player-authored templates and requires a producer_id.
--
-- Applied to grvd-staging 2026-07-27. Verified: all 6 rows readable
-- anonymously via PostgREST. NOT yet applied to production — the web client
-- still reads its own hardcoded copy and would need to switch over first.

create table if not exists public.game_templates (
  id          text primary key,
  name        text not null,
  subtitle    text,
  bpm         integer not null,
  bars        integer not null,
  key_root    text not null,
  tags        text[] not null default '{}',
  recipe      text[] not null,               -- ordered layer kinds the DAW asks for
  hook_line   text,
  verse       text[] not null default '{}',
  suggested   jsonb  not null default '{}',  -- kind -> [sound_id]
  sort_order  integer not null default 0,
  retired_at  timestamptz
);

alter table public.game_templates enable row level security;

do $$ begin
begin
  create policy "game_templates: public read" on public.game_templates
    for select to public using (retired_at is null);
exception when duplicate_object then null; end;
end $$;

insert into public.game_templates
  (id, name, subtitle, bpm, bars, key_root, tags, recipe, hook_line, verse, suggested, sort_order)
values
  ('tpl-grvd-real', 'GRVD Test', 'Real samples — your actual sounds', 150, 4, 'D#',
   array['trap','rap'], array['drums','hat','808','sample','vocal'],
   'I put that on everything, I been working',
   array[
     'I put that on everything, I been working every night',
     'Stack the sounds, lock the 808, everything just right',
     'No days off in the booth, grinding for the light',
     'GRVD life we building, gonna take it to new heights',
     'Drums hit hard, melody smooth, recipe on lock',
     'Every layer that I add make the whole thing rock',
     'From the basement to the penthouse, never gonna stop',
     'GRVD certified, yeah we certified at the top'],
   '{"drums":["r-drums-150","r-drums-160","r-drums-165-Fm"],"hat":["r-hat-150","r-hat-160","r-hat-128"],"808":["r-808-150-Dsm","r-808-144-Em","r-808-144-Fm"],"sample":["r-melodic-Gm","r-bells-Fm","r-vinyl-Em","r-sample-Bm"]}',
   0),

  ('tpl-trap-hook', 'Trap Hook', 'Central Cee / Ice Spice energy', 142, 4, 'A',
   array['trap','pop-rap'], array['kick','hat','808','sample','melody','vocal'],
   'I been ridin'' round, I been gettin'' it', array[]::text[],
   '{"kick":["k-trap","k-halftime"],"hat":["r-hat-160","r-hat-150"],"808":["r-808-144-Em","r-808-150-Dsm"],"sample":["r-bells-Fm","r-sample-Bm"],"melody":["m-bell","m-flute"]}',
   1),

  ('tpl-boom-bap', 'Boom-Bap Hook', 'Classic head-nod, chopped soul', 90, 4, 'D',
   array['boom-bap','rap'], array['kick','snare','hat','sample','vocal'],
   'Every day I''m on my grind, watch me work', array[]::text[],
   '{"kick":["k-boom"],"snare":["s-clap","s-rim"],"hat":["r-hat-150"],"sample":["r-vinyl-Em"]}',
   2),

  ('tpl-drill', 'Drill Hook', 'Half-time, dark, menacing', 148, 4, 'F',
   array['drill'], array['kick','snare','hat','808','sample','vocal'],
   'In the city with my team, we don''t play', array[]::text[],
   '{"kick":["k-halftime","k-trap"],"snare":["s-halftime"],"hat":["r-hat-160"],"808":["r-808-144-Fm","r-808-144-Em"],"sample":["r-sample-Bm"]}',
   3),

  ('tpl-pop-rap', 'Pop-Rap Hook', 'Bright, bouncy, TikTok-ready', 110, 4, 'C',
   array['pop-rap'], array['kick','snare','hat','sample','melody','vocal'],
   'Light it up, light it up, baby feel the beat', array[]::text[],
   '{"kick":["k-bounce","k-trap"],"snare":["s-clap"],"hat":["r-hat-128","r-hat-150"],"sample":["r-bells-Fm","r-melodic-Gm"],"melody":["m-bell","m-pluck"]}',
   4),

  ('tpl-punchline', 'Punchline', 'Hook + 1 vocal — under a minute', 100, 2, 'E',
   array['rap'], array['kick','hat','sample','vocal'],
   'They sleepin'', they sleepin'', wake up, wake up', array[]::text[],
   '{"kick":["k-boom","k-trap"],"hat":["r-hat-150","r-hat-160"],"sample":["r-vinyl-Em","r-sample-Bm"]}',
   5)
on conflict (id) do update set
  name = excluded.name, subtitle = excluded.subtitle, bpm = excluded.bpm,
  bars = excluded.bars, key_root = excluded.key_root, tags = excluded.tags,
  recipe = excluded.recipe, hook_line = excluded.hook_line, verse = excluded.verse,
  suggested = excluded.suggested, sort_order = excluded.sort_order;
