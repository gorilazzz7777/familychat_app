#Requires -Version 5.1
<#
.SYNOPSIS
  Pull mtg docker json logs for a time window into _fc_diag/proxy_parity/.

.DESCRIPTION
  Uses SSH alias `vps` (BatchMode). Ask the user for VPS consent before running.

.PARAMETER Minutes
  How many minutes of docker logs to request (default 30).

.PARAMETER OutName
  Output file name under _fc_diag/proxy_parity/.

.EXAMPLE
  powershell -File _fc_diag/proxy_parity/pull_mtg_window.ps1 -Minutes 45
#>
param(
  [int]$Minutes = 30,
  [string]$OutName = ""
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutName) {
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmm")
  $OutName = "mtg_window_$stamp.log"
}
$out = Join-Path $here $OutName

# One remote command; find mtg container then dump json lines.
$remote = @"
C=`$(docker ps --format '{{.Names}}' | grep -E 'mtg.*wifi|mtg-wifi|mtg_wifi' | head -n1); if [ -z "`$C" ]; then C=`$(docker ps --format '{{.Names}}' | grep -i mtg | head -n1); fi; if [ -z "`$C" ]; then echo NO_MTG_CONTAINER >&2; exit 2; fi; echo "# container=`$C since=${Minutes}m" >&2; docker logs --since ${Minutes}m "`$C" 2>&1 | grep -E '^\{' || true
"@

Write-Host "SSH vps → docker logs last ${Minutes}m → $out"
# NOTE: requires prior user consent for VPS access.
ssh -o BatchMode=yes vps $remote | Set-Content -Path $out -Encoding utf8

$size = (Get-Item $out).Length
Write-Host "Wrote $out ($size bytes)"
if ($size -lt 32) {
  Write-Warning "Output looks empty — check container name / consent / ssh."
  exit 1
}
