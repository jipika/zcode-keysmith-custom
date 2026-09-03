<#
.SYNOPSIS
  zcode-keysmith-custom installer for Windows (no admin required).
  Installs the managed system-role entrypoint for the local ZCode desktop app:
  prompt file, wrapper with injection toggle + channel skip, /po slash commands.
  Activation: current-user environment (HKCU\Environment) + WM_SETTINGCHANGE.
.DESCRIPTION
  Usage:
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -Yes
  Optional:
    -ZCodeAppPath "D:\software\ZCode"   explicit install dir containing ZCode.exe
    -ManagedDir  "C:\Users\me\.zcode-keysmith"
    -SystemSource "C:\path\to\system-role.md"
  Requirements: Windows 10/11, Python 3.10+ (kept installed; ZCode uses it to
  launch the wrapper), local ZCode.exe with resources\glm\zcode.cjs.
.NOTES
  Only operates on current-user registry values and files under the user
  profile. Never reads API keys, tokens, or MCP config. The ZCode install
  directory is not modified.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$Uninstall,
  [string]$ZCodeAppPath = "",
  [string]$ManagedDir = "",
  [string]$SystemSource = ""
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  Write-Output 'install.ps1 is Windows-only. Use install.sh on macOS.'
  exit 1
}

$RepoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ManagedDir) { $ManagedDir = Join-Path $HOME '.zcode-keysmith' }
$BinDir     = Join-Path $ManagedDir 'bin'
$LogDir     = Join-Path $ManagedDir 'logs'
$CacheDir   = Join-Path $ManagedDir 'cache'
$SystemFile = Join-Path $ManagedDir 'system-role.md'
$Wrapper    = Join-Path $BinDir 'zcode-agent-wrapper.py'
$EnvPs1     = Join-Path $BinDir 'zcode-keysmith-env.ps1'
$ConfigFile = Join-Path $ManagedDir 'config.json'
$SkipFile   = Join-Path $ManagedDir 'skip-channels.txt'
if (-not $SystemSource) { $SystemSource = Join-Path $RepoDir 'examples\zcode-unrestricted.md' }

$EnvKeys = @(
  'ZCODE_AGENT_SERVER_COMMAND',
  'ZCODE_AGENT_SERVER_ARGS_JSON',
  'ZCODE_KEYSMITH_SYSTEM_FILE',
  'ZCODE_KEYSMITH_ORIGINAL',
  'ZCODE_KEYSMITH_NODE_COMMAND',
  'ZCODE_KEYSMITH_CACHE_DIR',
  'ZCODE_KEYSMITH_LOG_DIR'
)

$Apply = $false
if ($Yes) { $Apply = $true }

function Write-File([string]$Dst, [string]$Src, [bool]$Exec = $false) {
  $dir = Split-Path -Parent $Dst
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (-not $script:Apply) {
    Write-Output "preview: would write $Dst"
    return
  }
  Copy-Item -LiteralPath $Src -Destination $Dst -Force
  Write-Output "wrote: $Dst"
}

function Backup-ItemSafe([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $bak = "$Path.bak_$stamp"
  Move-Item -LiteralPath $Path -Destination $bak -Force
  Write-Output "backup: $Path -> $bak"
}

function Get-UserEnv([string]$Key) {
  return [Environment]::GetEnvironmentVariable($Key, 'User')
}

function Set-UserEnv([string]$Key, [string]$Value) {
  [Environment]::SetEnvironmentVariable($Key, $Value, 'User')
}

function Remove-UserEnv([string]$Key) {
  [Environment]::SetEnvironmentVariable($Key, $null, 'User')
}

function Invoke-EnvBroadcast {
  Add-Type -Namespace Win32 -Name NativeMethod -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
  $result = [UIntPtr]::Zero
  [Win32.NativeMethod]::SendMessageTimeout(
    [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment',
    0x0002, 5000, [ref]$result) | Out-Null
}

function Find-ZCodeExe {
  if ($script:ZCodeAppPath) {
    $p = Join-Path $script:ZCodeAppPath 'ZCode.exe'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }
  if ($env:ZCODE_APP_PATH) {
    $p = Join-Path $env:ZCODE_APP_PATH 'ZCode.exe'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }
  $proc = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path } | Select-Object -First 1
  if ($proc) { return $proc.Path }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\ZCode\ZCode.exe'),
    (Join-Path $env:ProgramFiles 'ZCode\ZCode.exe')
  )
  if (${env:ProgramFiles(x86)}) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'ZCode\ZCode.exe')
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  return $null
}

function Find-Python {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py -and $py.Source) { return $py.Source }
  return $null
}

function PSSingleQuote([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
  $config = $null
  if (Test-Path $ConfigFile) {
    try { $config = Get-Content -Raw $ConfigFile | ConvertFrom-Json } catch { $config = $null }
  }
  Write-Output '== zcode-keysmith-custom uninstall preview =='
  foreach ($p in @($SystemFile, $SkipFile, $ConfigFile, $Wrapper, $EnvPs1)) {
    if (Test-Path $p) { Write-Output "target: $p" }
  }
  if (-not $Apply) { exit 0 }
  foreach ($p in @($SystemFile, $SkipFile, $ConfigFile, $Wrapper, $EnvPs1)) {
    Backup-ItemSafe $p
  }
  $previous = @{}
  if ($config -and $config.previous_user_environment) {
    $config.previous_user_environment.PSObject.Properties |
      ForEach-Object { $previous[$_.Name] = $_.Value.value }
  }
  $installed = @{}
  if ($config -and $config.environment) {
    $config.environment.PSObject.Properties |
      ForEach-Object { $installed[$_.Name] = $_.Value }
  }
  foreach ($key in $EnvKeys) {
    $current = Get-UserEnv $key
    if ($null -eq $current) { continue }
    if ($installed.ContainsKey($key) -and $current -ne $installed[$key]) {
      Write-Output "skipped env $key (modified after install, left untouched)"
      continue
    }
    if ($previous.ContainsKey($key)) {
      Set-UserEnv $key $previous[$key]
      Write-Output "restored env $key (previous value)"
    } else {
      Remove-UserEnv $key
      Write-Output "removed env $key"
    }
  }
  # /po slash command backups
  foreach ($p in @((Join-Path $HOME '.zcode\commands\po.md'),
                   (Join-Path $HOME '.zcode\cli\plugins\local\keysmith\commands\po.md'))) {
    Backup-ItemSafe $p
  }
  Invoke-EnvBroadcast
  Write-Output 'uninstall done (backups kept). Fully quit ZCode and reopen.'
  exit 0
}

# ---------------------------------------------------------------- preflight
$zcodeExe = Find-ZCodeExe
if (-not $zcodeExe) {
  Write-Output 'ZCode.exe not found. Pass -ZCodeAppPath "D:\...\ZCode" or set ZCODE_APP_PATH.'
  exit 1
}
$zcodeDir = Split-Path -Parent $zcodeExe
$runtime  = Join-Path $zcodeDir 'resources\glm\zcode.cjs'
if (-not (Test-Path $runtime)) {
  Write-Output "ZCode runtime not found: $runtime"
  exit 1
}
$runtimeText = Get-Content -Raw $runtime
if (-not $runtimeText.Contains('customSystemPrompt')) {
  Write-Output 'runtime entrypoint shape not recognized (customSystemPrompt anchor missing)'
  exit 1
}
$python = Find-Python
if (-not $python) {
  Write-Output 'python not found. Install Python 3.10+ and keep it installed (ZCode launches the wrapper with it).'
  exit 1
}
if (-not (Test-Path $SystemSource)) {
  Write-Output "missing source prompt: $SystemSource"
  exit 1
}

Write-Output "== zcode-keysmith-custom install $(if ($Apply) { '(apply)' } else { '(dry-run)' }) =="
Write-Output "managed_dir: $ManagedDir"
Write-Output "zcode_exe:   $zcodeExe"
Write-Output "python:      $python"
Write-Output "prompt src:  $SystemSource"

# ---------------------------------------------------------------- files
Write-File $SystemFile $SystemSource

$skipTmp = Join-Path $env:TEMP ("zcode-skip-" + [guid]::NewGuid().ToString() + '.txt')
@'
# 不注入的通道关键词（一行一个，子串匹配，改完即生效无需重启）
# offpeak-idle-plan = 官方送的闲时算力通道
# bigmodel-start-plan = 官方送的体验通道
offpeak
start-plan
'@ | Set-Content -Encoding utf8 -Path $skipTmp
Write-File $SkipFile $skipTmp
Remove-Item $skipTmp -Force -ErrorAction SilentlyContinue

Write-File $Wrapper (Join-Path $RepoDir 'bin\zcode-agent-wrapper.py')

# config.json
$configObj = [ordered]@{
  tool_version = 'custom-1.0'
  mode = 'zcode-app-wrapper'
  system_file = $SystemFile
  wrapper = $Wrapper
  env_script = $EnvPs1
  launch_agent = $null
  zcode_runtime = $runtime
  node_command = $zcodeExe
  cache_dir = $CacheDir
  wrapper_log = (Join-Path $LogDir 'wrapper-start.jsonl')
  platform = 'Windows'
}
$configTmp = Join-Path $env:TEMP ("zcode-config-" + [guid]::NewGuid().ToString() + '.json')
$configObj | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -Path $configTmp
Write-File $ConfigFile $configTmp
Remove-Item $configTmp -Force -ErrorAction SilentlyContinue

# env.ps1 (regenerates HKCU values from the recorded install paths)
$envLines = @(
  '$ErrorActionPreference = ''Stop''',
  '$values = [ordered]@{',
  "    ZCODE_AGENT_SERVER_COMMAND = $(PSSingleQuote $python)",
  "    ZCODE_AGENT_SERVER_ARGS_JSON = $(PSSingleQuote (@($Wrapper, 'app-server', '--stdio') | ConvertTo-Json -Compress))",
  "    ZCODE_KEYSMITH_SYSTEM_FILE = $(PSSingleQuote $SystemFile)",
  "    ZCODE_KEYSMITH_ORIGINAL = $(PSSingleQuote $runtime)",
  "    ZCODE_KEYSMITH_NODE_COMMAND = $(PSSingleQuote $zcodeExe)",
  "    ZCODE_KEYSMITH_CACHE_DIR = $(PSSingleQuote $CacheDir)",
  "    ZCODE_KEYSMITH_LOG_DIR = $(PSSingleQuote $LogDir)",
  '}',
  'foreach ($entry in $values.GetEnumerator()) {',
  "    [Environment]::SetEnvironmentVariable(`$entry.Key, `$entry.Value, 'User')",
  '}',
  "Write-Output 'zcode-keysmith-custom Windows environment activated'",
  ''
)
$envTmp = Join-Path $env:TEMP ("zcode-env-" + [guid]::NewGuid().ToString() + '.ps1')
$envLines -join "`r`n" | Set-Content -Encoding utf8 -Path $envTmp
Write-File $EnvPs1 $envTmp
Remove-Item $envTmp -Force -ErrorAction SilentlyContinue

# /po slash commands (mirror the macOS layout under %USERPROFILE%\.zcode)
Write-File (Join-Path $HOME '.zcode\commands\po.md') (Join-Path $RepoDir 'commands\po.md')
$pluginPo = Join-Path $HOME '.zcode\cli\plugins\local\keysmith\commands\po.md'
Write-File $pluginPo (Join-Path $RepoDir 'commands\keysmith-po.md')

if (-not $Apply) {
  Write-Output ''
  Write-Output 'dry-run complete. rerun with -Yes to apply.'
  exit 0
}

# ---------------------------------------------------------------- activate
New-Item -ItemType Directory -Force -Path $LogDir, $CacheDir | Out-Null

# capture previous user env values once, before overwriting (used by uninstall)
$previousEnv = [ordered]@{}
foreach ($key in $EnvKeys) {
  $val = Get-UserEnv $key
  if ($null -ne $val) { $previousEnv[$key] = @{ value = $val } }
}
$configObj.previous_user_environment = $previousEnv
$configObj | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -Path $ConfigFile

# env values
$jsonArgs = @($Wrapper, 'app-server', '--stdio') | ConvertTo-Json -Compress
$envValues = [ordered]@{
  'ZCODE_AGENT_SERVER_COMMAND'   = $python
  'ZCODE_AGENT_SERVER_ARGS_JSON' = $jsonArgs
  'ZCODE_KEYSMITH_SYSTEM_FILE'   = $SystemFile
  'ZCODE_KEYSMITH_ORIGINAL'      = $runtime
  'ZCODE_KEYSMITH_NODE_COMMAND'  = $zcodeExe
  'ZCODE_KEYSMITH_CACHE_DIR'     = $CacheDir
  'ZCODE_KEYSMITH_LOG_DIR'       = $LogDir
}
foreach ($entry in $envValues.GetEnumerator()) {
  Set-UserEnv $entry.Key $entry.Value
}
$configObj.environment = $envValues
$configObj | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -Path $ConfigFile
Invoke-EnvBroadcast

Write-Output ''
Write-Output '== verify =='
Write-Output "ZCODE_AGENT_SERVER_COMMAND = $(Get-UserEnv 'ZCODE_AGENT_SERVER_COMMAND')"
Write-Output "ZCODE_AGENT_SERVER_ARGS_JSON = $(Get-UserEnv 'ZCODE_AGENT_SERVER_ARGS_JSON')"
& $python $Wrapper status

Write-Output ''
Write-Output 'done. Fully quit ZCode (tray icon -> Quit) and reopen; injection starts on the next new task.'
Write-Output 'toggle: /po on | /po off | /po status'
