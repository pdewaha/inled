-- Morning digest: only receivers (not authors) for published expectations.
-- Receivers = primary (target_person_id) + all co-receivers (expectation_mentions).

DROP FUNCTION IF EXISTS public.inled_morning_unhealthy_digest_rows();

CREATE OR REPLACE FUNCTION public.inled_morning_unhealthy_digest_rows()
RETURNS TABLE (
  recipient_person_id uuid,
  recipient_email text,
  recipient_name text,
  company_id uuid,
  expectation_id uuid,
  summary text,
  expectation_status integer,
  expectation_health integer,
  deadline_label text,
  deadline_at timestamptz,
  involvement text,
  sender_handle text,
  sender_label text,
  issues text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT e.*
    FROM expectations e
    WHERE e.expectation_type = 0
      AND e.expectation_visibility = 1
      AND public.inled_expectation_is_unhealthy_for_digest(
        e.expectation_status,
        e.expectation_health
      )
  )
  SELECT DISTINCT ON (recipient.id, b.id)
    recipient.id,
    trim(recipient.email),
    trim(recipient.display_name),
    b.company_id,
    b.id,
    b.summary,
    b.expectation_status,
    b.expectation_health,
    b.deadline_label,
    b.deadline_at,
    'receiver'::text,
    coalesce(nullif(trim(sender.handle), ''), 'someone'),
    coalesce(nullif(trim(sender.display_name), ''), nullif(trim(sender.handle), ''), 'Someone'),
    public.inled_expectation_unhealthy_issues(
      b.expectation_status,
      b.expectation_health,
      b.deadline_at,
      b.deadline_label
    )
  FROM base b
  JOIN people recipient
    ON recipient.company_id = b.company_id
   AND recipient.auth_user_id IS NOT NULL
   AND trim(coalesce(recipient.email, '')) <> ''
   AND (
     recipient.id = b.target_person_id
     OR EXISTS (
       SELECT 1
       FROM expectation_mentions m
       WHERE m.expectation_id = b.id
         AND m.mentioned_person_id = recipient.id
     )
   )
  LEFT JOIN people sender
    ON sender.company_id = b.company_id
   AND sender.auth_user_id = b.writer_user_id
  ORDER BY recipient.id, b.id, b.responsible_updated_at DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION public.inled_morning_unhealthy_digest_rows()
  TO service_role, supabase_admin, postgres;

COMMENT ON FUNCTION public.inled_morning_unhealthy_digest_rows() IS
  'Morning digest: one row per receiver (primary + co-@mentions) × unhealthy published expectation. Authors excluded.';
