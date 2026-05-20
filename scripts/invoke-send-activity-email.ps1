# Invoke send-activity-email Edge Function (self-hosted, no Supabase CLI).
#
# Usage:
#   $env:SUPABASE_URL = "https://be.exled.app"
#   $env:SUPABASE_SERVICE_ROLE_KEY = "<from your server .env>"
#   .\scripts\invoke-send-activity-email.ps1 -OutboxId "<uuid>"
#   .\scripts\invoke-send-activity-email.ps1 -ProcessPending -Limit 20
#   .\scripts\invoke-send-activity-email.ps1 -TestEmail "you@example.com"
#
# Get a pending outbox id from SQL:
#   SELECT id FROM activity_email_outbox WHERE status = 'pending' LIMIT 1;

param(
  [string]$SupabaseUrl = $env:SUPABASE_URL,
  [string]$ServiceRoleKey = $env:SUPABASE_SERVICE_ROLE_KEY,
  [string]$OutboxId = "",
  [string]$TestEmail = "",
  [switch]$ProcessPending,
  [int]$Limit = 20
)

if (-not $SupabaseUrl) {
  $SupabaseUrl = "https://be.exled.app"
}
$SupabaseUrl = $SupabaseUrl.TrimEnd("/")

if (-not $ServiceRoleKey) {
  Write-Error "Set SUPABASE_SERVICE_ROLE_KEY (service_role JWT from your self-hosted .env on beacon)."
  exit 1
}

$uri = "$SupabaseUrl/functions/v1/send-activity-email"

if ($TestEmail) {
  $body = @{ test_email = $TestEmail } | ConvertTo-Json
} elseif ($ProcessPending) {
  $body = @{ process_pending = $true; limit = $Limit } | ConvertTo-Json
} elseif ($OutboxId) {
  $body = @{ outbox_id = $OutboxId } | ConvertTo-Json
} else {
  Write-Error "Pass -TestEmail <addr>, -OutboxId <uuid>, or -ProcessPending"
  exit 1
}

Write-Host "POST $uri"
try {
  $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{
    Authorization = "Bearer $ServiceRoleKey"
    apikey        = $ServiceRoleKey
    "Content-Type" = "application/json"
  } -Body $body
  $response | ConvertTo-Json -Depth 6
} catch {
  Write-Host "HTTP error:" $_.Exception.Message
  if ($_.ErrorDetails.Message) {
    Write-Host $_.ErrorDetails.Message
  }
  Write-Host ""
  Write-Host "If 404: Edge Functions may not be deployed on this stack."
  Write-Host "If connection refused / timeout: check functions container and Kong route."
  exit 1
}
