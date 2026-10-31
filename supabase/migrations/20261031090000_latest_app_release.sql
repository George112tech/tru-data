-- Newest Android app in the app-updates bucket, for the website's download
-- buttons.
--
-- The page used to list the bucket from the browser, but that request had no
-- API key and the bucket has no listing policy, so it always failed and every
-- download fell back to trudata-v1.1.3.apk. This returns only the newest
-- trudata-vX.Y.Z.apk (name, version, size), nothing else in the bucket.
-- Uploading a new trudata-vX.Y.Z.apk is all it takes to publish an update.
--
-- Run AFTER 20261030200000_realtime_updates.sql.

create or replace function public.latest_app_release()
returns jsonb
language sql
stable
security definer
set search_path = public, storage
as $$
  select jsonb_build_object(
    'name', o.name,
    'version', substring(o.name from '^trudata-v([0-9]+\.[0-9]+\.[0-9]+)\.apk$'),
    'size', (o.metadata ->> 'size')::bigint,
    'uploaded_at', o.created_at)
  from storage.objects o
  where o.bucket_id = 'app-updates'
    and o.name ~ '^trudata-v[0-9]+\.[0-9]+\.[0-9]+\.apk$'
  order by string_to_array(substring(o.name from '^trudata-v([0-9.]+)\.apk$'), '.')::int[] desc
  limit 1;
$$;

revoke execute on function public.latest_app_release() from public;
grant execute on function public.latest_app_release() to anon, authenticated;
