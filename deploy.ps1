Write-Host "Building Flutter Web (prod)..." -ForegroundColor Cyan
flutter build web --release --dart-define=SUPABASE_URL=https://be.exled.app
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Cleaning remote web root..." -ForegroundColor Yellow
ssh root@beacon.tauworks.org "rm -rf /web/exled/*"

Write-Host "Uploading build/web -> /web/exled/ ..." -ForegroundColor Green
scp -r build/web/* root@beacon.tauworks.org:/web/exled/

Write-Host "Verifying deploy (mentions-fix build id in bundle)..." -ForegroundColor Yellow
ssh root@beacon.tauworks.org "grep -c '2026-05-22-mentions-fix' /web/exled/main.dart.js || echo MISSING"
ssh root@beacon.tauworks.org "grep -c 'saved locally, but DB write failed' /web/exled/main.dart.js || true"

Write-Host "Deployment complete. In Brave: unregister service worker + clear site data for be.exled.app, then reload." -ForegroundColor Green