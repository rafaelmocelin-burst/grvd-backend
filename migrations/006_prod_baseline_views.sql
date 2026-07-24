-- Prod baseline (views) — generated from grvd-staging (== production).
-- Order matters: weekly_artist_score reads weekly_song_score.

create or replace view public.my_friends as
 SELECT
        CASE
            WHEN auth.uid() = user_a_id THEN user_b_id
            ELSE user_a_id
        END AS friend_user_id,
    status,
    requested_by,
    requested_at,
    accepted_at
   FROM friend_relationships fr
  WHERE auth.uid() = user_a_id OR auth.uid() = user_b_id;

create or replace view public.song_publication_stats as
 SELECT p.id AS song_id,
    p.title,
    p.artist_id,
    p.artist_name,
    p.artist_avatar,
    p.audio_url,
    p.waveform_url,
    p.bpm,
    p.key_root,
    p.duration_sec,
    p.published_at,
    p.collaborator_ids,
    p.collaborator_names,
    COALESCE(r.rating_count, 0) AS rating_count,
    COALESCE(r.avg_stars, 0::numeric) AS avg_stars,
    COALESCE(e.endorsement_count, 0) AS endorsement_count
   FROM song_publications p
     LEFT JOIN ( SELECT song_ratings.song_id,
            count(*)::integer AS rating_count,
            round(avg(song_ratings.stars), 2) AS avg_stars
           FROM song_ratings
          GROUP BY song_ratings.song_id) r ON r.song_id = p.id
     LEFT JOIN ( SELECT song_endorsements.song_id,
            count(*)::integer AS endorsement_count
           FROM song_endorsements
          GROUP BY song_endorsements.song_id) e ON e.song_id = p.id
  WHERE p.retired_at IS NULL;

create or replace view public.weekly_song_score as
 WITH window_ratings AS (
         SELECT song_ratings.song_id,
            count(*)::integer AS ratings_this_week,
            round(avg(song_ratings.stars), 2) AS avg_stars_this_week
           FROM song_ratings
          WHERE song_ratings.created_at >= (now() - '7 days'::interval)
          GROUP BY song_ratings.song_id
        ), window_endorsements AS (
         SELECT song_endorsements.song_id,
            count(*)::integer AS endorsements_this_week
           FROM song_endorsements
          WHERE song_endorsements.created_at >= (now() - '7 days'::interval)
          GROUP BY song_endorsements.song_id
        )
 SELECT p.id AS song_id,
    p.title,
    p.artist_id,
    p.artist_name,
    p.artist_avatar,
    p.collaborator_ids,
    p.collaborator_names,
    p.audio_url,
    p.bpm,
    p.key_root,
    p.duration_sec,
    p.published_at,
    COALESCE(r.ratings_this_week, 0) AS ratings_this_week,
    COALESCE(r.avg_stars_this_week, 0::numeric) AS avg_stars_this_week,
    COALESCE(e.endorsements_this_week, 0) AS endorsements_this_week,
    COALESCE(r.avg_stars_this_week, 0::numeric) * COALESCE(r.ratings_this_week, 0)::numeric + (COALESCE(e.endorsements_this_week, 0) * 5)::numeric AS score
   FROM song_publications p
     LEFT JOIN window_ratings r ON r.song_id = p.id
     LEFT JOIN window_endorsements e ON e.song_id = p.id
  WHERE p.retired_at IS NULL AND (COALESCE(r.ratings_this_week, 0) > 0 OR COALESCE(e.endorsements_this_week, 0) > 0);

create or replace view public.weekly_tastemaker_score as
 WITH rated AS (
         SELECT song_ratings.user_id,
            count(*)::integer AS ratings_given
           FROM song_ratings
          WHERE song_ratings.created_at >= (now() - '7 days'::interval)
          GROUP BY song_ratings.user_id
        ), endorsed AS (
         SELECT song_endorsements.user_id,
            count(*)::integer AS endorsements_given
           FROM song_endorsements
          WHERE song_endorsements.created_at >= (now() - '7 days'::interval)
          GROUP BY song_endorsements.user_id
        ), combined AS (
         SELECT COALESCE(r.user_id, e.user_id) AS user_id,
            COALESCE(r.ratings_given, 0) AS ratings_given,
            COALESCE(e.endorsements_given, 0) AS endorsements_given
           FROM rated r
             FULL JOIN endorsed e ON e.user_id = r.user_id
        )
 SELECT c.user_id,
    COALESCE(p.username, 'anon'::text) AS username,
    COALESCE(p.avatar, '👤'::text) AS avatar,
    c.ratings_given,
    c.endorsements_given,
    c.ratings_given + c.endorsements_given * 3 AS score
   FROM combined c
     LEFT JOIN profiles p ON p.id = c.user_id;

create or replace view public.weekly_artist_score as
 SELECT artist_id,
    max(artist_name) AS artist_name,
    max(artist_avatar) AS artist_avatar,
    count(*)::integer AS songs_active,
    sum(ratings_this_week)::integer AS ratings_this_week,
    sum(endorsements_this_week)::integer AS endorsements_this_week,
    round(sum(score), 2) AS score
   FROM weekly_song_score s
  GROUP BY artist_id;
