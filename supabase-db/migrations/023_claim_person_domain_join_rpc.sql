-- Reliable domain join: claim placeholder or insert person without depending on
-- client-visible RLS (SELECT could still hide rows in some setups).
-- SET row_security = off: SECURITY DEFINER does not bypass RLS unless the owner
-- is table owner / BYPASSRLS; without this the UPDATE can match 0 rows and INSERT hits uq_people_company_email.

CREATE OR REPLACE FUNCTION public.inled_claim_person_for_domain_join(
  p_company_id uuid,
  p_title text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_uid uuid;
  v_email text;
  v_domain text;
  v_company_domain text;
  v_local text;
  v_display text;
  v_handle text;
  pid uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  v_email := lower(trim(coalesce(nullif(trim(auth.jwt() ->> 'email'), ''), '')));
  IF v_email = '' OR position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'jwt has no email' USING ERRCODE = '28000';
  END IF;

  v_domain := lower(split_part(v_email, '@', 2));

  SELECT lower(trim(c.domain))
  INTO v_company_domain
  FROM companies c
  WHERE c.id = p_company_id;

  IF v_company_domain IS NULL OR v_company_domain = '' THEN
    RAISE EXCEPTION 'company has no domain' USING ERRCODE = '28000';
  END IF;

  IF v_company_domain <> v_domain THEN
    RAISE EXCEPTION 'email domain does not match company domain' USING ERRCODE = '28000';
  END IF;

  UPDATE people
  SET
    auth_user_id = v_uid,
    updated_at = now(),
    title = COALESCE(NULLIF(trim(p_title), ''), title)
  WHERE company_id = p_company_id
    AND lower(trim(coalesce(email, ''))) = v_email
    AND (auth_user_id IS NULL OR auth_user_id = v_uid)
  RETURNING id INTO pid;

  IF pid IS NOT NULL THEN
    RETURN pid;
  END IF;

  v_local := split_part(v_email, '@', 1);
  IF length(v_local) = 0 THEN
    v_display := v_email;
  ELSE
    v_display := upper(substr(v_local, 1, 1)) || substr(v_local, 2);
  END IF;

  v_handle := lower(regexp_replace(v_local, '[^a-zA-Z0-9._-]', '', 'g'));
  IF v_handle IS NULL OR v_handle = '' THEN
    v_handle := 'user';
  END IF;

  INSERT INTO people (
    company_id,
    email,
    display_name,
    handle,
    title,
    auth_user_id,
    role,
    status
  )
  VALUES (
    p_company_id,
    v_email,
    v_display,
    v_handle,
    nullif(trim(p_title), ''),
    v_uid,
    0,
    1
  )
  RETURNING id INTO pid;

  RETURN pid;

EXCEPTION
  WHEN unique_violation THEN
    UPDATE people
    SET
      auth_user_id = v_uid,
      updated_at = now(),
      title = COALESCE(NULLIF(trim(p_title), ''), title)
    WHERE company_id = p_company_id
      AND lower(trim(coalesce(email, ''))) = v_email
      AND (auth_user_id IS NULL OR auth_user_id = v_uid)
    RETURNING id INTO pid;

    IF pid IS NOT NULL THEN
      RETURN pid;
    END IF;
    RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.inled_claim_person_for_domain_join(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inled_claim_person_for_domain_join(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.inled_claim_person_for_domain_join(uuid, text) IS
  'Onboarding: claim placeholder or insert person; row_security=off so UPDATE sees rows under RLS.';
