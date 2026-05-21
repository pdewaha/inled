-- Immediate SMTP dispatch when a row is inserted into activity_email_outbox.
-- Requires pg_net + DB settings (run scripts/setup-activity-email-immediate-dispatch.sh on beacon).

CREATE OR REPLACE FUNCTION inled_dispatch_activity_email_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  fn_url text;
  sr_key text;
BEGIN
  BEGIN
    fn_url := current_setting('app.activity_email_function_url', true);
    sr_key := current_setting('app.service_role_key', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;

  IF fn_url IS NULL OR fn_url = '' OR sr_key IS NULL OR sr_key = '' THEN
    RAISE WARNING
      'activity_email_outbox %: immediate dispatch not configured (app.activity_email_function_url / app.service_role_key). Row stays pending.',
      NEW.id;
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := fn_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || sr_key,
      'apikey', sr_key
    ),
    body := jsonb_build_object('outbox_id', NEW.id::text),
    timeout_milliseconds := 300000
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'activity_email_outbox %: pg_net dispatch failed: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION inled_dispatch_activity_email_outbox() IS
  'POST send-activity-email with {outbox_id} on each pending INSERT. Configure via setup-activity-email-immediate-dispatch.sh.';
