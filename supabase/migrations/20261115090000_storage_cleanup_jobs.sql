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
  status text not null default 'staged' check (status in ('staged','pending','completed')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (bucket, object_path)
);
create index if not exists storage_cleanup_jobs_pending_idx
  on public.storage_cleanup_jobs (created_at, id)
  where status = 'pending';
alter table public.storage_cleanup_jobs enable row level security;
revoke all on table public.storage_cleanup_jobs from anon, authenticated;
grant all on table public.storage_cleanup_jobs to service_role;
grant usage, select on sequence public.storage_cleanup_jobs_id_seq to service_role;
