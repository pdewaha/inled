-- Config table for immediate outbox dispatch (self-hosted Postgres often blocks ALTER DATABASE SET app.*).

CREATE TABLE IF NOT EXISTS inled_activity_email_dispatch_config (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  function_url text NOT NULL,
  service_role_key text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE inled_activity_email_dispatch_config ENABLE ROW LEVEL SECURITY;
-- No policies: only SECURITY DEFINER trigger reads/writes; setup script uses postgres.

REVOKE ALL ON inled_activity_email_dispatch_config FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON inled_activity_email_dispatch_config TO postgres;
GRANT SELECT, INSERT, UPDATE, DELETE ON inled_activity_email_dispatch_config TO supabase_admin;

-- Dashboard SQL often creates this function as supabase_admin; DROP then CREATE avoids "must be owner".
DROP FUNCTION IF EXISTS public.inled_dispatch_activity_email_outbox() CASCADE;

CREATE FUNCTION public.inled_dispatch_activity_email_outbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  fn_url text;
  sr_key text;
BEGIN
  SELECT c.function_url, c.service_role_key
  INTO fn_url, sr_key
  FROM inled_activity_email_dispatch_config c
  WHERE c.id = 1;

  IF fn_url IS NULL OR fn_url = '' OR sr_key IS NULL OR sr_key = '' THEN
    BEGIN
      fn_url := current_setting('app.activity_email_function_url', true);
      sr_key := current_setting('app.service_role_key', true);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  IF fn_url IS NULL OR fn_url = '' OR sr_key IS NULL OR sr_key = '' THEN
    RAISE WARNING
      'activity_email_outbox %: immediate dispatch not configured. Run setup-activity-email-immediate-dispatch.sh.',
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

ALTER FUNCTION public.inled_dispatch_activity_email_outbox() OWNER TO postgres;

COMMENT ON TABLE inled_activity_email_dispatch_config IS
  'Singleton row (id=1): Kong URL + service role JWT for pg_net dispatch on activity_email_outbox INSERT.';
