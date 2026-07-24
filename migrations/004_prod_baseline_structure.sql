-- Prod baseline sync (structure) — mirrors grvd-daw production schema.
-- Captured from live project kpchlhxfsvonspyiikqs on 2026-07-24 and applied
-- to grvd-staging (erqiyxakfdoemeskpygy). Verified: function fingerprint,
-- table/view/policy counts identical between prod and staging afterwards.
-- Idempotent over a 001+002 base (guards skip what already exists).

create sequence if not exists public.crib_visits_id_seq;
create sequence if not exists public.notifications_id_seq;
create sequence if not exists public.player_events_id_seq;
create sequence if not exists public.sound_acquisitions_id_seq;

create table if not exists public.crib_visits (
  id bigint not null default nextval('crib_visits_id_seq'::regclass),
  visitor_id uuid not null,
  host_id uuid not null,
  visited_at timestamp with time zone not null default now()
);

create table if not exists public.fan_relationships (
  fan_id uuid not null,
  artist_id uuid not null,
  became_fan_at timestamp with time zone not null default now()
);

create table if not exists public.friend_relationships (
  user_a_id uuid not null,
  user_b_id uuid not null,
  status text not null,
  requested_by uuid not null,
  requested_at timestamp with time zone not null default now(),
  accepted_at timestamp with time zone,
  blocked_by uuid
);

create table if not exists public.notifications (
  id bigint not null default nextval('notifications_id_seq'::regclass),
  user_id uuid not null,
  kind text not null,
  payload jsonb not null default '{}'::jsonb,
  seen_at timestamp with time zone,
  created_at timestamp with time zone not null default now()
);

create table if not exists public.player_events (
  id bigint not null default nextval('player_events_id_seq'::regclass),
  user_id uuid not null,
  event_type text not null,
  energy_delta integer not null default 0,
  xp_delta integer not null default 0,
  target_id text,
  created_at timestamp with time zone not null default now()
);

create table if not exists public.song_bonus_events (
  song_id uuid not null,
  bonus_type text not null,
  crossed_at timestamp with time zone not null default now()
);

create table if not exists public.song_endorsements (
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  song_id uuid not null,
  created_at timestamp with time zone not null default now()
);

create table if not exists public.song_publications (
  id uuid not null default gen_random_uuid(),
  artist_id uuid not null,
  title text not null,
  artist_name text not null,
  audio_url text,
  waveform_url text,
  bpm integer,
  key_root text,
  duration_sec integer,
  published_at timestamp with time zone not null default now(),
  retired_at timestamp with time zone,
  artist_avatar text not null default '🎧'::text,
  collaborator_ids uuid[] not null default '{}'::uuid[],
  collaborator_names text[] not null default '{}'::text[]
);

create table if not exists public.song_ratings (
  user_id uuid not null,
  song_id uuid not null,
  stars smallint not null,
  created_at timestamp with time zone not null default now()
);

create table if not exists public.sound_acquisitions (
  id bigint not null default nextval('sound_acquisitions_id_seq'::regclass),
  user_id uuid not null,
  sound_id text not null,
  source text not null,
  created_at timestamp with time zone not null default now()
);

create table if not exists public.sound_bonus_events (
  sound_id text not null,
  bonus_type text not null,
  crossed_at timestamp with time zone not null default now()
);

create table if not exists public.sound_catalog (
  id text not null,
  kind text not null,
  variant text,
  display_name text not null,
  glyph text not null default '🎵'::text,
  audio_url text,
  bpm integer,
  key_root text,
  category text not null default 'starter'::text,
  producer_id uuid,
  created_at timestamp with time zone not null default now()
);

create table if not exists public.template_publications (
  id uuid not null default gen_random_uuid(),
  producer_id uuid not null,
  name text not null,
  sounds jsonb not null default '[]'::jsonb,
  published_at timestamp with time zone not null default now(),
  bpm integer not null default 140,
  key_root text not null default 'C'::text,
  bars integer not null default 4,
  recipe text[] not null default '{}'::text[],
  sound_ids text[] not null default '{}'::text[],
  tags text[] not null default '{}'::text[],
  subtitle text,
  usage_count integer not null default 0,
  retired_at timestamp with time zone
);

create table if not exists public.user_sounds (
  user_id uuid not null,
  sound_id text not null,
  acquired_at timestamp with time zone not null default now(),
  source text not null default 'starter'::text
);

-- Columns added to 001-era tables since
alter table public.songs add column if not exists published_publication_id uuid;
alter table public.coop_sessions add column if not exists invited_user_id uuid;
alter table public.coop_sessions add column if not exists invited_at timestamp with time zone not null default now();
alter table public.coop_sessions add column if not exists accepted_at timestamp with time zone;
alter table public.coop_sessions add column if not exists available_sound_ids text[] not null default '{}'::text[];
alter table public.coop_sessions alter column status set default 'pending'::text;

-- Constraints (guarded — some already exist from 001).
-- Primary keys and uniques FIRST, then FKs that reference them.
do $$ begin
begin alter table public.crib_visits add constraint crib_visits_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.fan_relationships add constraint fan_relationships_pkey PRIMARY KEY (fan_id, artist_id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.friend_relationships add constraint friend_relationships_pkey PRIMARY KEY (user_a_id, user_b_id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.notifications add constraint notifications_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.player_events add constraint player_events_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.song_bonus_events add constraint song_bonus_events_pkey PRIMARY KEY (song_id, bonus_type); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.song_endorsements add constraint song_endorsements_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.song_publications add constraint song_publications_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.song_ratings add constraint song_ratings_pkey PRIMARY KEY (user_id, song_id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.sound_acquisitions add constraint sound_acquisitions_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.sound_bonus_events add constraint sound_bonus_events_pkey PRIMARY KEY (sound_id, bonus_type); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.sound_catalog add constraint sound_catalog_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.template_publications add constraint template_publications_pkey PRIMARY KEY (id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.user_sounds add constraint user_sounds_pkey PRIMARY KEY (user_id, sound_id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.song_endorsements add constraint song_endorsements_user_id_song_id_key UNIQUE (user_id, song_id); exception when duplicate_object or duplicate_table then null; end;
begin alter table public.song_endorsements add constraint song_endorsements_user_song_unique UNIQUE (user_id, song_id); exception when duplicate_object or duplicate_table then null; end;

begin alter table public.coop_sessions add constraint coop_sessions_invited_user_id_fkey FOREIGN KEY (invited_user_id) REFERENCES auth.users(id) ON DELETE SET NULL; exception when duplicate_object then null; end;
begin alter table public.coop_sessions add constraint coop_sessions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'abandoned'::text]))); exception when duplicate_object then null; end;
begin alter table public.crib_visits add constraint crib_visits_host_id_fkey FOREIGN KEY (host_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.crib_visits add constraint crib_visits_visitor_id_fkey FOREIGN KEY (visitor_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.fan_relationships add constraint fan_relationships_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.fan_relationships add constraint fan_relationships_fan_id_fkey FOREIGN KEY (fan_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.friend_relationships add constraint friend_pair_ordered CHECK ((user_a_id < user_b_id)); exception when duplicate_object then null; end;
begin alter table public.friend_relationships add constraint friend_relationships_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'blocked'::text]))); exception when duplicate_object then null; end;
begin alter table public.friend_relationships add constraint friend_relationships_blocked_by_fkey FOREIGN KEY (blocked_by) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.friend_relationships add constraint friend_relationships_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.friend_relationships add constraint friend_relationships_user_a_id_fkey FOREIGN KEY (user_a_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.friend_relationships add constraint friend_relationships_user_b_id_fkey FOREIGN KEY (user_b_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.notifications add constraint notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.player_events add constraint player_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.song_endorsements add constraint song_endorsements_song_id_fkey FOREIGN KEY (song_id) REFERENCES song_publications(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.song_endorsements add constraint song_endorsements_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.song_publications add constraint song_publications_artist_id_fkey FOREIGN KEY (artist_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.song_ratings add constraint song_ratings_song_id_fkey FOREIGN KEY (song_id) REFERENCES song_publications(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.song_ratings add constraint song_ratings_stars_check CHECK (((stars >= 1) AND (stars <= 5))); exception when duplicate_object then null; end;
begin alter table public.song_ratings add constraint song_ratings_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.sound_acquisitions add constraint sound_acquisitions_sound_id_fkey FOREIGN KEY (sound_id) REFERENCES sound_catalog(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.sound_acquisitions add constraint sound_acquisitions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.sound_bonus_events add constraint sound_bonus_events_sound_id_fkey FOREIGN KEY (sound_id) REFERENCES sound_catalog(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.sound_catalog add constraint sound_catalog_producer_id_fkey FOREIGN KEY (producer_id) REFERENCES auth.users(id) ON DELETE SET NULL; exception when duplicate_object then null; end;
begin alter table public.template_publications add constraint template_publications_producer_id_fkey FOREIGN KEY (producer_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.user_sounds add constraint user_sounds_sound_id_fkey FOREIGN KEY (sound_id) REFERENCES sound_catalog(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
begin alter table public.user_sounds add constraint user_sounds_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE; exception when duplicate_object then null; end;
end $$;

-- Indexes
create unique index if not exists coop_sessions_join_code_key ON public.coop_sessions USING btree (join_code);
create index if not exists notifications_user_recent_idx ON public.notifications USING btree (user_id, created_at DESC);
create index if not exists notifications_user_unseen_idx ON public.notifications USING btree (user_id, created_at DESC) WHERE (seen_at IS NULL);
create index if not exists player_events_user_created_idx ON public.player_events USING btree (user_id, created_at DESC);
create index if not exists player_events_user_type_day_idx ON public.player_events USING btree (user_id, event_type, created_at DESC);
create unique index if not exists profiles_username_lower_unique ON public.profiles USING btree (lower(username)) WHERE ((username IS NOT NULL) AND (username <> ''::text));
create index if not exists song_endorsements_song_id_idx ON public.song_endorsements USING btree (song_id);
create index if not exists song_publications_published_at_idx ON public.song_publications USING btree (published_at DESC) WHERE (retired_at IS NULL);
create index if not exists song_ratings_song_id_idx ON public.song_ratings USING btree (song_id);
create index if not exists songs_published_publication_id_idx ON public.songs USING btree (published_publication_id);
create index if not exists sound_acquisitions_sound_id_idx ON public.sound_acquisitions USING btree (sound_id, created_at DESC);
create index if not exists sound_acquisitions_user_id_idx ON public.sound_acquisitions USING btree (user_id, created_at DESC);
create index if not exists sound_catalog_category_recent_idx ON public.sound_catalog USING btree (category, created_at DESC);
create index if not exists sound_catalog_kind_idx ON public.sound_catalog USING btree (kind);
create index if not exists sound_catalog_producer_idx ON public.sound_catalog USING btree (producer_id, created_at DESC) WHERE (producer_id IS NOT NULL);
create index if not exists template_publications_producer_idx ON public.template_publications USING btree (producer_id, published_at DESC);
create index if not exists template_publications_usage_idx ON public.template_publications USING btree (usage_count DESC, published_at DESC) WHERE (retired_at IS NULL);
create index if not exists user_sounds_user_recent_idx ON public.user_sounds USING btree (user_id, acquired_at DESC);

-- RLS on
alter table public.crib_visits enable row level security;
alter table public.fan_relationships enable row level security;
alter table public.friend_relationships enable row level security;
alter table public.notifications enable row level security;
alter table public.player_events enable row level security;
alter table public.song_bonus_events enable row level security;
alter table public.song_endorsements enable row level security;
alter table public.song_publications enable row level security;
alter table public.song_ratings enable row level security;
alter table public.sound_acquisitions enable row level security;
alter table public.sound_bonus_events enable row level security;
alter table public.sound_catalog enable row level security;
alter table public.template_publications enable row level security;
alter table public.user_sounds enable row level security;
