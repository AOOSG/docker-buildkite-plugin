# Equivalent PowerShell script
Set-StrictMode -Version Latest
# Equivalent PowerShell script
$ErrorActionPreference = "Stop"

# NOTE(AOOSG): Useful for debugging
#Write-Host "Env variables:"
#Get-ChildItem -Path env: | ForEach-Object {
#	Write-Host "$($_.Name) = $($_.Value)"
#}


function Invoke-OSGRunDocker {
	param (
		[Parameter(Mandatory = $true)]
		[string]$image,
		[Parameter(Mandatory = $true)]
		[string[]]$ArgumentList
	)

	Write-Host "--- :docker: Running command in $image"
		
	# Don't convert paths on gitbash on windows, as that can mangle user paths and cmd options.
	# See https://github.com/buildkite-plugins/docker-buildkite-plugin/issues/81 for more information.
	if (Test-Is-Windows) {
		$env:MSYS_NO_PATHCONV = 1
	}
	
	$executable = "docker"

	Write-Host "$executable $ArgumentList"
	$process = Start-Process -FilePath $executable -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru
	if ($null -eq $process) {
		throw "Unable to start process '$($executable)'..."
	}
	$process.WaitForExit()

	if ($process.ExitCode -ne 0)
	{
		Throw "$($executable) exited with code '$($process.ExitCode)'"
	}
}

function Invoke-OSGRun {
	param (
		[Parameter(Mandatory = $true)]
		[string]$command
	)

	Write-Host "--- :computer: Running command"
	Write-Host "Running: '$($command)'"
	$process = Start-Process -FilePath $command -NoNewWindow -Wait -PassThru
	if ($null -eq $process) {
		throw "Unable to start process '$($executable)'..."
	}
	$process.WaitForExit()

	if ($process.ExitCode -ne 0)
	{
		Throw "$($executable) exited with code '$($process.ExitCode)'"
	}
}

function Get-EnvVariableWithDefault {
	param (
		[AllowEmptyString()]
		[AllowNull()]
		[Parameter(Mandatory = $true)]
		[string]$envVariable,
		[string]$defaultValue
	)

	if ($envVariable) {
		return $envVariable
	} else {
		return $defaultValue
	}
}

function Retry {
	param(
		[int]$retries,
		[ScriptBlock]$command
	)

	$attempts = 1

	do {
		try {
			& $command
			return
		} catch {
			$retry_exit_status = $_.Exception.ExitCode
			Write-Host "Exited with $retry_exit_status"
			if ($retries -eq 0) {
				return $retry_exit_status
			} elseif ($attempts -eq $retries) {
				Write-Host "Failed $attempts retries"
				return $retry_exit_status
			} else {
				Write-Host "Retrying $($retries - $attempts) more times..."
				$attempts++
				Start-Sleep -Seconds (($attempts - 2) * 2)
			}
		}
	} while ($true)
}

# AO(TODO): Test that this is a replacement for Plugin-Read-List-Into-Result
function Get-EnvironmentVariableArray {
	param (
		[string]$prefix
	)

	$result = @()

	if ($null -ne $prefix) {
		$i = 0
		while ($true) {
			$variableName = "${prefix}_${i}"
			$value = [System.Environment]::GetEnvironmentVariable($variableName)
			if ($null -eq $value) {
				break
			}
			$result += $value
			$i++
		}	
	}

	return $result
}

# docker's -v arguments don't do local path expansion, so we add very simple support for .
function Expand-Relative-Volume-Path {
	param (
		[string]$path
	)

	if ($env:BUILDKITE_PLUGIN_DOCKER_EXPAND_VOLUME_VARS -match "^(true|on|1)$") {
		$expandedPath = Invoke-Expression -Command $path
	} else {
		$expandedPath = $path
	}

	if ($expandedPath -match '^\.:') {
		$expandedPath = Join-Path $PWD ($expandedPath -replace '^\.:')
	} elseif ($expandedPath -match '^\.(/|\\)') {
		$expandedPath = Join-Path $PWD ($expandedPath -replace '^\.(/|\\)')
	}

	return $expandedPath
}

# PowerShell equivalent of is_windows() function
function Test-Is-Windows {
	return (-Not (Test-Is-Macos))
	#return ($env:OSTYPE -match "^(win|msys|cygwin)")
}

# PowerShell equivalent of is_macos() function
function Test-Is-Macos {
	return ($env:OSTYPE -match "^(darwin)")
}

$tty_default = "on"
$interactive_default = "on"
$init_default = "on"
$mount_agent_default = "off"
$pwd_default = $env:PWD
$workdir_default = "/workdir"
$agent_mount_folder = "/usr/bin/buildkite-agent"

# Set operating system specific defaults
if (Test-Is-Windows) {
	$tty_default = ""
	$init_default = ""
	$workdir_default = "C:\workdir"
	# NOTE(AOOSG): This doesn't seem to be needed - use $env:PWD
	# Escaping /C is a necessary workaround for an issue with Git for Windows 2.24.1.2
	# https://github.com/git-for-windows/git/issues/2442
	#$pwd_default = (cmd.exe //C "echo $($env:PWD)")
	# Single quotes are important to avoid double-escaping the already escaped backslash
	$agent_mount_folder = "C:\buildkite-agent"
}


$ArgumentList = @()
$ArgumentList += "run"

# Support switching tty off
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_TTY `
		-defaultValue $tty_default) -match "^(true|on|1)$") {
	$ArgumentList += "-t"
}

# Support switching interactive off
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_INTERACTIVE `
		-defaultValue $interactive_default) -match "^(true|on|1)$") {
	$ArgumentList += "-i"
}

# Automatically remove the container when it exits
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_LEAVE_CONTAINER `
		-defaultValue "off") -notmatch "^(true|on|1)$") {
	$ArgumentList += "--rm"
}

# Support docker run --init.
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_INIT `
		-defaultValue $init_default) -match "^(true|on|1)$") {
	$ArgumentList += "--init"
}

# Parse tmpfs property.
$tmpfsArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_TMPFS"
foreach ($arg in $tmpfsArgs) {
	$expandedPath = Expand-Relative-Volume-Path $arg
	$ArgumentList += "--tmpfs"
	$ArgumentList += $expandedPath
}

$workdir = ""

if ($env:BUILDKITE_PLUGIN_DOCKER_WORKDIR -or `
	((Get-EnvVariableWithDefault `
			-envVariable $env:BUILDKITE_PLUGIN_DOCKER_MOUNT_CHECKOUT `
			-defaultValue "on") -match "^(true|on|1)$")) {
	$workdir = $env:BUILDKITE_PLUGIN_DOCKER_WORKDIR
	if (-Not $workdir) {
		$workdir = $workdir_default
	}

	# Set an environment variable so we can go easily find the directory inside the running docker image.
	$ArgumentList += "--env"
	$ArgumentList += "OSG_WORKDIR=$($workdir)"
}

# By default, mount $PWD onto $WORKDIR
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_MOUNT_CHECKOUT `
		-defaultValue "on") -match "^(true|on|1)$") {
	$ArgumentList += "--volume"
	$ArgumentList += "$($pwd_default):$workdir"
}

# Parse volumes (and deprecated mounts) and add them to the docker ArgumentList
$volumesArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_VOLUMES"
if ($volumesArgs) {
	foreach ($arg in $volumesArgs) {
		$expandedPath = Expand-Relative-Volume-Path $arg
		$ArgumentList += "--volume"
		$ArgumentList += $expandedPath
	}
}

# If there's a git mirror, mount it so that git references can be followed.
# But not if mount-checkout is disabled.
if ($env:BUILDKITE_REPO_MIRROR -and
	((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_MOUNT_CHECKOUT `
		-defaultValue "on") -match "^(true|on|1)$")) {
	$ArgumentList += "--volume"
	$ArgumentList += "$($env:BUILDKITE_REPO_MIRROR):$($env:BUILDKITE_REPO_MIRROR):ro"
}

# Parse devices and add them to the docker ArgumentList
$devicesArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_DEVICES"
if ($devicesArgs) {
	foreach ($arg in $devicesArgs) {
		$ArgumentList += "--device"
		$ArgumentList += $arg
	}
}

# Parse sysctl ArgumentList and add them to docker ArgumentList
$sysctlArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_SYSCTLS"
if ($sysctlArgs) {
	foreach ($arg in $sysctlArgs) {
		$ArgumentList += "--sysctl"
		$ArgumentList += $arg
	}
}

# Parse cap-add ArgumentList and add them to docker ArgumentList
$addCapsArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_ADD_CAPS"
if ($addCapsArgs) {
	foreach ($arg in $addCapsArgs) {
		$ArgumentList += "--cap-add"
		$ArgumentList += $arg
	}
}

# Parse cap-drop ArgumentList and add them to docker ArgumentList
$dropCapsArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_DROP_CAPS"
if ($dropCapsArgs) {
	foreach ($arg in $dropCapsArgs) {
		$ArgumentList += "--cap-drop"
		$ArgumentList += $arg
	}
}

# Parse security-opts ArgumentList and add them to docker ArgumentList
$securityOptsArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_SECURITY_OPTS"
if ($securityOptsArgs) {
	foreach ($arg in $securityOptsArgs) {
		$ArgumentList += "--security-opt"
		$ArgumentList += $arg
	}
}

# Parse ulimits ArgumentList and add them to docker ArgumentList
$ulimitsArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_ULIMITS"
if ($ulimitsArgs) {
	foreach ($arg in $ulimitsArgs) {
		$ArgumentList += "--ulimit"
		$ArgumentList += $arg
	}
}

# Set workdir if one is provided or if the checkout is mounted
if ($env:OSG_SET_WORKDIR) {
	if ($workdir -or
		((Get-EnvVariableWithDefault `
			-envVariable $env:BUILDKITE_PLUGIN_DOCKER_MOUNT_CHECKOUT `
			-defaultValue "on") -match "^(true|on|1)$")) {
		$ArgumentList += "--workdir"
		$ArgumentList += $workdir
	}
}

# Support docker run --user
if ($env:BUILDKITE_PLUGIN_DOCKER_USER -and $env:BUILDKITE_PLUGIN_DOCKER_PROPAGATE_UID_GID) {
	Write-Host "+++ Error: Can't set both user and propagate-uid-gid" -ForegroundColor Red
	exit 1
}

if ($env:BUILDKITE_PLUGIN_DOCKER_USER) {
	$ArgumentList += "-u"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_USER
}

# Parse publish ArgumentList and add them to docker ArgumentList
$publishArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_PUBLISH"
if ($publishArgs) {
	foreach ($arg in $publishArgs) {
		$ArgumentList += "--publish"
		$ArgumentList += $arg
	}
}

if ($env:BUILDKITE_PLUGIN_DOCKER_PROPAGATE_UID_GID) {
	$ArgumentList += "-u"
	$ArgumentList += "$(id -u):$(id -g)"
}

# Support docker run --group-add
# AO(FIXME): The variable '$env' cannot be retrieved because it has not been set.
#$env.GetEnumerator() | Where-Object { $_.Name -match "^(BUILDKITE_PLUGIN_DOCKER_ADDITIONAL_GROUPS_[0-9]+)" } | ForEach-Object {
#	$ArgumentList += "--group-add"
#	$ArgumentList += $_.Value
#}

# Support docker run --userns
if ($env:BUILDKITE_PLUGIN_DOCKER_USERNS) {
	# However, if BUILDKITE_PLUGIN_DOCKER_PRIVILEGED is enabled, then userns MUST
	# be overridden to host per limitations of docker
	# https://docs.docker.com/engine/security/userns-remap/#user-namespace-known-limitations
	if ($env:BUILDKITE_PLUGIN_DOCKER_PRIVILEGED -match "^(true|on|1)$") {
		$ArgumentList += "--userns"
		$ArgumentList += "host"
	} else {
		$ArgumentList += "--userns"
		$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_USERNS
	}
}

# Mount ssh-agent socket and known_hosts
if ($env:BUILDKITE_PLUGIN_DOCKER_MOUNT_SSH_AGENT -match "^(true|on|1)$") {
	if (-not (Test-Path $env:SSH_AUTH_SOCK)) {
		Write-Host "+++ 🚨 `$SSH_AUTH_SOCK isn't set, has ssh-agent started?" -ForegroundColor Yellow
		exit 1
	}
	if (-not (Test-Path -PathType Leaf $env:SSH_AUTH_SOCK)) {
		Write-Host "+++ 🚨 The file at $($env:SSH_AUTH_SOCK) does not exist or is not a socket, has ssh-agent started?" -ForegroundColor Yellow
		exit 1
	}

	if ($env:BUILDKITE_PLUGIN_DOCKER_MOUNT_SSH_AGENT -match "^(true|on|1)$") {
		$mountPath = "/root"
	} else {
		$mountPath = $env:BUILDKITE_PLUGIN_DOCKER_MOUNT_SSH_AGENT
	}

	$ArgumentList += "--env"
	$ArgumentList += "SSH_AUTH_SOCK=/ssh-agent"
	$ArgumentList += "--volume"
	$ArgumentList += "$($env:SSH_AUTH_SOCK):/ssh-agent"
	$ArgumentList += "--volume"
	$ArgumentList += "$($env:USERPROFILE)\.ssh\known_hosts:$($mountPath)\.ssh\known_hosts"
}

# Handle the mount-buildkite-agent option
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_MOUNT_BUILDKITE_AGENT `
		-defaultValue $mount_agent_default) -match "^(true|on|1)$") {
	if (-not $env:BUILDKITE_BIN_PATH) {
		if (Test-Path -PathType Leaf "buildkite-agent.exe") {
			$env:BUILDKITE_BIN_PATH = (Get-Command -Name "buildkite-agent.exe").Source
		} elseif (!(Get-Command -Name "buildkite-agent" -ErrorAction SilentlyContinue)) {
			Write-Host "+++ 🚨 Failed to find buildkite-agent in PATH to mount into container, you can disable this behavior with 'mount-buildkite-agent:false'" -ForegroundColor Yellow
		}
	}
}

if ($env:BUILDKITE_BIN_PATH) {
	$ArgumentList += "--env"
	$ArgumentList += "BUILDKITE_JOB_ID"
	$ArgumentList += "--env"
	$ArgumentList += "BUILDKITE_BUILD_ID"
	$ArgumentList += "--env"
	$ArgumentList += "BUILDKITE_AGENT_ACCESS_TOKEN"
	$ArgumentList += "--volume"
	$ArgumentList += "$($env:BUILDKITE_BIN_PATH):$($agent_mount_folder)"
	$ArgumentList += "--env"
	$ArgumentList += "BUILDKITE_BIN_PATH=$($agent_mount_folder)"
}

# Parse extra env vars and add them to the docker ArgumentList
# AO(FIXME): The variable '$env' cannot be retrieved because it has not been set.
#$env.GetEnumerator() | Where-Object { $_.Name -match "^(BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_[0-9]+)" } | ForEach-Object {
#	$ArgumentList += "--env"
#	$ArgumentList += $_.Value
#}


# Parse host mappings and add them to the docker ArgumentList
# AO(FIXME): The variable '$env' cannot be retrieved because it has not been set.
#$env.GetEnumerator() | Where-Object { $_.Name -match "^(BUILDKITE_PLUGIN_DOCKER_ADD_HOST_[0-9]+)" } | ForEach-Object {
#	$ArgumentList += "--add-host"
#	$ArgumentList += $_.Value
#}

# Privileged container
if ($env:BUILDKITE_PLUGIN_DOCKER_PRIVILEGED -match "^(true|on|1)$") {
	$ArgumentList += "--privileged"
}

$envFileArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_ENV_FILE"
if ($envFileArgs) {
	foreach ($arg in $envFileArgs) {
		$ArgumentList += "--env-file"
		$ArgumentList += $arg
	}
}

# If requested, propagate a set of env vars as listed in a given env var to the container.
if ($env:BUILDKITE_PLUGIN_DOCKER_ENV_PROPAGATION_LIST) {
	if (-not $env:BUILDKITE_PLUGIN_DOCKER_ENV_PROPAGATION_LIST) {
		Write-Host "env-propagation-list desired, but env:BUILDKITE_PLUGIN_DOCKER_ENV_PROPAGATION_LIST is not defined!" -ForegroundColor Yellow
		exit 1
	}
	foreach ($var in $env:BUILDKITE_PLUGIN_DOCKER_ENV_PROPAGATION_LIST) {
		$ArgumentList += "--env"
		$ArgumentList += $var
	}
}

# Propagate all environment variables into the container if requested
if ($env:BUILDKITE_PLUGIN_DOCKER_PROPAGATE_ENVIRONMENT -match "^(true|on|1)$") {
	if ($env:BUILDKITE_ENV_FILE) {
		# Read in the env file and convert to --env params for docker
		# This is because --env-file doesn't support newlines or quotes per https://docs.docker.com/compose/env-file/#syntax-rules
		Get-Content -Path $env:BUILDKITE_ENV_FILE | ForEach-Object {
			$ArgumentList += "--env"
			$ArgumentList += $_.Split("=")[0]
		}
	} else {
		Write-Host "🚨 Not propagating environment variables to container as \$env:BUILDKITE_ENV_FILE is not set" -ForegroundColor Yellow
	}
}

# Propagate aws auth environment variables into the container e.g. from assume role plugins
if ($env:BUILDKITE_PLUGIN_DOCKER_PROPAGATE_AWS_AUTH_TOKENS -match "^(true|on|1)$") {
	if ($env:AWS_ACCESS_KEY_ID) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_ACCESS_KEY_ID"
	}
	if ($env:AWS_SECRET_ACCESS_KEY) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_SECRET_ACCESS_KEY"
	}
	if ($env:AWS_SESSION_TOKEN) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_SESSION_TOKEN"
	}
	if ($env:AWS_REGION) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_REGION"
	}
	if ($env:AWS_DEFAULT_REGION) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_DEFAULT_REGION"
	}
	if ($env:AWS_ROLE_ARN) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_ROLE_ARN"
	}
	if ($env:AWS_STS_REGIONAL_ENDPOINTS) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_STS_REGIONAL_ENDPOINTS"
	}
	# Pass ECS variables when the agent is running in ECS
	# https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
	if ($env:AWS_CONTAINER_CREDENTIALS_FULL_URI) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_CONTAINER_CREDENTIALS_FULL_URI"
	}
	if ($env:AWS_CONTAINER_CREDENTIALS_RELATIVE_URI) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
	}
	if ($env:AWS_CONTAINER_AUTHORIZATION_TOKEN) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_CONTAINER_AUTHORIZATION_TOKEN"
	}
	# Pass EKS variables when the agent is running in EKS
	# https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts-minimum-sdk.html
	if ($env:AWS_WEB_IDENTITY_TOKEN_FILE) {
		$ArgumentList += "--env"
		$ArgumentList += "AWS_WEB_IDENTITY_TOKEN_FILE"
		# Add the token file as a volume
		$ArgumentList += "--volume"
		$ArgumentList += "$env:AWS_WEB_IDENTITY_TOKEN_FILE:$env:AWS_WEB_IDENTITY_TOKEN_FILE"
	}
}

if ($env:BUILDKITE_PLUGIN_DOCKER_EXPAND_IMAGE_VARS -match "^(true|on|1)$") {
	$image = $ExecutionContext.InvokeCommand.ExpandString($env:BUILDKITE_PLUGIN_DOCKER_IMAGE)
} else {
	$image = $env:BUILDKITE_PLUGIN_DOCKER_IMAGE
}

if ($env:BUILDKITE_PLUGIN_DOCKER_ALWAYS_PULL -match "^(true|on|1)$") {
	Write-Host "--- :docker: Pulling $image"
	if (-not (Retry "$($env:BUILDKITE_PLUGIN_DOCKER_PULL_RETRIES)" { docker pull $image })) {
		Write-Host "!!! :docker: Pull failed." -ForegroundColor Red
		exit $retry_exit_status
	}
}

# Parse network and create it if it don't exist.
if ($env:BUILDKITE_PLUGIN_DOCKER_NETWORK) {
	$dockerNetworkId = (docker network ls --quiet --filter "name=${$env:BUILDKITE_PLUGIN_DOCKER_NETWORK}")
	if (-not $dockerNetworkId) {
		Write-Host "creating network ${$env:BUILDKITE_PLUGIN_DOCKER_NETWORK}"
		docker network create $env:BUILDKITE_PLUGIN_DOCKER_NETWORK
	} else {
		Write-Host "docker network ${$env:BUILDKITE_PLUGIN_DOCKER_NETWORK} already exists"
	}
	$ArgumentList += "--network"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_NETWORK
}
# Support docker run --platform
if ($env:BUILDKITE_PLUGIN_DOCKER_PLATFORM) {
	$ArgumentList += "--platform"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_PLATFORM
}

# Support docker run --pid
if ($env:BUILDKITE_PLUGIN_DOCKER_PID) {
	$ArgumentList += "--pid"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_PID
}

# Support docker run --gpus
if ($env:BUILDKITE_PLUGIN_DOCKER_GPUS) {
	$ArgumentList += "--gpus"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_GPUS
}

# Support docker run --runtime
if ($env:BUILDKITE_PLUGIN_DOCKER_RUNTIME) {
	$ArgumentList += "--runtime"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_RUNTIME
}

# Support docker run --ipc
if ($env:BUILDKITE_PLUGIN_DOCKER_IPC) {
	$ArgumentList += "--ipc"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_IPC
}

# Support docker run --storage-opt
if ($env:BUILDKITE_PLUGIN_DOCKER_STORAGE_OPT) {
	$ArgumentList += "--storage-opt"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_STORAGE_OPT
}

# Set up the LongtailCache path so we can use a shared UE5 download cache for all builds.
if ((Get-EnvVariableWithDefault `
		-envVariable $env:OSG_LONGTAIL_SHARED_CACHE `
		-defaultValue "true") -match "^(true|on|1)$") {
	$longtailCachePath = (Get-EnvVariableWithDefault `
		-envVariable $env:OSG_LONGTAIL_CACHE_RELATIVE_PATH `
		-defaultValue "..\..\..\LongtailCache")
	$longtailCachePath = Join-Path -Path $pwd_default -ChildPath $longtailCachePath
	# Create a longtail cache folder on the host if it does not exist.
	if (-not (Test-Path -Path $longtailCachePath)) {
		New-Item -Path $longtailCachePath -ItemType Directory -Force
	}
	$longtailCachePath = (Resolve-Path -Path $longtailCachePath).Path
	Write-Host "Using longtail cache path '$($longtailCachePath)'"
	$ArgumentList += "--volume"
	$ArgumentList += "`"$($longtailCachePath)`":C:\LongtailCache"
}

# Set up the an external DerivedDataCache folder so we can re-use shaders between runs.
if ((Get-EnvVariableWithDefault `
		-envVariable $env:OSG_DERIVED_DATA_CACHE_VOLUME `
		-defaultValue "true") -match "^(true|on|1)$") {
	$derivedDataCachePath = (Get-EnvVariableWithDefault `
		-envVariable $env:OSG_LONGTAIL_CACHE_RELATIVE_PATH `
		-defaultValue "..\..\DerivedDataCache")
	$derivedDataCachePath = Join-Path -Path $pwd_default -ChildPath $derivedDataCachePath
	# Create a derived data cache folder on the host if it does not exist.
	if (-not (Test-Path -Path $derivedDataCachePath)) {
		New-Item -Path $derivedDataCachePath -ItemType Directory -Force
	}
	$derivedDataCachePath = (Resolve-Path -Path $derivedDataCachePath).Path
	Write-Host "Using derived data cache path '$($derivedDataCachePath)'"
	$ArgumentList += "--volume"
	# Note: If the user changes from ContainerAdministrator we need to update this path.
	$ArgumentList += "`"$($derivedDataCachePath)`":`"C:\Users\ContainerAdministrator\AppData\Local\UnrealEngine\Common\DerivedDataCache`""
}

# Add a name to the container
$ArgumentList += "--name"
$projectSlug = ($env:BUILDKITE_PIPELINE_SLUG) -replace ' ', '-'
$projectBranch = ($env:BUILDKITE_BRANCH) -replace '/', '-'
$ArgumentList += "$projectSlug.$($env:BUILDKITE_BUILD_NUMBER).$projectBranch-$($env:BUILDKITE_AGENT_NAME)"

$shell = @()
$shell_disabled = $true

# We use an entrypoint file to run the command, so disable the shell.
if ($env:BUILDKITE_COMMAND) {
	if (($env:BUILDKITE_COMMAND -split '\r?\n').Count -gt 1) {
		Write-Host "⚠️  Warning: The command received has multiple lines."
		Write-Host "⚠️           The Docker Plugin may not correctly run multiple commands in the step-level configuration."
		Write-Host "⚠️           You will need to use a single command, a script, or the plugin's command option."
	}
	Write-Host "We use an entrypoint file to run the command, so disable the shell."
	#$shell_disabled = $false
}

# Handle setting of shm size if provided
if ($env:BUILDKITE_PLUGIN_DOCKER_SHM_SIZE) {
	$ArgumentList += "--shm-size"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_SHM_SIZE
}

$defaultIsolationMode = "hyperv"

if (-not (Test-Is-Windows)) {
	Write-Host "Forcing isolation mode to hyperv on non-windows host."
	$defaultIsolationMode = "hyperv"
	# Hack - for cooking builds we use process by default to enable GPU acceleration
} elseif ($env:BUILDKITE_AGENT_META_DATA_QUEUE -like "*cook*") {
	Write-Host "Forcing isolation mode to process for cook builds."
	$defaultIsolationMode = "process"
}

# Set the default isolation mode.
# Note: We have to force 'hyperv' isolation mode on older windows builds, see
# https://unrealcontainers.com/docs/concepts/windows-containers
$osVersion = [System.Environment]::OSVersion.Version
$buildVersion = $osVersion.Build
Write-Host "Windows Build Version: $buildVersion"
if ($buildVersion -lt 1809) {
	Write-Host "Forcing isolation mode to 'hyperv' due to older windows build version $($buildVersion) < 1809."
	$defaultIsolationMode = "hyperv"
}

# Allow us to use all threads on windows
# Handle setting of cpus if provided
# Isolation mode 'process' is recommended (see https://docs.docker.com/docker-for-windows/performance/#tips-for-improving-performance)
$isolationMode = (Get-EnvVariableWithDefault `
	-envVariable $env:OSG_ISOLATION_MODE `
	-defaultValue $defaultIsolationMode)
if ($isolationMode) {
	if ($isolationMode -match "process") {
		# This is required for hardware acceleration.
		# UE5/Engine/Extras/Containers/Windows/Runtime/Dockerfile recommends
		# we set the device.
		$ArgumentList += "--device"
		$ArgumentList += "class/5B45201D-F2F2-4F3B-85BB-30FF1F953599"
	}
	Write-Host "Setting isolation mode to $isolationMode"
	$ArgumentList += "--isolation=$isolationMode"
}

# Handle setting of cpus if provided
$cpus_default = 1
if (Test-Is-Windows) {
	$cpuInfo = Get-WmiObject Win32_Processor
	$cpus_default = $cpuInfo.NumberOfLogicalProcessors
}
$cpu_cap = 16
Write-Host "Number of host logical CPU Cores (capped at $cpu_cap): $cpus_default"
$cpus_default = [Math]::Min($cpus_default, $cpu_cap)
$cpus = (Get-EnvVariableWithDefault `
	-envVariable $env:BUILDKITE_PLUGIN_DOCKER_CPUS `
	-defaultValue $cpus_default)
if ($cpus) {
	$ArgumentList += "--cpus=$cpus"
}

# Handle memory limit if provided
# It seems a minimum of 24GB memory is required to use 16 threads in 'hyperv' mode whilst we add a bit more in 'process'
# mode to be safe as we also need to account for the memory used by the host OS and other processes.
# UE5 allocates 1.5GB to each thread.
$minimumMemoryGbs = [int](1.5 * $cpus)
$memory = (Get-EnvVariableWithDefault `
	-envVariable $env:BUILDKITE_PLUGIN_DOCKER_MEMORY `
	-defaultValue "$($minimumMemoryGbs)")
if ($memory) {
	# Seems process mode requries a bit more memory. Add a bit more memory to be safe as we also need to account for
	# the memory used by the host OS and other processes.
	# Cooking the island map requires + 6GB atm (30GB total for 16 threads)
	# 2023-09-30: Got out of memory using 30GB, 34GB and 38GB so bumping to 42GB (+18GB)
	# c1xx: error C3859: Failed to create virtual memory for PCH
	# c1xx: note: the system returned code 1455: The paging file is too small for this operation to complete.
	# c1xx: note: please visit https://aka.ms/pch-help for more details
	# c1xx: fatal error C1076: compiler limit: internal heap limit reached
	$additional_memory = 18
	Write-Host "Adding 1.5 * $($cpus) + 10GB memory in process isolation mode"
	$memory = [int]($memory) + $additional_memory
	$ArgumentList += "--memory=$($memory)g"
}

# Handle memory swap limit if provided
if ($env:BUILDKITE_PLUGIN_DOCKER_MEMORY_SWAP) {
	$ArgumentList += "--memory-swap=$($env:BUILDKITE_PLUGIN_DOCKER_MEMORY_SWAP)"
}

# Handle memory swappiness if provided
if ($env:BUILDKITE_PLUGIN_DOCKER_MEMORY_SWAPPINESS) {
	$ArgumentList += "--memory-swappiness=$($env:BUILDKITE_PLUGIN_DOCKER_MEMORY_SWAPPINESS)"
}

# Handle entrypoint if set, and default shell to disabled
if ($env:BUILDKITE_PLUGIN_DOCKER_ENTRYPOINT) {
	$ArgumentList += "--entrypoint"
	$ArgumentList += $env:BUILDKITE_PLUGIN_DOCKER_ENTRYPOINT
	$shell_disabled = $true
}

# Handle shell being disabled
if ($env:BUILDKITE_PLUGIN_DOCKER_SHELL -match "^(false|off|0)$") {
	$shell_disabled = $true
} elseif ($env:BUILDKITE_PLUGIN_DOCKER_SHELL) {
	Write-Host "🚨 The Docker Plugin’s shell configuration option can no longer be specified as a string, but only as an array."
	Write-Host "🚨 Please update your pipeline.yml to use an array, for example: [\"/bin/sh\", \"-e\", \"-u\"]."
	Write-Host "Note that the docker plugin will infer a shell if one is required, so you might be able to remove the option entirely"
	exit 1
} else {
	$shellArgs = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_SHELL"
	if ($shellArgs) {
		$shell_disabled = $false
		$shell += $result	
	}
}

# Add the job id as meta-data for reference in pre-exit
$ArgumentList += "--label"
$ArgumentList += "com.buildkite.job-id=$($env:BUILDKITE_JOB_ID)"  # Keep the kebab-case one for backwards compat

# Add useful labels to run container
if ((Get-EnvVariableWithDefault `
		-envVariable $env:BUILDKITE_PLUGIN_DOCKER_RUN_LABELS `
		-defaultValue "true") -match "^(true|on|1)$") {
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.pipeline_name=`"$($env:BUILDKITE_PIPELINE_NAME)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.pipeline_slug=`"$($env:BUILDKITE_PIPELINE_SLUG)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.build_number=`"$($env:BUILDKITE_BUILD_NUMBER)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.job_id=`"$($env:BUILDKITE_JOB_ID)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.job_label=`"$($env:BUILDKITE_LABEL)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.step_key=`"$($env:BUILDKITE_STEP_KEY)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.agent_name=`"$($env:BUILDKITE_AGENT_NAME)`""
	$ArgumentList += "--label"
	$ArgumentList += "com.buildkite.agent_id=`"$($env:BUILDKITE_AGENT_ID)`""
}

# Add the image in before the shell and command
$ArgumentList += $image

# Set a default shell if one is needed
if (-not $shell_disabled -and $shell.Count -eq 0) {
	if (Test-Is-Windows) {
		$shell = @("CMD.EXE", "/c")
	} else {
		$shell = @("/bin/sh", "-e", "-c")
	}
}

$command = @()

# Parse plugin command if provided
$dockerCommands = Get-EnvironmentVariableArray "BUILDKITE_PLUGIN_DOCKER_COMMAND"
if ($dockerCommands) {
	foreach ($arg in $dockerCommands) {
		$command += $arg
	}
}

if ($command.Count -gt 0 -and $env:BUILDKITE_COMMAND) {
	Write-Host "+++ Error: Can't use both a step level command and the command parameter of the plugin"
	exit 1
}

# Assemble the shell and command arguments into the docker arguments

if ($shell.Count -gt 0) {
	$ArgumentList += $shell
}

if ($env:BUILDKITE_COMMAND) {
	if (Test-Is-Windows) {
		# The windows CMD shell only supports multiple commands with &&.
		$windows_multi_command = $env:BUILDKITE_COMMAND -replace '\r?\n', ' && '
		$windows_multi_command = $windows_multi_command -replace '/', '\'
		$ArgumentList += "`"$windows_multi_command`""
	} else {
		$ArgumentList += $env:BUILDKITE_COMMAND
	}
} elseif ($command.Count -gt 0) {
	$ArgumentList += $command
}

# Don't convert paths on gitbash on windows, as that can mangle user paths and cmd options.
# See https://github.com/buildkite-plugins/docker-buildkite-plugin/issues/81 for more information.
if (Test-Is-Windows) {
	$env:MSYS_NO_PATHCONV = 1
}

$runInDocker = Get-EnvVariableWithDefault `
	-envVariable $env:BUILDKITE_AGENT_META_DATA_DOCKER `
	-defaultValue "false"
if ($runInDocker -match "^(true|on|1)$") {
	Invoke-OSGRunDocker -image $image -ArgumentList $ArgumentList
} else {
	Invoke-OSGRun -command $env:BUILDKITE_COMMAND
}
