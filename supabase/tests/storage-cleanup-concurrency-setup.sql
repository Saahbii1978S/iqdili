-- Isolated PostgreSQL concurrency harness for the Storage cleanup lock protocol.
-- Synthetic tables only; this does not apply or alter the production schema.
drop schema if exists cleanup_concurrency cascade;
create schema cleanup_concurrency;
set search_path = cleanup_concurrency, pg_catalog;

create table cleanup_jobs (
  id bigint generated always as identity primary key,
  bucket text not null,
  object_path text not null,
  status text not null check (status in ('pending','processing','staged','completed','dead_letter')),
  lease_token uuid not null
);
create table listings (
  id bigint generated always as identity primary key,
  bucket text not null,
  object_path text not null
);

create function object_lock(p_bucket text, p_path text) returns void
language sql as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_bucket || ':' || p_path, 0)
  );
$$;

create function has_reference(p_bucket text, p_path text) returns boolean
language sql stable as $$
  select exists (
    select 1 from cleanup_concurrency.listings
     where bucket = p_bucket and object_path = p_path
  );
$$;

create function guard_attachment() returns trigger
language plpgsql as $$
begin
  perform cleanup_concurrency.object_lock(new.bucket, new.object_path);
  if exists (
    select 1 from cleanup_concurrency.cleanup_jobs
     where bucket = new.bucket and object_path = new.object_path
       and status in ('pending','processing','completed','dead_letter')
  ) then
    raise exception 'object reserved for cleanup';
  end if;
  return new;
end;
$$;
create trigger listing_attachment_guard
before insert or update of bucket, object_path on listings
for each row execute function guard_attachment();

create function lock_detachment() returns trigger
language plpgsql as $$
begin
  perform cleanup_concurrency.object_lock(old.bucket, old.object_path);
  return old;
end;
$$;
create trigger listing_detachment_lock
before delete or update of bucket, object_path on listings
for each row execute function lock_detachment();

create function reactivate_deferred() returns trigger
language plpgsql as $$
begin
  if not cleanup_concurrency.has_reference(old.bucket, old.object_path) then
    update cleanup_concurrency.cleanup_jobs
       set status = 'pending'
     where bucket = old.bucket and object_path = old.object_path
       and status = 'staged';
  end if;
  return old;
end;
$$;
create trigger listing_detachment_reactivate
after delete or update of bucket, object_path on listings
for each row execute function reactivate_deferred();

create function claim_one() returns text
language plpgsql as $$
declare j cleanup_concurrency.cleanup_jobs%rowtype;
begin
  for j in
    select * from cleanup_concurrency.cleanup_jobs where status='pending' order by id
  loop
    perform cleanup_concurrency.object_lock(j.bucket,j.object_path);
    select * into j from cleanup_concurrency.cleanup_jobs where id=j.id for update;
    if j.status <> 'pending' then continue; end if;
    if cleanup_concurrency.has_reference(j.bucket,j.object_path) then
      update cleanup_concurrency.cleanup_jobs set status='staged' where id=j.id;
      return 'staged';
    end if;
    update cleanup_concurrency.cleanup_jobs set status='processing' where id=j.id;
    return 'processing';
  end loop;
  return 'none';
end;
$$;

create function defer_one(p_id bigint) returns text
language plpgsql as $$
declare j cleanup_concurrency.cleanup_jobs%rowtype;
begin
  select * into j from cleanup_concurrency.cleanup_jobs where id=p_id;
  if not found then return 'missing'; end if;
  perform cleanup_concurrency.object_lock(j.bucket,j.object_path);
  select * into j from cleanup_concurrency.cleanup_jobs where id=p_id for update;
  if j.status <> 'processing' then return 'not_processing'; end if;
  if cleanup_concurrency.has_reference(j.bucket,j.object_path) then
    update cleanup_concurrency.cleanup_jobs set status='staged' where id=p_id;
    return 'staged';
  end if;
  update cleanup_concurrency.cleanup_jobs set status='pending' where id=p_id;
  return 'pending';
end;
$$;
