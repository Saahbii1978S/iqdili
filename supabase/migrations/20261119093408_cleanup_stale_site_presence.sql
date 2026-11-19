-- Delete stale anonymous presence tokens on a schedule, not only when another visitor arrives.
-- This keeps the privacy notice's two-minute retention promise accurate.
DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'cleanup-stale-site-presence'
  ) THEN
    PERFORM cron.schedule(
      'cleanup-stale-site-presence',
      '* * * * *',
      'DELETE FROM private.active_site_presence WHERE last_seen < now() - interval ''2 minutes'';'
    );
  END IF;
END;
$migration$;
