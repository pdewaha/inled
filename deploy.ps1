Write-Host "Building Flutter Web..." -ForegroundColor Cyan
flutter build web --release

Write-Host "Cleaning remote directory..." -ForegroundColor Yellow
ssh root@beacon.tauworks.org "rm -rf /root/exled/web-dist/*"

Write-Host "Uploading files..." -ForegroundColor Green
scp -r build/web/* root@beacon.tauworks.org:/web/exled/

Write-Host "Deployment Complete!" -ForegroundColor White