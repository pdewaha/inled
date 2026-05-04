Inled App Summary
Inled is an executive accountability ledger, not a typical task manager.
It governs commitments between people with clear ownership, strategic context, and auditability.

Core product ideas:

Strategic anchoring: every expectation can tie to a strategic goal (ideation_goals) so work has a documented “why”.
Contractual handshake: expectations are explicit agreements between a writer and a target person.
Definitive accountability: lifecycle status + event history provide objective records (e.g., pending/contracted/breached flow in app semantics).
UI/mental model:

“Objective” and “Expectation” are treated as two perspectives of the same row:
writer view => expectation I set
target view => objective for me
Composer/capture flow supports quick entry and parsed hints (@people, #tags, deadlines).
Data Model Summary
Current schema is in supabase-db/schema.sql.

1) Multi-company tenancy and access
companies: tenant root.
company_members: users affiliated to companies (multi-company capable).
invites: invitation workflow for membership onboarding.
This supports a future where one user can belong to multiple companies, while the app can still behave as “one active company” for now.

2) People and strategy context
people: collaborators/targets inside a company; may optionally map to a real auth user.
ideation_goals: strategic goal layer used to anchor expectations.
3) Core ledger entity
expectations: the central directed commitment record, including:
writer_user_id (who authored/owns it)
target_person_id (who it is about/for)
title, summary
deadline_label, deadline_at
progress (integer, app-defined)
expectation_status (integer, app-defined)
expectation_visibility (integer, app-defined)
optional ideation_goal_id
4) Tagging model (reusable and coherent)
expectation_tags: reusable tag dictionary per company.
expectation_tag_links: many-to-many link between expectations and tags.
Uniqueness is enforced per company via lower(name) so tag naming stays coherent.
5) Audit and capture
expectation_events: immutable history/events for lifecycle and change tracking.
ledger_captures: raw composer entries plus optional parsed JSON payload.
Modeling Principles We Agreed
Use UUID primary keys and timestamptz.
Use integer semantic codes (status, visibility, pillar, role, etc.) mapped in app code.
No CHECK constraints on semantic integer ranges, to avoid blocking future app evolution.
Keep data company-scoped for clean tenancy and future RLS.
