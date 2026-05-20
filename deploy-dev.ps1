# --- CONFIGURATION ---
$LocalPath   = './supabase/functions'
$RemoteUser  = 'root'
$RemoteHost  = 'beacon.tauworks.org'
$RemotePath  = '/root/leam/docker/volumes/'
$DockerPath  = '/root/leam/docker'           # The folder containing your docker-compose.yml

# --- EXECUTION ---
Clear-Host
Write-Host '========================================='
Write-Host '🚀 Starting Supabase Edge Function Deploy'
Write-Host '========================================='

if (-not (Test-Path -Path $LocalPath)) {
    Write-Error 'CRITICAL: Local directory not found!'
    Exit
}

# Run native OpenSSH SCP
scp -o StrictHostKeyChecking=no -r $LocalPath ($RemoteUser + '@' + $RemoteHost + ':' + $RemotePath)

# Check status
if ($LASTEXITCODE -eq 0) {
    Write-Host '📦 Sync complete. Sending remote restart instructions...' -ForegroundColor Yellow
    
    # Construct the remote command string
    # This navigates to the directory and restarts the functions container
    $RemoteCmd = "cd $DockerPath && docker compose restart functions"
    
    # Execute the command over SSH
    ssh -o StrictHostKeyChecking=no ($RemoteUser + '@' + $RemoteHost) $RemoteCmd
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host '✅ Success! Edge functions deployed and container restarted cleanly.' -ForegroundColor Green
    } else {
        Write-Host '⚠️ Files copied, but remote container restart failed.' -ForegroundColor Yellow
    }
} else {
    Write-Host '❌ Error: SCP operation aborted.' -ForegroundColor Red
}
Write-Host '========================================='