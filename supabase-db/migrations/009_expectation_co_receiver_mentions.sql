-- Allow @co-receivers on expectations (type 0) in expectation_mentions, not only talking points.

DROP POLICY IF EXISTS inled_expectation_mentions_insert ON expectation_mentions;
CREATE POLICY inled_expectation_mentions_insert ON expectation_mentions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id IN (SELECT public.inled_user_company_ids())
    AND EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.company_id = company_id
        AND e.writer_user_id = auth.uid()
        AND (
          (e.expectation_type = 1 AND e.expectation_visibility IN (0, 1))
          OR (e.expectation_type = 0 AND e.expectation_visibility IN (0, 1))
        )
    )
  );

DROP POLICY IF EXISTS inled_expectation_mentions_delete ON expectation_mentions;
CREATE POLICY inled_expectation_mentions_delete ON expectation_mentions
  FOR DELETE
  TO authenticated
  USING (
    company_id IN (SELECT public.inled_user_company_ids())
    AND EXISTS (
      SELECT 1
      FROM expectations e
      WHERE e.id = expectation_id
        AND e.writer_user_id = auth.uid()
        AND e.expectation_type IN (0, 1)
    )
  );
