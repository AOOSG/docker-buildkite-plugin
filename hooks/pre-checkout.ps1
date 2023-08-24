# Equivalent PowerShell script
Set-StrictMode -Version Latest

if ($env:BUILDKITE_PLUGIN_DOCKER_SKIP_CHECKOUT -match '^(true|on|1)$') {
	Write-Host "~~~ :docker: Skipping checkout"
	$env:BUILDKITE_REPO = ""
}
