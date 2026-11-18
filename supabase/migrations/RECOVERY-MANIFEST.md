# Supabase migration recovery manifest

**Project:** أحلى توانسة / AHLA TOUNSA  
**Supabase project:** iqdili  
**Captured:** 2026-11-15  
**Purpose:** Recovery inventory only. This file is not executable SQL and does not recreate the database.

The following migration versions are recorded as applied in the live Supabase project:

| Version | Migration name |
|---|---|
| 20261102161723 | allow_public_service_submissions |
| 20261102161831 | publish_services_without_phone |
| 20261104174400 | protect_legacy_contact_tables |
| 20261105130220 | lock_down_unused_legacy_listing_tables |
| 20261105142326 | add_opt_in_public_contact_for_listings |
| 20261105175224 | market_product_images |
| 20261105180017 | add_images_to_all_listing_sections |
| 20261106194948 | require_turnstile_for_public_posts |
| 20261107205238 | add_ask_iqdili_hourly_rate_limit |
| 20261107205310 | cleanup_old_ask_rate_limit_entries |
| 20261107205428 | create_private_pending_images_bucket |
| 20261107210011 | add_pending_image_upload_rate_limit |
| 20261107210508 | restrict_public_listing_image_uploads |
| 20261107214706 | revoke_excess_admins_table_privileges |
| 20261107222507 | add_listing_expiry_and_cleanup_scheduler |
| 20261107222948 | add_optional_member_ownership |
| 20261107223417 | grant_admin_service_role_delete_posts |
| 20261108084317 | add_owner_moderator_roles_and_audit |
| 20261108084428 | limit_moderator_updates_to_post_status |
| 20261108084454 | add_owner_review_audit_reader |
| 20261108084530 | route_all_status_changes_through_authorized_edge_function |
| 20261108153947 | add_admin_audit_foreign_key_indexes |
| 20261108172215 | revoke_unneeded_table_admin_privileges |
| 20261108172408 | secure_site_visit_identity_from_request_ip |
| 20261108172416 | disable_legacy_client_supplied_visitor_ids |
| 20261114175919 | admin_notification_events |
| 20261114194958 | raise_ask_rate_limit_to_15_per_hour |
| 20261114202111 | respect_service_contact_privacy |

## Important recovery limitation

The live database reports these 28 migrations as applied, but the corresponding SQL migration files were not found in the GitHub `main` branch at the expected `supabase/migrations/` paths during the read-only audit.

This manifest preserves version numbers and names only. It does **not** contain the SQL statements, data, secrets, Auth users, Storage objects, or scheduled-job definitions. It is therefore not a complete or restorable database backup.

## Required next recovery work

1. Locate the original SQL migration files or obtain an authorised database schema dump.
2. Preserve table definitions, constraints, indexes, triggers, RLS policies, grants, functions, storage policies, and scheduler definitions.
3. Keep data backups separate from schema backups and verify a restore in an isolated project.
4. Do not replay reconstructed migrations against the live project without a reviewed migration plan.

No live database changes were made while preparing this manifest.
