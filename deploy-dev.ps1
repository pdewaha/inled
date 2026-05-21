# --- CONFIGURATION ---
$LocalFunctionsPath = './supabase/functions'
$LocalScriptsPath   = './scripts'       # Path to your local scripts folder
$RemoteUser         = 'root'
$RemoteHost         = 'beacon.tauworks.org'
$RemotePath         = '/root/leam/docker/volumes/'
$DockerPath         = '/root/leam/docker'         # The folder containing your docker-compose.yml

# --- EXECUTION ---
Clear-Host
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '🚀 Starting Leam Dev Environment Deploy'  -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan

# Guard Clause: Verify both local directories exist before continuing
if (-not (Test-Path -Path $LocalFunctionsPath)) {
    Write-Error "CRITICAL: Local functions directory '$LocalFunctionsPath' not found!"
    Exit
}
if (-not (Test-Path -Path $LocalScriptsPath)) {
    Write-Error "CRITICAL: Local scripts directory '$LocalScriptsPath' not found!"
    Exit
}

# 1. Sync Functions Folder
Write-Host '📦 Syncing edge functions...' -ForegroundColor Yellow
scp -o StrictHostKeyChecking=no -r $LocalFunctionsPath ($RemoteUser + '@' + $RemoteHost + ':' + $RemotePath)

if ($LASTEXITCODE -ne 0) {
    Write-Host '❌ Error: Functions SCP operation aborted.' -ForegroundColor Red
    Exit
}

# 2. Sync Scripts Folder
Write-Host '📦 Syncing automation scripts...' -ForegroundColor Yellow
scp -o StrictHostKeyChecking=no -r $LocalScriptsPath ($RemoteUser + '@' + $RemoteHost + ':' + $DockerPath)

if ($LASTEXITCODE -ne 0) {
    Write-Host '❌ Error: Scripts SCP operation aborted.' -ForegroundColor Red
    Exit
}

# 3. Handle Remote Restarts
Write-Host '🔄 Sync complete. Sending remote restart instructions...' -ForegroundColor Yellow

# Construct the remote command string to trigger the restart
$RemoteCmd = "cd $DockerPath && docker compose restart functions"

# Execute the command over SSH
ssh -o StrictHostKeyChecking=no ($RemoteUser + '@' + $RemoteHost) $RemoteCmd

if ($LASTEXITCODE -eq 0) {
    Write-Host '✅ Success! Functions & Scripts deployed and runtime restarted cleanly.' -ForegroundColor Green
} else {
    Write-Host '⚠️ Files copied, but remote container restart failed.' -ForegroundColor Yellow
}

Write-Host '=========================================' -ForegroundColor Cyan