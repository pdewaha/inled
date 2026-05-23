-- Items waiting for an invited placeholder person (expectations + talking points).

CREATE OR REPLACE FUNCTION public.inled_invite_pending_items_for_person(
  p_company_id uuid,
  p_person_id uuid
)
RETURNS TABLE (
  item_kind text,
  expectation_id uuid,
  summary text,
  sender_handle text,
  status_note text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    CASE
      WHEN e.expectation_type = 1 THEN 'talking_point'
      ELSE 'expectation'
    END AS item_kind,
    e.id AS expectation_id,
    coalesce(nullif(trim(e.summary), ''), '(no summary)') AS summary,
    coalesce(nullif(trim(sender.handle), ''), 'someone') AS sender_handle,
    CASE
      WHEN e.expectation_type = 0 AND e.expectation_status = 0 THEN 'Pending your acceptance'
      WHEN e.expectation_type = 0 AND e.expectation_status = 1 THEN 'Accepted — awaiting progress'
      WHEN e.expectation_type = 1 THEN 'Talking point for you'
      ELSE 'Open'
    END AS status_note
  FROM expectations e
  LEFT JOIN people sender
    ON sender.company_id = e.company_id
   AND sender.auth_user_id = e.writer_user_id
  WHERE e.company_id = p_company_id
    AND e.expectation_status NOT IN (2, 3)
    AND (
      e.target_person_id = p_person_id
      OR EXISTS (
        SELECT 1
        FROM expectation_mentions m
        WHERE m.expectation_id = e.id
          AND m.mentioned_person_id = p_person_id
      )
    )
    AND (
      (e.expectation_type = 0 AND e.expectation_visibility = 1)
      OR (e.expectation_type = 1 AND e.expectation_visibility IN (0, 1))
    )
  ORDER BY e.updated_at DESC NULLS LAST, e.created_at DESC
  LIMIT 30;
$$;

REVOKE ALL ON FUNCTION public.inled_invite_pending_items_for_person(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_invite_pending_items_for_person(uuid, uuid) TO service_role;
