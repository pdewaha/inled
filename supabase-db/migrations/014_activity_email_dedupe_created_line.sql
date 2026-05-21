-- Email: avoid repeating expectation title in intro + summary box.

CREATE OR REPLACE FUNCTION inled_changelog_email_activity_line(
  p_type smallint,
  p_message_text text,
  p_is_topic boolean
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  t text;
  lower_t text;
BEGIN
  t := trim(COALESCE(p_message_text, ''));
  lower_t := lower(t);
  IF t = '' THEN
    RETURN 'New activity on this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  -- Title is shown in summary_snippet; intro stays short.
  IF lower_t LIKE 'created a new expectation:%' THEN
    RETURN 'Created a new expectation.';
  END IF;
  IF lower_t LIKE 'created a new talking point:%' THEN
    RETURN 'Created a new talking point.';
  END IF;
  IF lower_t LIKE 'published this expectation:%' OR lower_t LIKE 'published this talking point:%' THEN
    RETURN 'Published this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  IF lower_t LIKE 'created a new %' OR lower_t LIKE 'published this %' THEN
    RETURN regexp_replace(t, ':.*$', '.');
  END IF;
  IF p_type = 14 THEN
    RETURN 'Published this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  IF p_type = 15 THEN
    RETURN 'Requested an update — consider progress, deadline, or status.';
  END IF;
  IF p_type IN (10, 11, 12, 13) THEN
    RETURN 'Updated this '
      || CASE WHEN p_is_topic THEN 'talking point' ELSE 'expectation' END
      || '.';
  END IF;
  RETURN left(t, 240);
END;
$$;
