# Equivalent PowerShell script
Set-StrictMode -Version Latest

if ($env:BUILDKITE_PLUGIN_DOCKER_CLEANUP -match '^(true|on|1)$') {
	$containers = Get-DockerContainer -All -Filter "label=com.buildkite.job-id=$env:BUILDKITE_JOB_ID"
	foreach ($container in $containers) {
		Write-Host "~~~ Cleaning up left-over container $($container.ID)"
		Stop-DockerContainer -Force $container.ID
	}
}
