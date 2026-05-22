-- Morning digest: open expectations that need attention (matches app Home Urgent / outbox warnings).
-- expectation_type 0 only; talking points excluded.
-- Unhealthy when still open (not finished/abandoned) AND:
--   pending (not accepted), OR health unknown (no progress), OR at risk, OR off track.
-- Digest also lists "No deadline set" as an issue when deadline_at is null / TBD.

CREATE OR REPLACE FUNCTION public.inled_expectation_unhealthy_issues(
  p_status integer,
  p_health integer,
  p_deadline_at timestamptz,
  p_deadline_label text
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT array_remove(ARRAY[
    CASE WHEN p_status = 0 THEN 'Not accepted yet' END,
    CASE WHEN p_health = 0 THEN 'No progress defined' END,
    CASE WHEN p_health = 2 THEN 'At risk' END,
    CASE WHEN p_health = 3 THEN 'Off track' END,
    CASE
      WHEN p_deadline_at IS NULL
        AND (
          p_deadline_label IS NULL
          OR trim(p_deadline_label) = ''
          OR upper(trim(p_deadline_label)) = 'TBD'
        )
      THEN 'No deadline set'
    END
  ]::text[], NULL);
$$;

CREATE OR REPLACE FUNCTION public.inled_expectation_is_unhealthy_for_digest(
  p_status integer,
  p_health integer
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_status NOT IN (2, 3)
    AND (
      p_status = 0
      OR p_health IN (0, 2, 3)
    );
$$;

-- One row per (recipient, expectation) for the edge function to group and email.
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
    CASE
      WHEN recipient.auth_user_id IS NOT NULL
        AND recipient.auth_user_id = b.writer_user_id
      THEN 'author'
      ELSE 'receiver'
    END,
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
     (recipient.auth_user_id = b.writer_user_id)
     OR (
       b.expectation_visibility = 1
       AND (
         recipient.id = b.target_person_id
         OR EXISTS (
           SELECT 1
           FROM expectation_mentions m
           WHERE m.expectation_id = b.id
             AND m.mentioned_person_id = recipient.id
         )
       )
     )
   )
  ORDER BY recipient.id, b.id, b.responsible_updated_at DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION public.inled_expectation_unhealthy_issues(integer, integer, timestamptz, text)
  TO service_role, supabase_admin, postgres;
GRANT EXECUTE ON FUNCTION public.inled_expectation_is_unhealthy_for_digest(integer, integer)
  TO service_role, supabase_admin, postgres;
GRANT EXECUTE ON FUNCTION public.inled_morning_unhealthy_digest_rows()
  TO service_role, supabase_admin, postgres;

COMMENT ON FUNCTION public.inled_morning_unhealthy_digest_rows() IS
  'Rows for morning unhealthy-expectations digest emails (one row per recipient × expectation).';
