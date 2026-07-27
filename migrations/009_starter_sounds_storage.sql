-- Starter sound audio moved into Supabase Storage.
--
-- Why: sound_catalog recorded audio locations as paths relative to the web
-- app's own server ('/sounds/drums/drums_150.wav'). The web client resolves
-- those against itself, but the UE client has no such origin and cannot fetch
-- them — so the two clients could not have played the same sounds. Storage is
-- reachable by both, and is where the sound catalog was always headed
-- (SOUND_ECONOMY_PLAN section 6).
--
-- Applied to grvd-staging 2026-07-27 together with an upload of the 13 WAVs
-- from the web repo's public/sounds/, preserving their folder structure
-- (808/, drums/, hihat/, samples/). Verified: anonymous GET returns the
-- byte-identical file with content-type audio/wav.
--
-- NOT yet applied to production. Doing so is safe for the web client (an
-- absolute URL works anywhere a relative one did) but should be paired with
-- uploading the same files to the production project's bucket.

insert into storage.buckets (id, name, public)
values ('starter-sounds', 'starter-sounds', true)
on conflict (id) do nothing;

do $$ begin
begin
  create policy "starter-sounds: public read" on storage.objects
    for select to public using (bucket_id = 'starter-sounds');
exception when duplicate_object then null; end;
begin
  create policy "starter-sounds: authenticated write" on storage.objects
    for insert to authenticated with check (bucket_id = 'starter-sounds');
exception when duplicate_object then null; end;
begin
  create policy "starter-sounds: authenticated update" on storage.objects
    for update to authenticated using (bucket_id = 'starter-sounds');
exception when duplicate_object then null; end;
end $$;

-- Rewrite the 13 file-backed starter rows to absolute Storage URLs.
-- Replace the project ref below when applying to a different project.
update public.sound_catalog
set audio_url = 'https://erqiyxakfdoemeskpygy.supabase.co/storage/v1/object/public/starter-sounds/'
                || replace(audio_url, '/sounds/', '')
where audio_url like '/sounds/%';
