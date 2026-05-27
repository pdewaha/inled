-- Domain join: invited / @mention placeholders have email set but auth_user_id NULL.
-- Previous RLS hid those rows from the joiner (not in company yet), so the app tried
-- INSERT and hit uq_people_company_email. Allow SELECT + UPDATE to claim own row.

CREATE OR REPLACE FUNCTION public.inled_jwt_email_normalized()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT lower(trim(coalesce(nullif(trim(auth.jwt() ->> 'email'), ''), '')));
$$;

REVOKE ALL ON FUNCTION public.inled_jwt_email_normalized() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_jwt_email_normalized() TO authenticated;

DROP POLICY IF EXISTS inled_people_select ON people;
CREATE POLICY inled_people_select ON people
  FOR SELECT
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    OR auth_user_id = auth.uid()
    OR (
      auth_user_id IS NULL
      AND nullif(trim(lower(coalesce(people.email, ''))), '') =
          nullif(public.inled_jwt_email_normalized(), '')
      AND public.inled_jwt_email_normalized() <> ''
      AND EXISTS (
        SELECT 1
        FROM companies c
        WHERE c.id = people.company_id
          AND c.domain IS NOT NULL
          AND lower(c.domain) = public.inled_jwt_email_domain()
          AND public.inled_jwt_email_domain() <> ''
      )
    )
  );

DROP POLICY IF EXISTS inled_people_update ON people;
CREATE POLICY inled_people_update ON people
  FOR UPDATE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    OR (
      auth_user_id IS NULL
      AND nullif(trim(lower(coalesce(people.email, ''))), '') =
          nullif(public.inled_jwt_email_normalized(), '')
      AND public.inled_jwt_email_normalized() <> ''
      AND EXISTS (
        SELECT 1
        FROM companies c
        WHERE c.id = people.company_id
          AND c.domain IS NOT NULL
          AND lower(c.domain) = public.inled_jwt_email_domain()
          AND public.inled_jwt_email_domain() <> ''
      )
    )
  )
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    OR (
      auth_user_id = auth.uid()
      AND EXISTS (
        SELECT 1
        FROM companies c
        WHERE c.id = people.company_id
          AND c.domain IS NOT NULL
          AND lower(c.domain) = public.inled_jwt_email_domain()
          AND public.inled_jwt_email_domain() <> ''
      )
    )
  );
