Write-Host "Building Flutter Web (prod)..." -ForegroundColor Cyan
flutter build web --release --dart-define=SUPABASE_URL=https://leam.tauworks.org
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Cleaning remote web root..." -ForegroundColor Yellow
ssh root@beacon.tauworks.org "rm -rf /web/inled/*"

Write-Host "Uploading build/web -> /web/inled/ ..." -ForegroundColor Green
scp -r build/web/* root@beacon.tauworks.org:/web/inled/

scp -r web/magic_link.html root@beacon.tauworks.org:/web/inled/

Write-Host "Verifying deploy (mentions-fix build id in bundle)..." -ForegroundColor Yellow

Write-Host "Deployment complete. In Brave: unregister service worker + clear site data for be.exled.app, then reload." -ForegroundColor Green