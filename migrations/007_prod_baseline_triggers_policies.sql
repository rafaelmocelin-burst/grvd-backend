-- Prod baseline (triggers + RLS policies) — generated from grvd-staging (== production).
-- Policies replaced from 001: coop_sessions' public-read/host-insert/host-guest-update
-- became a single participant-read (mutations go through security-definer RPCs).

-- Triggers
CREATE TRIGGER trg_notify_on_coop_invite AFTER INSERT ON public.coop_sessions FOR EACH ROW EXECUTE FUNCTION notify_on_coop_invite();
CREATE TRIGGER trg_notify_on_endorsement AFTER INSERT ON public.song_endorsements FOR EACH ROW EXECUTE FUNCTION notify_on_endorsement();
CREATE TRIGGER trg_notify_on_friend_accept AFTER UPDATE ON public.friend_relationships FOR EACH ROW EXECUTE FUNCTION notify_on_friend_accept();
CREATE TRIGGER trg_notify_on_friend_request AFTER INSERT ON public.friend_relationships FOR EACH ROW EXECUTE FUNCTION notify_on_friend_request();
CREATE TRIGGER trg_notify_on_player_event AFTER INSERT ON public.player_events FOR EACH ROW EXECUTE FUNCTION notify_on_player_event();
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();
CREATE TRIGGER trg_grant_starter_sounds AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION grant_starter_sounds_to_new_user();

-- Policies
create policy "coop: participant read" on public.coop_sessions as permissive for select to authenticated using (((auth.uid() = host_id) OR (auth.uid() = guest_id) OR (auth.uid() = invited_user_id)));
create policy "crib_visits_insert_own" on public.crib_visits as permissive for insert to public with check ((auth.uid() = visitor_id));
create policy "crib_visits_select_participant" on public.crib_visits as permissive for select to public using (((auth.uid() = visitor_id) OR (auth.uid() = host_id)));
create policy "fan_relationships_delete_own" on public.fan_relationships as permissive for delete to authenticated using ((auth.uid() = fan_id));
create policy "fan_relationships_insert_own" on public.fan_relationships as permissive for insert to public with check ((auth.uid() = fan_id));
create policy "fan_relationships_select_all" on public.fan_relationships as permissive for select to authenticated using (true);
create policy "friend_rel: participant read" on public.friend_relationships as permissive for select to authenticated using (((auth.uid() = user_a_id) OR (auth.uid() = user_b_id)));
create policy "game_config: public read" on public.game_config as permissive for select to public using (true);
create policy "notifications_delete_own" on public.notifications as permissive for delete to authenticated using ((( SELECT auth.uid() AS uid) = user_id));
create policy "notifications_select_own" on public.notifications as permissive for select to authenticated using ((( SELECT auth.uid() AS uid) = user_id));
create policy "notifications_update_own" on public.notifications as permissive for update to authenticated using ((( SELECT auth.uid() AS uid) = user_id)) with check ((( SELECT auth.uid() AS uid) = user_id));
create policy "player_events_select_own" on public.player_events as permissive for select to public using ((auth.uid() = user_id));
create policy "profiles: own read" on public.profiles as permissive for select to public using ((auth.uid() = id));
create policy "profiles: own update" on public.profiles as permissive for update to public using ((auth.uid() = id));
create policy "profiles: public read" on public.profiles as permissive for select to public using (true);
create policy "song_bonus_events: public read" on public.song_bonus_events as permissive for select to public using (true);
create policy "song_endorsements_insert_own" on public.song_endorsements as permissive for insert to public with check ((auth.uid() = user_id));
create policy "song_endorsements_select_all" on public.song_endorsements as permissive for select to authenticated using (true);
create policy "song_publications_insert_own" on public.song_publications as permissive for insert to public with check ((auth.uid() = artist_id));
create policy "song_publications_select_active" on public.song_publications as permissive for select to public using ((retired_at IS NULL));
create policy "song_publications_update_own" on public.song_publications as permissive for update to public using ((auth.uid() = artist_id));
create policy "song_ratings_select_all" on public.song_ratings as permissive for select to authenticated using (true);
create policy "song_ratings_update_own" on public.song_ratings as permissive for update to public using ((auth.uid() = user_id));
create policy "song_ratings_upsert_own" on public.song_ratings as permissive for insert to public with check ((auth.uid() = user_id));
create policy "songs: own all" on public.songs as permissive for all to public using ((auth.uid() = user_id));
create policy "songs: public read" on public.songs as permissive for select to public using (true);
create policy "sound_acquisitions: own read" on public.sound_acquisitions as permissive for select to public using ((( SELECT auth.uid() AS uid) = user_id));
create policy "sound_bonus_events: public read" on public.sound_bonus_events as permissive for select to public using (true);
create policy "sound_catalog: public read" on public.sound_catalog as permissive for select to anon, authenticated using (true);
create policy "tam: own all" on public.tamagotchi_state as permissive for all to public using ((auth.uid() = user_id));
create policy "template_publications: public read" on public.template_publications as permissive for select to public using ((retired_at IS NULL));
create policy "template_publications_insert_own" on public.template_publications as permissive for insert to public with check ((auth.uid() = producer_id));
create policy "template_publications_select_all" on public.template_publications as permissive for select to public using (true);
create policy "user_sounds: own insert" on public.user_sounds as permissive for insert to authenticated with check ((( SELECT auth.uid() AS uid) = user_id));
create policy "user_sounds: own read" on public.user_sounds as permissive for select to authenticated using ((( SELECT auth.uid() AS uid) = user_id));
create policy "stats: own all" on public.user_stats as permissive for all to public using ((auth.uid() = user_id));
