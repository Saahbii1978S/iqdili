-- Durable Storage cleanup queue for post/account deletion workflows.
-- Candidate migration only: do not apply to production without owner approval.
create table if not exists public.storage_cleanup_jobs (
  id bigint generated always as identity primary key,
  bucket text not null check (bucket in ('listing-images','market-images','pending-images')),
  object_path text not null check (
    length(object_path) between 1 and 220
    and object_path !~ '(^|/)\.\.(/|$)'
    and object_path !~ '//'
  ),
  status text not null default 'staged' check (status in ('staged','pending','processing','completed','dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  lease_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (bucket, object_path)
);
create index if not exists storage_cleanup_jobs_pending_idx
  on public.storage_cleanup_jobs (created_at, id)
  where status in ('pending','processing');
alter table public.storage_cleanup_jobs enable row level security;
revoke all on table public.storage_cleanup_jobs from anon, authenticated;
grant all on table public.storage_cleanup_jobs to service_role;
grant usage, select on sequence public.storage_cleanup_jobs_id_seq to service_role;

-- Claim jobs atomically so concurrent workers never process the same object at once.
create or replace function public.claim_storage_cleanup_jobs(p_limit integer default 20)
returns table(id bigint, bucket text, object_path text, attempts integer)
language sql
security invoker
set search_path = ''
as $$
  with exhausted as (
    update public.storage_cleanup_jobs j
       set status = 'dead_letter',
           lease_until = null,
           updated_at = pg_catalog.now(),
           last_error = coalesce(j.last_error, 'Maximum retry count reached')
     where j.attempts >= 8
       and (j.status = 'pending' or (j.status = 'processing' and j.lease_until < pg_catalog.now()))
    returning j.id
  ),
  candidates as (
    select j.id
      from public.storage_cleanup_jobs j
     where j.attempts < 8
       and (j.status = 'pending' or (j.status = 'processing' and j.lease_until < pg_catalog.now()))
     order by j.created_at, j.id
     for update skip locked
     limit least(greatest(coalesce(p_limit, 20), 1), 25)
  ),
  claimed as (
    update public.storage_cleanup_jobs j
       set status = 'processing',
           attempts = j.attempts + 1,
           lease_until = pg_catalog.now() + interval '5 minutes',
           updated_at = pg_catalog.now()
      from candidates c
     where j.id = c.id
    returning j.id, j.bucket, j.object_path, j.attempts
  )
  select c.id, c.bucket, c.object_path, c.attempts from claimed c;
$$;

revoke all on function public.claim_storage_cleanup_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup_jobs(integer) to service_role;

-- Activate only the exact paths whose listing-row deletion succeeded.
create or replace function public.activate_storage_cleanup_jobs(p_jobs jsonb)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  activated_count integer;
  requested_count integer;
begin
  if pg_catalog.jsonb_typeof(p_jobs) <> 'array'
     or pg_catalog.jsonb_array_length(p_jobs) > 500 then
    raise exception 'Invalid cleanup job batch';
  end if;

  select count(*) into requested_count
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text);

  update public.storage_cleanup_jobs q
     set status = 'pending',
         updated_at = pg_catalog.now()
    from pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
   where q.bucket = x.bucket
     and q.object_path = x.object_path
     and q.status = 'staged';

  select count(*) into activated_count
    from public.storage_cleanup_jobs q
    join pg_catalog.jsonb_to_recordset(p_jobs) as x(bucket text, object_path text)
      on q.bucket = x.bucket and q.object_path = x.object_path
   where q.status in ('pending','processing','completed','dead_letter');

  if activated_count <> requested_count then
    return 0;
  end if;
  return activated_count;
end;
$$;

revoke all on function public.activate_storage_cleanup_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.activate_storage_cleanup_jobs(jsonb) to service_role;
