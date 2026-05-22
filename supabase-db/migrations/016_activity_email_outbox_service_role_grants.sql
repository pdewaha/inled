-- Edge function send-activity-email reads/updates outbox via PostgREST as service_role.
-- Migration 010 enabled RLS but only supabase_admin had table privileges → dispatch 403.

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.activity_email_outbox TO service_role;
