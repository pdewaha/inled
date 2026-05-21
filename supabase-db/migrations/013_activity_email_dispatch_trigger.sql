-- Ensure INSERT trigger calls pg_net dispatch (missing on some manual/dashboard-only setups).

DROP TRIGGER IF EXISTS trg_dispatch_activity_email_outbox ON activity_email_outbox;
CREATE TRIGGER trg_dispatch_activity_email_outbox
  AFTER INSERT ON activity_email_outbox
  FOR EACH ROW
  WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION inled_dispatch_activity_email_outbox();
