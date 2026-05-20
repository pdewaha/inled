# --- CONFIGURATION ---
$LocalPath   = './supabase/functions'
$RemoteUser  = 'root'
$RemoteHost  = 'beacon.tauworks.org'
$RemotePath  = '/root/exled/docker'

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
scp -r $LocalPath ($RemoteUser + '@' + $RemoteHost + ':' + $RemotePath)

# Check status
if ($LASTEXITCODE -eq 0) {
    Write-Host '✅ Success! Edge functions deployed cleanly.'
} else {
    Write-Host '❌ Error: SCP operation aborted.'
}
Write-Host '========================================='