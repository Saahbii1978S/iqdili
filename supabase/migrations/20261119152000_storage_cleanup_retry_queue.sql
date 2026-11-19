-- Durable retry queue for Storage objects left behind after post/account cleanup.
-- This migration is intentionally additive: it does not touch existing posts or objects.

create table if not exists public.storage_cleanup_queue (
  id bigint generated always as identity primary key,
  bucket_id text not null,
  object_path text not null,
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint storage_cleanup_queue_bucket_check
    check (bucket_id in ('listing-images', 'market-images', 'pending-images')),
  constraint storage_cleanup_queue_path_check
    check (
      length(object_path) between 1 and 220
      and object_path !~ '(^/|\.\.|//)'
      and object_path ~ '^[A-Za-z0-9_./-]+\.(jpg|jpeg|png|webp)$'
      and (
        (bucket_id = 'listing-images' and
          (object_path like 'services/%' or object_path like 'jobs/%' or object_path like 'realty/%'))
        or (bucket_id = 'market-images' and object_path like 'market/%')
        or (bucket_id = 'pending-images' and
          (object_path like 'services/%' or object_path like 'jobs/%' or object_path like 'realty/%' or object_path like 'market/%'))
      )
    ),
  constraint storage_cleanup_queue_object_unique unique (bucket_id, object_path)
);

create index if not exists storage_cleanup_queue_due_idx
  on public.storage_cleanup_queue (next_attempt_at, id);

alter table public.storage_cleanup_queue enable row level security;
revoke all on table public.storage_cleanup_queue from public, anon, authenticated;
grant select, insert, update, delete on table public.storage_cleanup_queue to service_role;
grant usage, select on sequence public.storage_cleanup_queue_id_seq to service_role;

comment on table public.storage_cleanup_queue is
  'Private-to-service-role retry queue for validated Storage object paths; contains no post content or user identity.';
