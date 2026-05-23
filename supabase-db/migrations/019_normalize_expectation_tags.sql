-- One canonical tag per company per name (case-insensitive): store lowercase, merge duplicates.

UPDATE expectation_tags
SET name = lower(trim(name))
WHERE name <> lower(trim(name));

WITH ranked AS (
  SELECT
    id,
    company_id,
    lower(trim(name)) AS lname,
    row_number() OVER (
      PARTITION BY company_id, lower(trim(name))
      ORDER BY created_at ASC NULLS LAST, id ASC
    ) AS rn
  FROM expectation_tags
),
keepers AS (
  SELECT id AS keep_id, company_id, lname
  FROM ranked
  WHERE rn = 1
),
dupes AS (
  SELECT r.id AS drop_id, k.keep_id
  FROM ranked r
  JOIN keepers k ON k.company_id = r.company_id AND k.lname = r.lname
  WHERE r.rn > 1
)
UPDATE expectation_tag_links l
SET tag_id = d.keep_id
FROM dupes d
WHERE l.tag_id = d.drop_id
  AND NOT EXISTS (
    SELECT 1
    FROM expectation_tag_links l2
    WHERE l2.expectation_id = l.expectation_id
      AND l2.tag_id = d.keep_id
  );

DELETE FROM expectation_tag_links l
USING dupes d
WHERE l.tag_id = d.drop_id;

DELETE FROM expectation_tags t
USING dupes d
WHERE t.id = d.drop_id;

COMMENT ON TABLE expectation_tags IS
  'Tag names are stored lowercase; unique per company on lower(name).';
