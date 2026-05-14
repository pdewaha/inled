-- Allow company members to insert placeholder people (auth_user_id NULL) for
-- @handle targets before invite/sign-up. Matches app _createPersonFromHandleInSupabase.

DROP POLICY IF EXISTS inled_people_insert ON people;
CREATE POLICY inled_people_insert ON people
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (
      auth_user_id = auth.uid()
      AND (
        company_id IN (SELECT public.inled_user_company_ids())
        OR EXISTS (
          SELECT 1
          FROM companies c
          WHERE c.id = company_id
            AND c.domain IS NOT NULL
            AND lower(c.domain) = public.inled_jwt_email_domain()
            AND public.inled_jwt_email_domain() <> ''
        )
      )
    )
    OR (
      auth_user_id IS NULL
      AND company_id IN (SELECT public.inled_user_company_ids())
    )
  );
