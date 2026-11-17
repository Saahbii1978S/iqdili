\set ON_ERROR_STOP on

-- Synthetic Storage policy harness only.
-- These policies mirror the two read policies verified in production catalog
-- metadata. This does not connect to, export from, or modify production Storage.

create schema storage;
create table storage.objects (
  id uuid primary key,
  bucket_id text not null,
  name text not null
);

alter table storage.objects enable row level security;

grant usage on schema storage to anon, authenticated;
grant select on storage.objects to anon, authenticated;

create policy "Market images public read"
  on storage.objects
  for select
  to public
  using (bucket_id = 'market-images');

create policy "Public read listing images"
  on storage.objects
  for select
  to public
  using (bucket_id = 'listing-images');

-- Synthetic fixtures only; no production object paths or names are used.
insert into storage.objects (id, bucket_id, name) values
  ('10000000-0000-4000-8000-000000000001', 'listing-images', 'fixture-listing.webp'),
  ('10000000-0000-4000-8000-000000000002', 'market-images', 'fixture-market.webp'),
  ('10000000-0000-4000-8000-000000000003', 'pending-images', 'fixture-pending.webp');

set role anon;
do $storage_anon_read$
declare
  listing_count integer;
  market_count integer;
  pending_count integer;
begin
  select count(*) into listing_count
    from storage.objects where bucket_id = 'listing-images';
  select count(*) into market_count
    from storage.objects where bucket_id = 'market-images';
  select count(*) into pending_count
    from storage.objects where bucket_id = 'pending-images';

  if listing_count <> 1 then
    raise exception 'Expected anon to read exactly one listing-images fixture, found %', listing_count;
  end if;
  if market_count <> 1 then
    raise exception 'Expected anon to read exactly one market-images fixture, found %', market_count;
  end if;
  if pending_count <> 0 then
    raise exception 'Private pending-images bucket leaked % rows to anon', pending_count;
  end if;
end;
$storage_anon_read$;
reset role;

set role authenticated;
do $storage_authenticated_read$
declare
  pending_count integer;
begin
  select count(*) into pending_count
    from storage.objects where bucket_id = 'pending-images';
  if pending_count <> 0 then
    raise exception 'Private pending-images bucket leaked % rows to authenticated', pending_count;
  end if;
end;
$storage_authenticated_read$;
reset role;

-- Authenticated clients may also read the two public buckets, but not pending images.
set role authenticated;
do $storage_authenticated_public_read$
declare
  listing_count integer;
  market_count integer;
begin
  select count(*) into listing_count
    from storage.objects where bucket_id = 'listing-images';
  select count(*) into market_count
    from storage.objects where bucket_id = 'market-images';

  if listing_count <> 1 or market_count <> 1 then
    raise exception 'Authenticated public-bucket read mismatch: listing %, market %',
      listing_count, market_count;
  end if;
end;
$storage_authenticated_public_read$;
reset role;

-- Client roles must not receive direct object mutation privileges.
do $storage_write_acl$
begin
  if has_table_privilege('anon', 'storage.objects', 'INSERT')
     or has_table_privilege('anon', 'storage.objects', 'UPDATE')
     or has_table_privilege('anon', 'storage.objects', 'DELETE') then
    raise exception 'anon unexpectedly has direct Storage object write privileges';
  end if;

  if has_table_privilege('authenticated', 'storage.objects', 'INSERT')
     or has_table_privilege('authenticated', 'storage.objects', 'UPDATE')
     or has_table_privilege('authenticated', 'storage.objects', 'DELETE') then
    raise exception 'authenticated unexpectedly has direct Storage object write privileges';
  end if;
end;
$storage_write_acl$;

-- Ensure this fixture contains only the two intended SELECT policies.
do $storage_policy_shape$
declare
  policy_count integer;
  non_select_count integer;
begin
  select count(*) into policy_count
    from pg_catalog.pg_policies
   where schemaname = 'storage' and tablename = 'objects';

  select count(*) into non_select_count
    from pg_catalog.pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and cmd <> 'SELECT';

  if policy_count <> 2 or non_select_count <> 0 then
    raise exception 'Expected exactly two SELECT-only Storage policies; found % policies and % non-SELECT policies',
      policy_count, non_select_count;
  end if;
end;
$storage_policy_shape$;

drop schema storage cascade;
