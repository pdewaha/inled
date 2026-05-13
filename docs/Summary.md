inled — what it is
inled is a Flutter client for a small team expectations / talking-points ledger. Users capture one-line entries with @people and #tags, store them as expectations (commitments) or talking points (lighter prep / threads), and browse inbox, outbox, people, and talking points views. Backend is Supabase (auth, people, companies, expectations, tags-related reads).

App shell and navigation
main.dart — Initializes Supabase, runs MaterialApp with theme variant (light/dark).
Auth — StreamBuilder on auth.onAuthStateChange: no session → AuthWelcomeScreen (sign-in + theme menu); session → CompanyOnboardingGate.
CompanyOnboardingGate — Ensures the user is linked to a company / people row (join or create company flow). When ready → LedgerConsoleScreen (the main app UI).
Main UI: LedgerConsoleScreen
Single large screen: persistent left rail + main column.

Pillars (LedgerPillar)
The rail switches pillars (sections). Each has title, accent colors, and optional capture accent for the composer chrome:

Pillar	Role
Home
Dashboard (welcome + placeholder “waiting” card) + examples; dual-mode composer in Quick Capture (centered dialog from AppBar “Quick Capture” button or plain Q when not typing in a field; Ctrl/Alt/Meta+Q ignored).
Add expectation
Dedicated capture for expectations
Add talking point
Dedicated capture for talking points
Inbox / Outbox
Filtered expectation lists (“towards me” / “dispatched”)
People
Colleague directory
Talking points
Tags / colleagues / meetings-style browsing
Layout pattern
Top: pillar header.
Composer block (Add expectation, Add talking point, and Home Quick Capture dialog): wrapped in a Focus node with onKeyEvent for custom Tab / Enter behavior; ExcludeFocus on the thread ListView so Tab does not enter the feed during capture (when the save row is active).
Bottom: Expanded ListView of “thread” cards (guides, expectations, people, tags content — depends on pillar).
Composer and capture model
CommandCaptureBar — Shared multiline TextField (TextEditingController + FocusNode), monospace styling, optional @/# suggestion strip under the field, CallbackShortcuts for Enter when inline picks are active.
Parsing — parseCaptureLine (capture_parser.dart) extracts rough signals (handles, tags, deadline hints) for display; submit rules are enforced in the screen (regex for @ / #, “content word” checks, etc.).
Persistence — _submitCapture (and helpers) builds Expectation rows, optimistic FeedEntry on Home, writes to Supabase, reloads lists; visibility (shadow = private/draft, echo = published) and type (topic vs expectation) drive behavior.
Home vs dedicated capture pillars
Home
Quick Capture dialog: two-step save (Save as Talking Point / Save as Expectation, then visibility row) with the same keyboard rules as before; main Home body no longer embeds the composer.
State: _homePendingEntry, _composerMode, Listenable.merge on controller + revision notifier so the save row stays in sync after clear() / reset.
After successful save: hard reset (block key + token + neutral state) so UI returns to the kind row; home-only refocus path (GlobalKey host + FocusScope.requestFocus + delayed retries) so the capture field gets focus again.
Enter (hardware): resolves single valid mode and advances to visibility step; token picks delegate to the bar’s Enter handling.
Add expectation / Add talking point
Single row of two _PairedSaveAction buttons (draft/send or private/public).
Enter from field: expectation uses _expectationPillarQuickChoice (synced from which save button last had focus via FocusNode listeners); Add talking point Enter submits private save explicitly (aligned with UX copy).
Visual “Enter default” without stealing focus: emphasizeAsKeyboardDefault on the left (or matching) button — primary colors while the field is focused and the line is valid; Listenable.merge(controller, captureFocus) so it updates when focus moves.
Tab cycles field → left save → right save (custom handler; list excluded).
Supporting widgets / models
Models: Expectation, Person, FeedEntry, enums for status, health, visibility, type, pillar.
Widgets: LedgerTagChip, ExpectationStatusBadge, VisibilityGlyph, ResponsiveCenteredBody, etc.
Theme: theme.dart / AppThemeVariant.
Security / ops note for GitHub
main.dart embeds the Supabase URL and anon key. For a public repo, move secrets to --dart-define, CI secrets, or a non-committed config file and document how to run the app locally.
Row-level security for ledger tables is defined in supabase-db/rls_policies.sql (run in the Supabase SQL editor after schema.sql). Storage bucket policies are separate and not covered in that file.