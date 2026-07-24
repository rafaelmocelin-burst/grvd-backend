-- Prod baseline (all 34 public functions) — generated from grvd-staging
-- (byte-identical to production kpchlhxfsvonspyiikqs; md5 fingerprint
-- 38849179d2f98780aae2d486ff78391f verified 2026-07-24).
-- On a fresh 001+002 base, DROP the 003 provisional get_live_energy first:
drop function if exists public.get_live_energy(integer, integer);

CREATE OR REPLACE FUNCTION public._coop_compute_union(p_session_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_row record;
  v_union text[];
begin
  select host_id, guest_id into v_row
  from public.coop_sessions
  where id = p_session_id;

  if not found then return '{}'::text[]; end if;

  select coalesce(array_agg(distinct us.sound_id), '{}'::text[])
    into v_union
  from public.user_sounds us
  where us.user_id = v_row.host_id
     or (v_row.guest_id is not null and us.user_id = v_row.guest_id);

  return v_union;
end;
$function$
;

CREATE OR REPLACE FUNCTION public._coop_gen_code()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
declare
  v_code text;
  v_attempts int := 0;
begin
  loop
    v_code := upper(substring(encode(extensions.gen_random_bytes(6), 'hex') from 1 for 6));
    if not exists (select 1 from public.coop_sessions where join_code = v_code) then
      return v_code;
    end if;
    v_attempts := v_attempts + 1;
    if v_attempts > 20 then
      raise exception 'could not generate unique join code';
    end if;
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public._ordered_pair(p_x uuid, p_y uuid)
 RETURNS TABLE(user_a uuid, user_b uuid)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  select
    case when p_x < p_y then p_x else p_y end,
    case when p_x < p_y then p_y else p_x end;
$function$
;

CREATE OR REPLACE FUNCTION public.accept_coop_invite(p_session_id uuid)
 RETURNS TABLE(success boolean, message text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_row  record;
  v_union text[];
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text, null::text;
    return;
  end if;

  select * into v_row from public.coop_sessions where id = p_session_id;
  if not found then
    return query select false, 'Session not found'::text, null::text;
    return;
  end if;

  if v_row.invited_user_id is null or v_row.invited_user_id <> v_self then
    return query select false, 'No invite for you on this session'::text, v_row.status;
    return;
  end if;

  if v_row.status <> 'pending' then
    return query select false, format('Session is already %s', v_row.status)::text, v_row.status;
    return;
  end if;

  -- Stage the row activation, then compute the union with the now-known guest_id.
  update public.coop_sessions
     set guest_id    = v_self,
         status      = 'active',
         accepted_at = now(),
         updated_at  = now()
   where id = p_session_id;

  v_union := public._coop_compute_union(p_session_id);
  update public.coop_sessions
     set available_sound_ids = v_union,
         updated_at          = now()
   where id = p_session_id;

  return query select true, 'Joined'::text, 'active'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_set_game_config(p_key text, p_value jsonb)
 RETURNS TABLE(key text, value jsonb, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_role text;
begin
  -- Pull the caller's role from their JWT's app_metadata.
  v_role := coalesce(auth.jwt() -> 'app_metadata' ->> 'role', 'user');
  if v_role is distinct from 'admin' then
    raise exception 'Only admins can update game_config';
  end if;

  insert into public.game_config(key, value, updated_at)
    values (p_key, p_value, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();

  return query
    select c.key, c.value, c.updated_at
    from public.game_config c
    where c.key = p_key;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.award_early_claim_bonus_if_needed(p_sound_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_cfg                 jsonb;
  v_threshold           int;
  v_slots               int;
  v_claimer_xp          int;
  v_producer_xp         int;
  v_total_claims        int;
  v_producer_id         uuid;
  v_already             boolean;
  v_claimer_id          uuid;
  v_total_xp            int;
  v_new_xp              int;
  v_new_level           int;
begin
  select value into v_cfg from public.game_config where key = 'claim_sound';
  if v_cfg is null then return; end if;

  v_threshold   := coalesce((v_cfg ->> 'early_claim_threshold')::int,        10);
  v_slots       := coalesce((v_cfg ->> 'early_claim_slots')::int,             5);
  v_claimer_xp  := coalesce((v_cfg ->> 'early_claim_bonus_xp')::int,         20);
  v_producer_xp := coalesce((v_cfg ->> 'producer_milestone_bonus_xp')::int,  50);

  if v_threshold <= 0 then return; end if;

  -- Have we already fired the milestone for this sound?
  select true into v_already
  from public.sound_bonus_events
  where sound_id = p_sound_id and bonus_type = 'early_claim'
  limit 1;
  if v_already then return; end if;

  -- Total bona-fide claims (producer self-grant excluded).
  select count(*)::int into v_total_claims
  from public.user_sounds
  where sound_id = p_sound_id and source = 'claimed_from_producer';

  if v_total_claims < v_threshold then return; end if;

  -- Crossing the threshold now. Mark the milestone first so concurrent
  -- claims don't double-fire.
  insert into public.sound_bonus_events(sound_id, bonus_type)
  values (p_sound_id, 'early_claim')
  on conflict do nothing;

  -- Locate the producer to award the bigger bonus.
  select producer_id into v_producer_id
  from public.sound_catalog
  where id = p_sound_id;

  -- Award producer milestone XP.
  if v_producer_id is not null and v_producer_xp > 0 then
    select total_xp into v_total_xp
    from public.user_stats where user_id = v_producer_id;
    v_new_xp    := coalesce(v_total_xp, 0) + v_producer_xp;
    v_new_level := greatest(1, floor(v_new_xp / 300.0)::int + 1);
    update public.user_stats
       set total_xp = v_new_xp, level = v_new_level, updated_at = now()
     where user_id = v_producer_id;
    insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
      values (v_producer_id, 'sound_milestone_bonus', 0, v_producer_xp, p_sound_id);
    insert into public.notifications(user_id, kind, payload)
      values (
        v_producer_id,
        'early_claim_bonus_awarded',
        jsonb_build_object(
          'role',          'producer',
          'sound_id',      p_sound_id,
          'bonus_xp',      v_producer_xp,
          'total_claims',  v_total_claims
        )
      );
  end if;

  -- Award early-claimer bonuses to the first N claimers (oldest acquisitions).
  if v_slots > 0 and v_claimer_xp > 0 then
    for v_claimer_id in
      select user_id
      from public.user_sounds
      where sound_id = p_sound_id and source = 'claimed_from_producer'
      order by acquired_at asc
      limit v_slots
    loop
      select total_xp into v_total_xp
      from public.user_stats where user_id = v_claimer_id;
      v_new_xp    := coalesce(v_total_xp, 0) + v_claimer_xp;
      v_new_level := greatest(1, floor(v_new_xp / 300.0)::int + 1);
      update public.user_stats
         set total_xp = v_new_xp, level = v_new_level, updated_at = now()
       where user_id = v_claimer_id;
      insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
        values (v_claimer_id, 'early_claim_bonus', 0, v_claimer_xp, p_sound_id);
      insert into public.notifications(user_id, kind, payload)
        values (
          v_claimer_id,
          'early_claim_bonus_awarded',
          jsonb_build_object(
            'role',          'claimer',
            'sound_id',      p_sound_id,
            'bonus_xp',      v_claimer_xp,
            'total_claims',  v_total_claims
          )
        );
    end loop;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.award_early_ear_bonus_if_needed(p_song_id uuid, p_current_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_cfg                 jsonb;
  v_min_ratings         int;
  v_min_avg_stars       numeric;
  v_min_endorsements    int;
  v_bonus_xp            int;

  v_rating_count        int;
  v_avg_stars           numeric;
  v_endorsement_count   int;
  v_already_triggered   boolean;

  v_early_ear_user      uuid;
begin
  -- Load current threshold config. Exit quietly if the row is missing.
  select value into v_cfg from public.game_config where key = 'early_ear_threshold';
  if v_cfg is null then return; end if;

  v_min_ratings      := coalesce((v_cfg ->> 'min_ratings')::int,      10);
  v_min_avg_stars    := coalesce((v_cfg ->> 'min_avg_stars')::numeric, 4.0);
  v_min_endorsements := coalesce((v_cfg ->> 'min_endorsements')::int,  5);
  v_bonus_xp         := coalesce((v_cfg ->> 'bonus_xp')::int,         25);

  -- Already triggered? Skip.
  select exists (
    select 1 from public.song_bonus_events
    where song_id = p_song_id and bonus_type = 'early_ear'
  ) into v_already_triggered;
  if v_already_triggered then return; end if;

  -- Current aggregate for this song.
  select count(*)::int, coalesce(avg(stars)::numeric, 0)
    into v_rating_count, v_avg_stars
  from public.song_ratings where song_id = p_song_id;

  select count(*)::int into v_endorsement_count
  from public.song_endorsements where song_id = p_song_id;

  -- Threshold: either the rating gate (count + avg) OR the endorsement gate.
  if not (
       (v_rating_count     >= v_min_ratings and v_avg_stars >= v_min_avg_stars)
    or (v_endorsement_count >= v_min_endorsements)
  ) then
    return;
  end if;

  -- Mark as triggered FIRST so concurrent calls don't double-award.
  insert into public.song_bonus_events(song_id, bonus_type)
    values (p_song_id, 'early_ear')
    on conflict (song_id, bonus_type) do nothing;

  -- Award bonus XP to each qualifying early-ear user. Rules:
  --   - rated 4★+ before now, OR endorsed before now
  --   - not the user who just tipped the song over (p_current_user)
  --   - deduplicated (a user who did both only gets the bonus once)
  for v_early_ear_user in
    select distinct user_id from (
      select user_id from public.song_ratings
       where song_id = p_song_id and stars >= 4 and user_id <> p_current_user
      union
      select user_id from public.song_endorsements
       where song_id = p_song_id and user_id <> p_current_user
    ) q
  loop
    update public.user_stats
       set total_xp   = total_xp + v_bonus_xp,
           level      = greatest(1, floor((total_xp + v_bonus_xp) / 300.0)::int + 1),
           updated_at = now()
     where user_id = v_early_ear_user;

    insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
      values (v_early_ear_user, 'early_ear_bonus', 0, v_bonus_xp, p_song_id::text);
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.check_song_edit_lock(p_song_id text, p_coop_session_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(can_edit boolean, reason text, collaborator_ids uuid[], missing_collaborators uuid[], missing_sounds jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id            uuid;
  v_song               record;
  v_layers             jsonb;
  v_collab_ids         uuid[];   -- artist + collaborator user_ids (uuid)
  v_required_owners    uuid[];
  v_present_in_coop    uuid[];
  v_missing_collab     uuid[];
  v_missing_sounds     jsonb := '[]'::jsonb;
  v_layer              jsonb;
  v_sound_id           text;
  v_owner_id           uuid;
  v_owns               boolean;
  v_coop               record;
  v_pub                record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 'not_signed_in'::text,
      '{}'::uuid[], '{}'::uuid[], '[]'::jsonb;
    return;
  end if;

  select s.id, s.user_id, s.layers, s.published_publication_id
    into v_song
  from public.songs s
  where s.id = p_song_id;

  if not found then
    return query select false, 'song_not_found'::text,
      '{}'::uuid[], '{}'::uuid[], '[]'::jsonb;
    return;
  end if;

  -- Resolve real collaborator user_ids from the publication (Phase 5.A
  -- snapshot). songs.collaborators is legacy text[] of display names.
  if v_song.published_publication_id is not null then
    select sp.collaborator_ids into v_pub
    from public.song_publications sp
    where sp.id = v_song.published_publication_id;
    v_collab_ids := coalesce(v_pub.collaborator_ids, '{}'::uuid[]);
  else
    v_collab_ids := '{}'::uuid[];
  end if;

  -- Caller must be the artist or a collaborator.
  if v_song.user_id <> v_user_id
     and not (v_user_id = any(v_collab_ids)) then
    return query select false, 'not_a_collaborator'::text,
      v_collab_ids, '{}'::uuid[], '[]'::jsonb;
    return;
  end if;

  v_layers := coalesce(v_song.layers, '[]'::jsonb);

  -- ── Coop-presence check (only matters if there are collaborators) ──
  if array_length(v_collab_ids, 1) is not null and array_length(v_collab_ids, 1) > 0 then
    if p_coop_session_id is null then
      return query select false, 'no_coop_session'::text,
        v_collab_ids, v_collab_ids, '[]'::jsonb;
      return;
    end if;

    select cs.host_id, cs.guest_id, cs.status
      into v_coop
    from public.coop_sessions cs
    where cs.id = p_coop_session_id;

    if not found or v_coop.status <> 'active' then
      return query select false, 'no_coop_session'::text,
        v_collab_ids, v_collab_ids, '[]'::jsonb;
      return;
    end if;

    if v_user_id <> v_coop.host_id
       and (v_coop.guest_id is null or v_user_id <> v_coop.guest_id) then
      return query select false, 'not_in_coop_session'::text,
        v_collab_ids, v_collab_ids, '[]'::jsonb;
      return;
    end if;

    -- Required owners = artist + every collaborator user_id.
    v_required_owners := array(
      select distinct unnest(array_append(v_collab_ids, v_song.user_id))
    );
    v_present_in_coop := array(
      select x from unnest(array[v_coop.host_id, v_coop.guest_id]) x where x is not null
    );

    select array_agg(o)
      into v_missing_collab
    from unnest(v_required_owners) o
    where not (o = any(v_present_in_coop));

    if v_missing_collab is not null and array_length(v_missing_collab, 1) > 0 then
      return query select false, 'missing_collaborators'::text,
        v_collab_ids, v_missing_collab, '[]'::jsonb;
      return;
    end if;
  end if;

  -- ── Per-layer ownership check ──
  for v_layer in select * from jsonb_array_elements(v_layers) loop
    v_sound_id := v_layer ->> 'soundId';
    v_owner_id := nullif(v_layer ->> 'sourceOwnerId', '')::uuid;

    if v_owner_id is null then continue; end if;
    if v_sound_id is null or v_sound_id = '' then continue; end if;

    select exists(
      select 1 from public.user_sounds us
      where us.user_id  = v_owner_id
        and us.sound_id = v_sound_id
    ) into v_owns;

    if not v_owns then
      v_missing_sounds := v_missing_sounds
        || jsonb_build_object(
             'soundId',       v_sound_id,
             'sourceOwnerId', v_owner_id
           );
    end if;
  end loop;

  if jsonb_array_length(v_missing_sounds) > 0 then
    return query select false, 'missing_sounds'::text,
      v_collab_ids, '{}'::uuid[], v_missing_sounds;
    return;
  end if;

  return query select true, null::text,
    v_collab_ids, '{}'::uuid[], '[]'::jsonb;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_sound(p_sound_id text)
 RETURNS TABLE(success boolean, message text, sound_id text, already_owned boolean, claims_total integer, claims_this_week integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id              uuid;
  v_cat                  record;
  v_existing_owned       boolean;
  v_cfg                  jsonb;
  v_xp_per_claim         int;
  v_producer_daily_cap   int;

  v_producer_xp_today    int;
  v_xp_to_award          int;
  v_producer_total_xp    int;
  v_producer_new_xp      int;
  v_producer_new_level   int;

  v_total_claims         int;
  v_week_claims          int;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 'Not signed in'::text, null::text, false, 0, 0;
    return;
  end if;

  if p_sound_id is null or btrim(p_sound_id) = '' then
    return query select false, 'Sound id required'::text, null::text, false, 0, 0;
    return;
  end if;

  select sc.id, sc.category, sc.producer_id
    into v_cat
  from public.sound_catalog sc
  where sc.id = p_sound_id;

  if not found then
    return query select false, 'Sound not found'::text, null::text, false, 0, 0;
    return;
  end if;

  if v_cat.category <> 'producer_published' then
    return query select false, 'Only producer-published sounds can be claimed'::text, null::text, false, 0, 0;
    return;
  end if;

  if v_cat.producer_id = v_user_id then
    return query select true, 'You already own this — you produced it'::text,
      v_cat.id, true, 0, 0;
    return;
  end if;

  select true into v_existing_owned
  from public.user_sounds us
  where us.user_id = v_user_id and us.sound_id = p_sound_id
  limit 1;

  if v_existing_owned then
    -- Aliased so OUT column `sound_id` doesn't shadow user_sounds.sound_id.
    select
      count(*)::int,
      count(*) filter (where us.acquired_at >= (now() - interval '7 days'))::int
      into v_total_claims, v_week_claims
    from public.user_sounds us
    where us.sound_id = p_sound_id and us.source = 'claimed_from_producer';

    return query select true, 'Already in your inventory'::text,
      v_cat.id, true,
      coalesce(v_total_claims, 0), coalesce(v_week_claims, 0);
    return;
  end if;

  insert into public.user_sounds(user_id, sound_id, source)
  values (v_user_id, p_sound_id, 'claimed_from_producer')
  on conflict on constraint user_sounds_pkey do nothing;

  insert into public.sound_acquisitions(user_id, sound_id, source)
  values (v_user_id, p_sound_id, 'claimed_from_producer');

  select value into v_cfg from public.game_config where key = 'claim_sound';
  v_xp_per_claim       := coalesce((v_cfg ->> 'producer_xp_per_claim')::int, 3);
  v_producer_daily_cap := coalesce((v_cfg ->> 'producer_daily_xp_cap')::int, 60);

  if v_cat.producer_id is not null and v_xp_per_claim > 0 then
    select coalesce(sum(pe.xp_delta), 0)::int
      into v_producer_xp_today
    from public.player_events pe
    where pe.user_id    = v_cat.producer_id
      and pe.event_type = 'sound_claimed'
      and pe.created_at >= date_trunc('day', now() at time zone 'utc');

    v_xp_to_award := least(
      v_xp_per_claim,
      greatest(0, v_producer_daily_cap - coalesce(v_producer_xp_today, 0))
    );

    if v_xp_to_award > 0 then
      select us.total_xp into v_producer_total_xp
      from public.user_stats us where us.user_id = v_cat.producer_id;
      v_producer_new_xp    := coalesce(v_producer_total_xp, 0) + v_xp_to_award;
      v_producer_new_level := greatest(1, floor(v_producer_new_xp / 300.0)::int + 1);
      update public.user_stats
         set total_xp   = v_producer_new_xp,
             level      = v_producer_new_level,
             updated_at = now()
       where user_id = v_cat.producer_id;
    end if;

    insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
      values (v_cat.producer_id, 'sound_claimed', 0,
              coalesce(v_xp_to_award, 0), v_cat.id);
  end if;

  perform public.award_early_claim_bonus_if_needed(p_sound_id);

  -- Aliased for the same reason.
  select
    count(*)::int,
    count(*) filter (where us.acquired_at >= (now() - interval '7 days'))::int
    into v_total_claims, v_week_claims
  from public.user_sounds us
  where us.sound_id = p_sound_id and us.source = 'claimed_from_producer';

  return query select true, 'Claimed!'::text,
    v_cat.id, false,
    coalesce(v_total_claims, 0), coalesce(v_week_claims, 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_coop_session(p_invite_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, join_code text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_id   uuid;
  v_code text;
begin
  v_self := auth.uid();
  if v_self is null then raise exception 'Not signed in'; end if;
  if p_invite_user_id = v_self then raise exception 'Cannot invite yourself'; end if;

  v_code := public._coop_gen_code();
  v_id   := gen_random_uuid();

  insert into public.coop_sessions(
    id, host_id, guest_id, invited_user_id,
    join_code, status, state, invited_at
  ) values (
    v_id, v_self, null, p_invite_user_id,
    v_code, 'pending', '{}'::jsonb, now()
  );

  return query select v_id, v_code, 'pending'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.decline_coop_invite(p_session_id uuid)
 RETURNS TABLE(success boolean, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_row  record;
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text;
    return;
  end if;

  select * into v_row from public.coop_sessions where id = p_session_id;
  if not found then
    return query select false, 'Session not found'::text;
    return;
  end if;

  -- Null-safe: invited_user_id may be null for code-only sessions; only
  -- the actual invitee should be able to decline.
  if v_row.invited_user_id is distinct from v_self then
    return query select false, 'Not invited to this session'::text;
    return;
  end if;

  update public.coop_sessions
     set status = 'abandoned', updated_at = now()
   where id = p_session_id;

  return query select true, 'Declined'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.earn_xp_capped(p_event_type text, p_xp integer, p_daily_xp_cap integer, p_target_id text DEFAULT NULL::text)
 RETURNS TABLE(xp_awarded integer, new_xp integer, daily_xp_earned integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid;
  v_today_earned int;
  v_to_award int;
  v_total_xp int;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return;
  end if;

  insert into public.user_stats (user_id) values (v_user_id)
    on conflict (user_id) do nothing;

  select coalesce(sum(xp_delta), 0)::int
    into v_today_earned
    from public.player_events
    where user_id = v_user_id
      and event_type = p_event_type
      and created_at >= date_trunc('day', now());

  v_to_award := greatest(0, least(p_xp, p_daily_xp_cap - v_today_earned));

  if v_to_award > 0 then
    update public.user_stats
      set total_xp = total_xp + v_to_award
      where user_id = v_user_id;
  end if;

  insert into public.player_events (user_id, event_type, energy_delta, xp_delta, target_id)
  values (v_user_id, p_event_type, 0, v_to_award, p_target_id);

  select total_xp into v_total_xp from public.user_stats where user_id = v_user_id;

  return query select v_to_award, v_total_xp, (v_today_earned + v_to_award);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.endorse_song(p_song_id uuid)
 RETURNS TABLE(success boolean, message text, new_energy integer, new_xp integer, new_level integer, endorsements_today integer, daily_cap integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id            uuid;
  v_cost     constant  int  := 15;
  v_xp_gain  constant  int  := 10;
  v_energy_max constant int := 100;
  v_regen_s  constant  int  := 300;

  v_base_energy        int;
  v_updated_at         timestamptz;
  v_live_energy        int;
  v_new_energy         int;

  v_total_xp           int;
  v_new_xp             int;
  v_level              int;
  v_new_level          int;

  v_daily_cap          int;
  v_count_today        int;

  v_already            boolean;

  -- Artist credit
  v_artist_id          uuid;
  v_boost_cfg          jsonb;
  v_boost_per          int;
  v_boost_daily_cap    int;
  v_artist_boost_today int;
  v_artist_credit      int;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 'Not signed in'::text, 0, 0, 1, 0, 0;
    return;
  end if;

  select exists (
    select 1 from public.song_endorsements
    where user_id = v_user_id and song_id = p_song_id
  ) into v_already;

  if v_already then
    return query select false, 'Already pushed'::text, 0, 0, 1, 0, 0;
    return;
  end if;

  select level, total_xp, energy, energy_updated_at
    into v_level, v_total_xp, v_base_energy, v_updated_at
  from public.user_stats
  where user_id = v_user_id;

  if v_level is null then
    insert into public.user_stats(user_id, level, total_xp, energy, energy_updated_at)
      values (v_user_id, 1, 0, v_energy_max, now())
      on conflict (user_id) do nothing;
    v_level        := 1;
    v_total_xp     := 0;
    v_base_energy  := v_energy_max;
    v_updated_at   := now();
  end if;

  v_daily_cap := case
    when v_level <= 5  then 3
    when v_level <= 15 then 5
    when v_level <= 30 then 7
    else 10
  end;

  select count(*)::int
    into v_count_today
  from public.player_events
  where user_id    = v_user_id
    and event_type = 'endorse'
    and created_at >= date_trunc('day', now() at time zone 'utc');

  if v_count_today >= v_daily_cap then
    return query select false,
      format('Daily push cap reached (%s/%s)', v_count_today, v_daily_cap)::text,
      v_base_energy, v_total_xp, v_level, v_count_today, v_daily_cap;
    return;
  end if;

  v_live_energy := least(
    v_energy_max,
    v_base_energy + floor(extract(epoch from (now() - v_updated_at)) / v_regen_s)::int
  );

  if v_live_energy < v_cost then
    return query select false,
      format('Not enough energy (%s/%s)', v_live_energy, v_cost)::text,
      v_live_energy, v_total_xp, v_level, v_count_today, v_daily_cap;
    return;
  end if;

  v_new_energy := v_live_energy - v_cost;
  v_new_xp    := v_total_xp + v_xp_gain;
  v_new_level := greatest(1, floor(v_new_xp / 300.0)::int + 1);

  update public.user_stats
     set energy            = v_new_energy,
         energy_updated_at = now(),
         total_xp          = v_new_xp,
         level             = v_new_level,
         updated_at        = now()
   where user_id = v_user_id;

  insert into public.song_endorsements(user_id, song_id)
    values (v_user_id, p_song_id);

  insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
    values (v_user_id, 'endorse', -v_cost, v_xp_gain, p_song_id::text);

  -- ── NEW: Credit the artist with a small energy boost ──
  -- Skipped when the endorser IS the artist (no self-endorse reward).
  -- Capped per-day-per-artist from config so farming via alts is limited.
  select artist_id into v_artist_id
  from public.song_publications
  where id = p_song_id;

  if v_artist_id is not null and v_artist_id <> v_user_id then
    select value into v_boost_cfg from public.game_config where key = 'artist_boost';
    v_boost_per        := coalesce((v_boost_cfg ->> 'energy_per_endorsement')::int, 5);
    v_boost_daily_cap  := coalesce((v_boost_cfg ->> 'daily_cap_energy')::int, 25);

    -- How much boost has this artist already received today?
    select coalesce(sum(energy_delta), 0)::int
      into v_artist_boost_today
    from public.player_events
    where user_id    = v_artist_id
      and event_type = 'artist_boost'
      and created_at >= date_trunc('day', now() at time zone 'utc');

    v_artist_credit := least(v_boost_per, greatest(0, v_boost_daily_cap - v_artist_boost_today));

    if v_artist_credit > 0 then
      -- Credit the artist atomically. Use live-energy math so a capped
      -- artist doesn't overflow: we add to base, clamp to energy_max.
      update public.user_stats
         set energy = least(
               v_energy_max,
               least(energy, v_energy_max) -- clamp current first
                 + v_artist_credit
             ),
             energy_updated_at = now(),
             updated_at = now()
       where user_id = v_artist_id;

      insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
        values (v_artist_id, 'artist_boost', v_artist_credit, 0, p_song_id::text);
    end if;
  end if;

  -- ── NEW: early-ear bonus check ──
  perform public.award_early_ear_bonus_if_needed(p_song_id, v_user_id);

  return query select true,
    format('pushed (%s/%s today)', v_count_today + 1, v_daily_cap)::text,
    v_new_energy, v_new_xp, v_new_level, v_count_today + 1, v_daily_cap;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_live_energy(p_energy_max integer DEFAULT 100, p_regen_interval_seconds integer DEFAULT 300)
 RETURNS TABLE(live_energy integer, base_energy integer, energy_updated_at timestamp with time zone, level integer, total_xp integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return;
  end if;

  insert into public.user_stats (user_id) values (v_user_id)
    on conflict (user_id) do nothing;

  return query
    select
      least(
        p_energy_max,
        us.energy + floor(extract(epoch from (now() - us.energy_updated_at)) / p_regen_interval_seconds)::int
      ) as live_energy,
      us.energy            as base_energy,
      us.energy_updated_at,
      us.level,
      us.total_xp
    from public.user_stats us
    where us.user_id = v_user_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.grant_starter_sounds_to_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  insert into public.user_sounds (user_id, sound_id, source)
  select NEW.id, c.id, 'starter'
  from public.sound_catalog c
  where c.category = 'starter'
  on conflict (user_id, sound_id) do nothing;
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  insert into public.profiles (id, username, avatar)
  values (new.id, split_part(new.email, '@', 1), '🧢');
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.join_coop_by_code(p_code text)
 RETURNS TABLE(success boolean, message text, session_id uuid, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_row  record;
  v_union text[];
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text, null::uuid, null::text;
    return;
  end if;

  select * into v_row
  from public.coop_sessions
  where upper(join_code) = upper(p_code)
  order by created_at desc
  limit 1;

  if not found then
    return query select false, 'Session not found for that code'::text, null::uuid, null::text;
    return;
  end if;

  if v_row.host_id = v_self then
    return query select false, 'That is your own session'::text, v_row.id, v_row.status;
    return;
  end if;

  if v_row.status <> 'pending' then
    return query select false, format('Session is %s', v_row.status)::text, v_row.id, v_row.status;
    return;
  end if;

  update public.coop_sessions
     set guest_id        = v_self,
         invited_user_id = v_self,
         status          = 'active',
         accepted_at     = now(),
         updated_at      = now()
   where id = v_row.id;

  v_union := public._coop_compute_union(v_row.id);
  update public.coop_sessions
     set available_sound_ids = v_union,
         updated_at          = now()
   where id = v_row.id;

  return query select true, 'Joined'::text, v_row.id, 'active'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.leave_coop_session(p_session_id uuid)
 RETURNS TABLE(success boolean, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_row  record;
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text;
    return;
  end if;

  select * into v_row from public.coop_sessions where id = p_session_id;
  if not found then
    return query select false, 'Session not found'::text;
    return;
  end if;

  -- Null-safe: IS DISTINCT FROM treats NULL properly, so a stranger on a
  -- pending session (guest_id=null) is still correctly rejected.
  if v_row.host_id is distinct from v_self
     and v_row.guest_id is distinct from v_self then
    return query select false, 'Not a participant'::text;
    return;
  end if;

  update public.coop_sessions
     set status = 'abandoned', updated_at = now()
   where id = p_session_id;

  return query select true, 'Left'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_on_coop_invite()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_host_username text;
  v_host_avatar   text;
begin
  -- Only target-invite sessions trigger a notification. Code-only
  -- sessions (invited_user_id null) are joined by paste-a-code.
  if NEW.invited_user_id is null or NEW.status <> 'pending' then
    return NEW;
  end if;

  select username, avatar
    into v_host_username, v_host_avatar
  from public.profiles
  where id = NEW.host_id;

  insert into public.notifications(user_id, kind, payload)
  values (
    NEW.invited_user_id,
    'coop_invite_received',
    jsonb_build_object(
      'session_id',     NEW.id,
      'host_id',        NEW.host_id,
      'host_username',  coalesce(nullif(v_host_username, ''), 'someone'),
      'host_avatar',    coalesce(nullif(v_host_avatar, ''), '👤'),
      'join_code',      NEW.join_code
    )
  );

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_on_endorsement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_artist_id    uuid;
  v_song_title   text;
  v_fan_username text;
  v_fan_avatar   text;
begin
  select artist_id, title into v_artist_id, v_song_title
  from public.song_publications
  where id = NEW.song_id;

  -- skip self-endorsement (shouldn't happen with our other guards but
  -- defense-in-depth) and missing artist (retired song, etc.)
  if v_artist_id is null or v_artist_id = NEW.user_id then
    return NEW;
  end if;

  select username, avatar into v_fan_username, v_fan_avatar
  from public.profiles
  where id = NEW.user_id;

  insert into public.notifications(user_id, kind, payload)
  values (
    v_artist_id,
    'endorsement_received',
    jsonb_build_object(
      'song_id',      NEW.song_id,
      'song_title',   coalesce(v_song_title, 'your song'),
      'fan_id',       NEW.user_id,
      'fan_username', coalesce(nullif(v_fan_username, ''), 'someone'),
      'fan_avatar',   coalesce(nullif(v_fan_avatar, ''), '👤')
    )
  );

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_on_friend_accept()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_target_id uuid;            -- the original requester
  v_accepter_id uuid;
  v_accepter_username text;
  v_accepter_avatar   text;
begin
  -- Only fire on the specific pending → accepted transition
  if OLD.status = 'pending' and NEW.status = 'accepted' then
    -- The accepter is the side that wasn't requested_by.
    v_target_id := NEW.requested_by;
    if v_target_id = NEW.user_a_id then
      v_accepter_id := NEW.user_b_id;
    else
      v_accepter_id := NEW.user_a_id;
    end if;

    select username, avatar
      into v_accepter_username, v_accepter_avatar
    from public.profiles
    where id = v_accepter_id;

    insert into public.notifications(user_id, kind, payload)
    values (
      v_target_id,
      'friend_request_accepted',
      jsonb_build_object(
        'accepter_id',       v_accepter_id,
        'accepter_username', coalesce(nullif(v_accepter_username, ''), 'someone'),
        'accepter_avatar',   coalesce(nullif(v_accepter_avatar, ''), '👤')
      )
    );
  end if;

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_on_friend_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_target_id uuid;
  v_requester_username text;
  v_requester_avatar   text;
begin
  -- Only fire on initial pending insert (not blocks)
  if NEW.status <> 'pending' then return NEW; end if;

  -- Target = whichever side of the pair is NOT the requester
  if NEW.requested_by = NEW.user_a_id then
    v_target_id := NEW.user_b_id;
  else
    v_target_id := NEW.user_a_id;
  end if;

  select username, avatar
    into v_requester_username, v_requester_avatar
  from public.profiles
  where id = NEW.requested_by;

  insert into public.notifications(user_id, kind, payload)
  values (
    v_target_id,
    'friend_request_received',
    jsonb_build_object(
      'requester_id',       NEW.requested_by,
      'requester_username', coalesce(nullif(v_requester_username, ''), 'someone'),
      'requester_avatar',   coalesce(nullif(v_requester_avatar, ''), '👤')
    )
  );
  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_on_player_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_kind        text;
  v_song_title  text;
begin
  if NEW.event_type = 'early_ear_bonus' then
    v_kind := 'early_ear_bonus_awarded';
  elsif NEW.event_type = 'artist_boost' then
    v_kind := 'artist_boost_received';
  else
    return NEW;
  end if;

  -- target_id may be a uuid pointing to a song_publications row.
  -- Use a safe cast — if target_id isn't a uuid, leave title null.
  if NEW.target_id is not null then
    begin
      select title into v_song_title
      from public.song_publications
      where id = NEW.target_id::uuid;
    exception when others then
      v_song_title := null;
    end;
  end if;

  insert into public.notifications(user_id, kind, payload)
  values (
    NEW.user_id,
    v_kind,
    jsonb_build_object(
      'song_id',      NEW.target_id,
      'song_title',   coalesce(v_song_title, 'a drop'),
      'energy_delta', NEW.energy_delta,
      'xp_delta',     NEW.xp_delta
    )
  );

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.patch_coop_session_state(p_session_id uuid, p_patch jsonb)
 RETURNS TABLE(success boolean, message text, state jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_row  record;
  v_new  jsonb;
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text, null::jsonb;
    return;
  end if;

  select * into v_row from public.coop_sessions where id = p_session_id;
  if not found then
    return query select false, 'Session not found'::text, null::jsonb;
    return;
  end if;

  -- Null-safe participant check (see leave_coop_session note).
  if v_row.host_id is distinct from v_self
     and v_row.guest_id is distinct from v_self then
    return query select false, 'Not a participant'::text, null::jsonb;
    return;
  end if;

  if v_row.status <> 'active' then
    return query select false, format('Session is %s', v_row.status)::text, v_row.state;
    return;
  end if;

  v_new := coalesce(v_row.state, '{}'::jsonb) || coalesce(p_patch, '{}'::jsonb);

  update public.coop_sessions
     set state      = v_new,
         updated_at = now()
   where id = p_session_id;

  return query select true, 'OK'::text, v_new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.publish_song(p_song_id text, p_audio_url text, p_collaborator_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS TABLE(success boolean, message text, publication_id uuid, new_energy integer, new_xp integer, new_level integer, publications_today integer, daily_cap integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id       uuid;
  v_energy_max    constant int := 100;
  v_regen_s       constant int := 300;

  v_cfg           jsonb;
  v_energy_cost   int;
  v_xp_gain       int;
  v_cap_l1        int;
  v_cap_l6        int;
  v_cap_l16       int;
  v_cap_l31       int;

  v_song          record;
  v_profile       record;

  v_level         int;
  v_total_xp     int;
  v_base_energy  int;
  v_updated_at   timestamptz;
  v_live_energy  int;
  v_new_energy   int;
  v_new_xp       int;
  v_new_level    int;

  v_daily_cap    int;
  v_count_today  int;

  v_duration_sec  int;
  v_publication_id uuid;

  v_artist_name   text;
  v_artist_avatar text;

  v_collab_ids   uuid[];
  v_collab_names text[];

  v_template_uuid uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 'Not signed in'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  select value into v_cfg from public.game_config where key = 'publish_song';
  v_energy_cost := coalesce((v_cfg ->> 'energy_cost')::int,    40);
  v_xp_gain     := coalesce((v_cfg ->> 'xp')::int,              25);
  v_cap_l1      := coalesce((v_cfg ->> 'daily_cap_l1_5')::int,   1);
  v_cap_l6      := coalesce((v_cfg ->> 'daily_cap_l6_15')::int,  2);
  v_cap_l16     := coalesce((v_cfg ->> 'daily_cap_l16_30')::int, 3);
  v_cap_l31     := coalesce((v_cfg ->> 'daily_cap_l31_plus')::int, 5);

  select id, user_id, name, bars, bpm, key_root, published_publication_id, template_id
    into v_song
  from public.songs
  where id = p_song_id;

  if not found or v_song.id is null then
    return query select false, 'Song not found'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  if v_song.user_id is distinct from v_user_id then
    return query select false, 'You can only publish your own songs'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  if v_song.published_publication_id is not null then
    return query select false, 'This song is already published'::text,
      v_song.published_publication_id, 0, 0, 1, 0, 0;
    return;
  end if;

  select level, total_xp, energy, energy_updated_at
    into v_level, v_total_xp, v_base_energy, v_updated_at
  from public.user_stats
  where user_id = v_user_id;

  if v_level is null then
    insert into public.user_stats(user_id, level, total_xp, energy, energy_updated_at)
      values (v_user_id, 1, 0, v_energy_max, now())
      on conflict (user_id) do nothing;
    v_level        := 1;
    v_total_xp     := 0;
    v_base_energy  := v_energy_max;
    v_updated_at   := now();
  end if;

  v_daily_cap := case
    when v_level <= 5  then v_cap_l1
    when v_level <= 15 then v_cap_l6
    when v_level <= 30 then v_cap_l16
    else                    v_cap_l31
  end;

  select count(*)::int into v_count_today
  from public.player_events
  where user_id    = v_user_id
    and event_type = 'publish_song'
    and created_at >= date_trunc('day', now() at time zone 'utc');

  if v_count_today >= v_daily_cap then
    return query select false,
      format('Daily publish cap reached (%s/%s). Try again tomorrow.',
             v_count_today, v_daily_cap)::text,
      null::uuid, v_base_energy, v_total_xp, v_level,
      v_count_today, v_daily_cap;
    return;
  end if;

  v_live_energy := least(
    v_energy_max,
    v_base_energy + floor(extract(epoch from (now() - v_updated_at)) / v_regen_s)::int
  );
  if v_live_energy < v_energy_cost then
    return query select false,
      format('Not enough energy to publish (%s/%s)',
             v_live_energy, v_energy_cost)::text,
      null::uuid, v_live_energy, v_total_xp, v_level,
      v_count_today, v_daily_cap;
    return;
  end if;

  select username, avatar into v_profile
  from public.profiles
  where id = v_user_id;

  v_artist_name   := coalesce(nullif(v_profile.username, ''), 'untitled artist');
  v_artist_avatar := coalesce(nullif(v_profile.avatar, ''), '🎧');

  v_duration_sec := greatest(1,
    round((greatest(v_song.bars, ceil(16.0 / v_song.bars) * v_song.bars) * 4.0 * 60.0) / v_song.bpm)::int
  );

  v_new_energy := v_live_energy - v_energy_cost;
  v_new_xp     := v_total_xp + v_xp_gain;
  v_new_level  := greatest(1, floor(v_new_xp / 300.0)::int + 1);

  -- Snapshot collaborators
  select array_agg(distinct c) filter (where c is not null and c <> v_user_id)
    into v_collab_ids
  from unnest(coalesce(p_collaborator_ids, '{}'::uuid[])) as c;
  v_collab_ids := coalesce(v_collab_ids, '{}'::uuid[]);

  select coalesce(array_agg(coalesce(nullif(p.username, ''), 'anon') order by c.ord), '{}'::text[])
    into v_collab_names
  from unnest(v_collab_ids) with ordinality as c(id, ord)
  left join public.profiles p on p.id = c.id;

  insert into public.song_publications(
    artist_id, artist_name, artist_avatar,
    title, audio_url,
    bpm, key_root, duration_sec,
    collaborator_ids, collaborator_names
  )
  values (
    v_user_id, v_artist_name, v_artist_avatar,
    v_song.name, p_audio_url,
    v_song.bpm, v_song.key_root, v_duration_sec,
    v_collab_ids, v_collab_names
  )
  returning id into v_publication_id;

  update public.user_stats
     set energy            = v_new_energy,
         energy_updated_at = now(),
         total_xp          = v_new_xp,
         level             = v_new_level,
         updated_at        = now()
   where user_id = v_user_id;

  update public.songs
     set published_publication_id = v_publication_id
   where id = p_song_id;

  insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
    values (v_user_id, 'publish_song', -v_energy_cost, v_xp_gain, v_publication_id::text);

  -- ── Phase 5.B step 10 — bump producer template usage_count ──
  -- Only if the song's template_id resolves to a published template
  -- (legacy static-template ids like 'tpl-trap-hook' aren't UUIDs and
  -- silently fail the regex).
  if v_song.template_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_template_uuid := v_song.template_id::uuid;
    update public.template_publications
       set usage_count = usage_count + 1
     where id = v_template_uuid;
  end if;

  return query select true,
    format('Published (%s/%s today)', v_count_today + 1, v_daily_cap)::text,
    v_publication_id, v_new_energy, v_new_xp, v_new_level,
    v_count_today + 1, v_daily_cap;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.publish_sound(p_kind text, p_display_name text, p_glyph text, p_audio_url text, p_variant text DEFAULT NULL::text, p_bpm integer DEFAULT NULL::integer, p_key_root text DEFAULT NULL::text)
 RETURNS TABLE(success boolean, message text, sound_id text, new_energy integer, new_xp integer, new_level integer, publications_today integer, daily_cap integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id      uuid;
  v_energy_max   constant int := 100;
  v_regen_s      constant int := 300;

  v_cfg          jsonb;
  v_energy_cost  int;
  v_xp_gain      int;
  v_cap_l1       int;
  v_cap_l6       int;
  v_cap_l16      int;
  v_cap_l31      int;

  v_level        int;
  v_total_xp     int;
  v_base_energy  int;
  v_updated_at   timestamptz;
  v_live_energy  int;
  v_new_energy   int;
  v_new_xp       int;
  v_new_level    int;

  v_daily_cap    int;
  v_count_today  int;

  v_sound_id     text;

  v_kind_ok      constant text[] := array[
    'drums','kick','snare','hat','808','sample','melody','vocal','fx','pad'
  ];

  v_dn   text;
  v_var  text;
  v_gly  text;
  v_kr   text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 'Not signed in'::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  if p_kind is null or not (p_kind = any(v_kind_ok)) then
    return query select false,
      format('Invalid kind: %s', coalesce(p_kind, '(null)'))::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  v_dn  := nullif(btrim(p_display_name), '');
  if v_dn is null or length(v_dn) > 40 then
    return query select false, 'Display name must be 1-40 chars'::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  v_var := nullif(btrim(coalesce(p_variant, '')), '');
  if v_var is not null and length(v_var) > 30 then
    return query select false, 'Variant must be ≤30 chars'::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  v_gly := nullif(btrim(coalesce(p_glyph, '')), '');
  if v_gly is null then v_gly := '🎵'; end if;
  if length(v_gly) > 8 then
    return query select false, 'Glyph must be ≤8 chars'::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  if p_audio_url is null or btrim(p_audio_url) = '' then
    return query select false, 'Audio URL required'::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  v_kr := nullif(btrim(coalesce(p_key_root, '')), '');

  if p_bpm is not null and (p_bpm < 40 or p_bpm > 240) then
    return query select false, 'BPM must be 40-240'::text,
      null::text, 0, 0, 1, 0, 0;
    return;
  end if;

  select value into v_cfg from public.game_config where key = 'publish_sound';
  v_energy_cost := coalesce((v_cfg ->> 'energy_cost')::int,         15);
  v_xp_gain     := coalesce((v_cfg ->> 'xp')::int,                  12);
  v_cap_l1      := coalesce((v_cfg ->> 'daily_cap_l1_5')::int,       3);
  v_cap_l6      := coalesce((v_cfg ->> 'daily_cap_l6_15')::int,      5);
  v_cap_l16     := coalesce((v_cfg ->> 'daily_cap_l16_30')::int,     8);
  v_cap_l31     := coalesce((v_cfg ->> 'daily_cap_l31_plus')::int,  12);

  select level, total_xp, energy, energy_updated_at
    into v_level, v_total_xp, v_base_energy, v_updated_at
  from public.user_stats
  where user_id = v_user_id;

  if v_level is null then
    insert into public.user_stats(user_id, level, total_xp, energy, energy_updated_at)
      values (v_user_id, 1, 0, v_energy_max, now())
      on conflict (user_id) do nothing;
    v_level       := 1;
    v_total_xp    := 0;
    v_base_energy := v_energy_max;
    v_updated_at  := now();
  end if;

  v_daily_cap := case
    when v_level <= 5  then v_cap_l1
    when v_level <= 15 then v_cap_l6
    when v_level <= 30 then v_cap_l16
    else                    v_cap_l31
  end;

  select count(*)::int into v_count_today
  from public.player_events
  where user_id    = v_user_id
    and event_type = 'publish_sound'
    and created_at >= date_trunc('day', now() at time zone 'utc');

  if v_count_today >= v_daily_cap then
    return query select false,
      format('Daily publish-sound cap reached (%s/%s). Try again tomorrow.',
             v_count_today, v_daily_cap)::text,
      null::text, v_base_energy, v_total_xp, v_level,
      v_count_today, v_daily_cap;
    return;
  end if;

  v_live_energy := least(
    v_energy_max,
    v_base_energy + floor(extract(epoch from (now() - v_updated_at)) / v_regen_s)::int
  );
  if v_live_energy < v_energy_cost then
    return query select false,
      format('Not enough energy to publish (%s/%s)',
             v_live_energy, v_energy_cost)::text,
      null::text, v_live_energy, v_total_xp, v_level,
      v_count_today, v_daily_cap;
    return;
  end if;

  v_sound_id := 'prod-' || replace(extensions.gen_random_uuid()::text, '-', '');

  insert into public.sound_catalog(
    id, kind, variant, display_name, glyph, audio_url,
    bpm, key_root, category, producer_id
  )
  values (
    v_sound_id, p_kind, v_var, v_dn, v_gly, p_audio_url,
    p_bpm, v_kr, 'producer_published', v_user_id
  );

  -- ON CONFLICT must reference the constraint by name; using
  -- (user_id, sound_id) triggers ambiguity with the function's `sound_id`
  -- OUT column.
  insert into public.user_sounds(user_id, sound_id, source)
  values (v_user_id, v_sound_id, 'self_published')
  on conflict on constraint user_sounds_pkey do nothing;

  insert into public.sound_acquisitions(user_id, sound_id, source)
  values (v_user_id, v_sound_id, 'self_published');

  v_new_energy := v_live_energy - v_energy_cost;
  v_new_xp     := v_total_xp + v_xp_gain;
  v_new_level  := greatest(1, floor(v_new_xp / 300.0)::int + 1);

  update public.user_stats
     set energy            = v_new_energy,
         energy_updated_at = now(),
         total_xp          = v_new_xp,
         level             = v_new_level,
         updated_at        = now()
   where user_id = v_user_id;

  insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
    values (v_user_id, 'publish_sound', -v_energy_cost, v_xp_gain, v_sound_id);

  return query select true,
    format('Published sound (%s/%s today)', v_count_today + 1, v_daily_cap)::text,
    v_sound_id, v_new_energy, v_new_xp, v_new_level,
    v_count_today + 1, v_daily_cap;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.publish_template(p_name text, p_subtitle text, p_bpm integer, p_key_root text, p_bars integer, p_recipe text[], p_sound_ids text[], p_tags text[])
 RETURNS TABLE(success boolean, message text, template_id uuid, new_energy integer, new_xp integer, new_level integer, publications_today integer, daily_cap integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id      uuid;
  v_energy_max   constant int := 100;
  v_regen_s      constant int := 300;

  v_cfg          jsonb;
  v_energy_cost  int;
  v_xp_gain      int;
  v_cap_l1       int;
  v_cap_l6       int;
  v_cap_l16      int;
  v_cap_l31      int;

  v_level        int;
  v_total_xp     int;
  v_base_energy  int;
  v_updated_at   timestamptz;
  v_live_energy  int;
  v_new_energy   int;
  v_new_xp       int;
  v_new_level    int;

  v_daily_cap    int;
  v_count_today  int;

  v_name         text;
  v_subtitle     text;
  v_template_id  uuid;
  v_missing_id   text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 'Not signed in'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  -- Validate inputs
  v_name := nullif(btrim(p_name), '');
  if v_name is null or length(v_name) > 50 then
    return query select false, 'Template name must be 1-50 chars'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  v_subtitle := nullif(btrim(coalesce(p_subtitle, '')), '');
  if v_subtitle is not null and length(v_subtitle) > 80 then
    return query select false, 'Subtitle must be ≤80 chars'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  if p_bpm is null or p_bpm < 40 or p_bpm > 240 then
    return query select false, 'BPM must be 40-240'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  if p_bars is null or p_bars < 1 or p_bars > 32 then
    return query select false, 'Bars must be 1-32'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  if p_recipe is null or array_length(p_recipe, 1) is null then
    return query select false, 'Recipe must have at least one kind'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  if p_sound_ids is null or array_length(p_sound_ids, 1) is null then
    return query select false, 'Sound ids must have at least one entry'::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  -- Producer must own every referenced sound.
  select s into v_missing_id
  from unnest(p_sound_ids) s
  where not exists (
    select 1 from public.user_sounds us
    where us.user_id = v_user_id and us.sound_id = s
  )
  limit 1;

  if v_missing_id is not null then
    return query select false,
      format('You don''t own sound %s — claim it first', v_missing_id)::text,
      null::uuid, 0, 0, 1, 0, 0;
    return;
  end if;

  -- Config + caps
  select value into v_cfg from public.game_config where key = 'publish_template';
  v_energy_cost := coalesce((v_cfg ->> 'energy_cost')::int,        25);
  v_xp_gain     := coalesce((v_cfg ->> 'xp')::int,                 20);
  v_cap_l1      := coalesce((v_cfg ->> 'daily_cap_l1_5')::int,      1);
  v_cap_l6      := coalesce((v_cfg ->> 'daily_cap_l6_15')::int,     2);
  v_cap_l16     := coalesce((v_cfg ->> 'daily_cap_l16_30')::int,    3);
  v_cap_l31     := coalesce((v_cfg ->> 'daily_cap_l31_plus')::int,  5);

  select level, total_xp, energy, energy_updated_at
    into v_level, v_total_xp, v_base_energy, v_updated_at
  from public.user_stats
  where user_id = v_user_id;

  if v_level is null then
    insert into public.user_stats(user_id, level, total_xp, energy, energy_updated_at)
      values (v_user_id, 1, 0, v_energy_max, now())
      on conflict (user_id) do nothing;
    v_level       := 1;
    v_total_xp    := 0;
    v_base_energy := v_energy_max;
    v_updated_at  := now();
  end if;

  v_daily_cap := case
    when v_level <= 5  then v_cap_l1
    when v_level <= 15 then v_cap_l6
    when v_level <= 30 then v_cap_l16
    else                    v_cap_l31
  end;

  select count(*)::int into v_count_today
  from public.player_events
  where user_id    = v_user_id
    and event_type = 'publish_template'
    and created_at >= date_trunc('day', now() at time zone 'utc');

  if v_count_today >= v_daily_cap then
    return query select false,
      format('Daily template-publish cap reached (%s/%s). Try again tomorrow.',
             v_count_today, v_daily_cap)::text,
      null::uuid, v_base_energy, v_total_xp, v_level, v_count_today, v_daily_cap;
    return;
  end if;

  v_live_energy := least(
    v_energy_max,
    v_base_energy + floor(extract(epoch from (now() - v_updated_at)) / v_regen_s)::int
  );
  if v_live_energy < v_energy_cost then
    return query select false,
      format('Not enough energy (%s/%s)', v_live_energy, v_energy_cost)::text,
      null::uuid, v_live_energy, v_total_xp, v_level, v_count_today, v_daily_cap;
    return;
  end if;

  insert into public.template_publications(
    producer_id, name, subtitle, bpm, key_root, bars,
    recipe, sound_ids, tags, sounds
  )
  values (
    v_user_id, v_name, v_subtitle, p_bpm, p_key_root, p_bars,
    p_recipe, p_sound_ids, coalesce(p_tags, '{}'::text[]),
    -- Legacy `sounds` jsonb kept populated for backward compat.
    jsonb_build_object('recipe', to_jsonb(p_recipe), 'sound_ids', to_jsonb(p_sound_ids))
  )
  returning id into v_template_id;

  v_new_energy := v_live_energy - v_energy_cost;
  v_new_xp     := v_total_xp + v_xp_gain;
  v_new_level  := greatest(1, floor(v_new_xp / 300.0)::int + 1);

  update public.user_stats
     set energy            = v_new_energy,
         energy_updated_at = now(),
         total_xp          = v_new_xp,
         level             = v_new_level,
         updated_at        = now()
   where user_id = v_user_id;

  insert into public.player_events(user_id, event_type, energy_delta, xp_delta, target_id)
    values (v_user_id, 'publish_template', -v_energy_cost, v_xp_gain, v_template_id::text);

  return query select true,
    format('Published template (%s/%s today)', v_count_today + 1, v_daily_cap)::text,
    v_template_id, v_new_energy, v_new_xp, v_new_level,
    v_count_today + 1, v_daily_cap;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rate_song(p_song_id uuid, p_stars integer)
 RETURNS TABLE(xp_awarded integer, new_xp integer, daily_xp_earned integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_user_id      uuid;
  v_daily_cap    constant int := 40;
  v_xp_gain      constant int := 2;
  v_xp_awarded   int;
  v_new_xp       int;
  v_daily_earned int;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select 0, 0, 0;
    return;
  end if;

  -- Upsert the rating (replace prior stars if any)
  insert into public.song_ratings(user_id, song_id, stars)
    values (v_user_id, p_song_id, p_stars)
    on conflict (user_id, song_id) do update set stars = excluded.stars, created_at = now();

  -- Award XP (capped per day)
  select xp_awarded, new_xp, daily_xp_earned
    into v_xp_awarded, v_new_xp, v_daily_earned
  from public.earn_xp_capped(v_daily_cap, 'rate', v_xp_gain, p_song_id::text);

  -- NEW: check if this rating just tipped the song over the early-ear
  -- threshold. If so, retroactively award qualifying users.
  perform public.award_early_ear_bonus_if_needed(p_song_id, v_user_id);

  return query select v_xp_awarded, v_new_xp, v_daily_earned;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.remove_friend(p_other_user_id uuid)
 RETURNS TABLE(success boolean, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self uuid;
  v_a    uuid;
  v_b    uuid;
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text;
    return;
  end if;

  select user_a, user_b into v_a, v_b from public._ordered_pair(v_self, p_other_user_id);

  delete from public.friend_relationships
   where user_a_id = v_a and user_b_id = v_b;

  if found then
    return query select true, 'Removed'::text;
  else
    return query select false, 'Not friends'::text;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.respond_friend_request(p_other_user_id uuid, p_accept boolean)
 RETURNS TABLE(success boolean, message text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self   uuid;
  v_a      uuid;
  v_b      uuid;
  v_exists record;
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text, null::text;
    return;
  end if;

  select user_a, user_b into v_a, v_b from public._ordered_pair(v_self, p_other_user_id);

  select * into v_exists
  from public.friend_relationships
  where user_a_id = v_a and user_b_id = v_b;

  if not found then
    return query select false, 'No request to respond to'::text, null::text;
    return;
  end if;

  if v_exists.status <> 'pending' then
    return query select false, format('Already %s', v_exists.status)::text, v_exists.status;
    return;
  end if;

  if v_exists.requested_by = v_self then
    return query select false, 'Cannot respond to your own request'::text, 'pending'::text;
    return;
  end if;

  if p_accept then
    update public.friend_relationships
       set status = 'accepted', accepted_at = now()
     where user_a_id = v_a and user_b_id = v_b;
    return query select true, 'Friend request accepted'::text, 'accepted'::text;
  else
    -- Decline = delete the row entirely so the requester can try again later.
    delete from public.friend_relationships
     where user_a_id = v_a and user_b_id = v_b;
    return query select true, 'Friend request declined'::text, null::text;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.send_friend_request(p_other_user_id uuid)
 RETURNS TABLE(success boolean, message text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_self    uuid;
  v_a       uuid;
  v_b       uuid;
  v_exists  record;
begin
  v_self := auth.uid();
  if v_self is null then
    return query select false, 'Not signed in'::text, null::text;
    return;
  end if;
  if v_self = p_other_user_id then
    return query select false, 'Cannot friend yourself'::text, null::text;
    return;
  end if;

  select user_a, user_b into v_a, v_b from public._ordered_pair(v_self, p_other_user_id);

  -- Existing row?
  select * into v_exists
  from public.friend_relationships
  where user_a_id = v_a and user_b_id = v_b;

  if found then
    if v_exists.status = 'accepted' then
      return query select false, 'Already friends'::text, v_exists.status;
      return;
    elsif v_exists.status = 'blocked' then
      return query select false, 'Cannot send (blocked)'::text, v_exists.status;
      return;
    elsif v_exists.status = 'pending' then
      -- If the OTHER user already requested you, auto-accept.
      if v_exists.requested_by <> v_self then
        update public.friend_relationships
           set status = 'accepted', accepted_at = now()
         where user_a_id = v_a and user_b_id = v_b;
        return query select true, 'Friend request accepted'::text, 'accepted'::text;
        return;
      else
        return query select false, 'Request already sent'::text, 'pending'::text;
        return;
      end if;
    end if;
  end if;

  -- Brand new request.
  insert into public.friend_relationships(user_a_id, user_b_id, status, requested_by)
    values (v_a, v_b, 'pending', v_self);

  return query select true, 'Friend request sent'::text, 'pending'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sound_claim_counts(p_sound_ids text[] DEFAULT NULL::text[])
 RETURNS TABLE(sound_id text, claim_count integer, claims_this_week integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  select
    s.id                                                               as sound_id,
    count(us.user_id)::int                                             as claim_count,
    count(us.user_id) filter (
      where us.acquired_at >= (now() - interval '7 days')
    )::int                                                             as claims_this_week
  from public.sound_catalog s
  left join public.user_sounds us
    on us.sound_id = s.id
   and us.source   = 'claimed_from_producer'
  where p_sound_ids is null or s.id = any(p_sound_ids)
  group by s.id;
$function$
;

CREATE OR REPLACE FUNCTION public.spend_energy(p_cost integer, p_event_type text, p_target_id text DEFAULT NULL::text, p_xp integer DEFAULT 0, p_energy_max integer DEFAULT 100, p_regen_interval_seconds integer DEFAULT 300)
 RETURNS TABLE(success boolean, new_energy integer, new_xp integer, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid;
  v_base int;
  v_updated_at timestamptz;
  v_regen_units int;
  v_live int;
  v_new int;
  v_total_xp int;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select false, 0, 0, 'Not authenticated'::text;
    return;
  end if;

  insert into public.user_stats (user_id) values (v_user_id)
    on conflict (user_id) do nothing;

  select energy, energy_updated_at, total_xp
    into v_base, v_updated_at, v_total_xp
    from public.user_stats
    where user_id = v_user_id
    for update;

  v_regen_units := floor(extract(epoch from (now() - v_updated_at)) / p_regen_interval_seconds)::int;
  v_live := least(p_energy_max, v_base + v_regen_units);

  if v_live < p_cost then
    return query select false, v_live, v_total_xp, 'Not enough energy'::text;
    return;
  end if;

  v_new := v_live - p_cost;

  update public.user_stats
    set
      energy             = v_new,
      energy_updated_at  = now(),
      total_xp           = total_xp + greatest(0, p_xp)
    where user_id = v_user_id;

  insert into public.player_events (user_id, event_type, energy_delta, xp_delta, target_id)
  values (v_user_id, p_event_type, -p_cost, p_xp, p_target_id);

  return query select true, v_new, (v_total_xp + p_xp), 'OK'::text;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.weekly_producer_score()
 RETURNS TABLE(producer_id uuid, producer_name text, producer_avatar text, claims_this_week integer, template_usages_this_week integer, score numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  with sound_claims as (
    select
      sc.producer_id              as user_id,
      count(*)::int               as claims_this_week
    from public.sound_acquisitions sa
    join public.sound_catalog      sc on sc.id = sa.sound_id
    where sa.source        = 'claimed_from_producer'
      and sa.created_at   >= (now() - interval '7 days')
      and sc.producer_id   is not null
    group by sc.producer_id
  ),
  recent_publishes as (
    select
      s.template_id::uuid         as template_uuid,
      s.published_publication_id  as pub_id
    from public.songs s
    join public.song_publications sp
      on sp.id = s.published_publication_id
    where s.template_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and sp.published_at >= (now() - interval '7 days')
  ),
  template_usages as (
    select
      tp.producer_id                              as user_id,
      count(distinct rp.pub_id)::int              as template_usages_this_week
    from recent_publishes rp
    join public.template_publications tp
      on tp.id = rp.template_uuid
    group by tp.producer_id
  )
  select
    coalesce(sc.user_id, tu.user_id)               as producer_id,
    p.username                                      as producer_name,
    p.avatar                                        as producer_avatar,
    coalesce(sc.claims_this_week, 0)               as claims_this_week,
    coalesce(tu.template_usages_this_week, 0)      as template_usages_this_week,
    round(
      (coalesce(sc.claims_this_week, 0) * 1.0)
      + (coalesce(tu.template_usages_this_week, 0) * 8.0),
      2
    )                                               as score
  from sound_claims sc
  full outer join template_usages tu on tu.user_id = sc.user_id
  left join public.profiles p
    on p.id = coalesce(sc.user_id, tu.user_id)
  where coalesce(sc.user_id, tu.user_id) is not null
  order by score desc nulls last;
$function$
;
