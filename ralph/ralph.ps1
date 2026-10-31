#Requires -Version 5.1
# Ralph Wiggum - Long-running AI agent loop (Windows port of ralph.sh)
# Usage: .\ralph.ps1 [--tool claude|amp] [--model <alias|id>] [--effort <level>] [--dry-run] [max_iterations]
#
#   --model    passed through to `claude --model` (e.g. opus, sonnet, fable, or a full model id)
#   --effort   passed through to `claude --effort`: low | medium | high | xhigh | max
#   --dry-run  print the resolved command line and exit without running anything
#
# Example: .\ralph.ps1 --model opus --effort high 30

# Emulate `set -e`. Relaxed around the AI tool invocation below.
$ErrorActionPreference = 'Stop'

# --- Helpers ---------------------------------------------------------------

# Windows PowerShell 5.1 writes a BOM with `Set-Content -Encoding utf8` and
# defaults `Add-Content` to the ANSI code page. progress.txt is appended to by
# every iteration, so pin everything to UTF-8 without BOM.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# The same shell pipes text to native commands as ASCII by default (non-ASCII
# prompt text would reach the AI CLI as "?") and decodes the CLI's output with
# the OEM code page. Pin both directions to UTF-8. (PowerShell still prepends a
# BOM to the piped stdin; that is unavoidable here and harmless to the CLI.)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch { }

function Write-TextFile {
  param([string]$Path, [string]$Text)
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

# Equivalent of: jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo ""
function Get-BranchName {
  param([string]$Path)
  try {
    $json = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json
    if ($json.branchName) { return [string]$json.branchName }
  } catch { }
  return ''
}

function Reset-ProgressFile {
  param([string]$Path)
  # Invariant culture so the log reads the same regardless of system locale
  $stamp = (Get-Date).ToString('ddd MMM d HH:mm:ss yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
  Write-TextFile -Path $Path -Text "# Ralph Progress Log`r`nStarted: $stamp`r`n---`r`n"
}

# --- Parse arguments -------------------------------------------------------

$Tool = 'claude'
$MaxIterations = 10
$Model = ''
$Effort = ''
$DryRun = $false
$ValidEfforts = @('low', 'medium', 'high', 'xhigh', 'max')

# Accepts both `--name value` and `--name=value` (and the PowerShell-style `-Name`).
# Returns the value and how many args were consumed, or exits if the value is missing.
function Get-OptionValue {
  param([object[]]$AllArgs, [int]$Index, [string]$Name)
  $arg = [string]$AllArgs[$Index]
  if ($arg.Contains('=')) {
    return @($arg.Substring($arg.IndexOf('=') + 1), 1)
  }
  if ($Index + 1 -ge $AllArgs.Count) {
    Write-Host "Error: --$Name requires a value."
    exit 1
  }
  return @([string]$AllArgs[$Index + 1], 2)
}

$idx = 0
while ($idx -lt $args.Count) {
  $arg = [string]$args[$idx]
  $name = ($arg -replace '^-{1,2}', '') -replace '=.*$', ''

  if ($arg -match '^-{1,2}(tool|model|effort)(=.*)?$') {
    $value, $consumed = Get-OptionValue -AllArgs $args -Index $idx -Name $name.ToLower()
    switch ($name.ToLower()) {
      'tool'   { $Tool = $value }
      'model'  { $Model = $value }
      'effort' { $Effort = $value.ToLower() }
    }
    $idx += $consumed
  }
  elseif ($arg -match '^-{1,2}dry-?run$') {
    $DryRun = $true
    $idx += 1
  }
  elseif ($arg -match '^[0-9]+$') {
    # Assume it's max_iterations if it's a number
    $MaxIterations = [int]$arg
    $idx += 1
  }
  else {
    # Silently ignoring a typo like `--modle` would run the whole loop on the wrong model
    Write-Host "Error: Unknown argument '$arg'."
    exit 1
  }
}

# Validate tool choice
if ($Tool -ne 'amp' -and $Tool -ne 'claude') {
  Write-Host "Error: Invalid tool '$Tool'. Must be 'amp' or 'claude'."
  exit 1
}

if ($Effort -and ($ValidEfforts -notcontains $Effort)) {
  Write-Host "Error: Invalid effort '$Effort'. Must be one of: $($ValidEfforts -join ', ')."
  exit 1
}

# amp has no equivalent flags; failing loudly beats running on a model nobody chose
if ($Tool -eq 'amp' -and ($Model -or $Effort)) {
  Write-Host "Error: --model / --effort are only supported with --tool claude."
  exit 1
}

# On Windows a missing CLI otherwise surfaces as a raw CommandNotFoundException
if (-not $DryRun -and -not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
  $alternative = if ($Tool -eq 'amp') { 'claude' } else { 'amp' }
  Write-Host "Error: '$Tool' not found in PATH. Install it or use --tool $alternative."
  exit 1
}

$ScriptDir      = $PSScriptRoot
$PrdFile        = Join-Path $ScriptDir 'prd.json'
$ProgressFile   = Join-Path $ScriptDir 'progress.txt'
# Codebase Patterns live in their own file so each iteration reads only them, not the
# ever-growing progress log. Archived with the run but NOT reset: patterns carry over.
$PatternsFile   = Join-Path $ScriptDir 'patterns.md'
$ArchiveDir     = Join-Path $ScriptDir 'archive'
$LastBranchFile = Join-Path $ScriptDir '.last-branch'

# --- Resolve the command line -----------------------------------------------

if ($Tool -eq 'amp') {
  $PromptFile = Join-Path $ScriptDir 'prompt.md'
  $ToolArgs   = @('--dangerously-allow-all')
} else {
  # Claude Code: use --dangerously-skip-permissions for autonomous operation, --print for output
  $PromptFile = Join-Path $ScriptDir 'CLAUDE.md'
  $ToolArgs   = @('--dangerously-skip-permissions', '--print')
  if ($Model)  { $ToolArgs += @('--model', $Model) }
  if ($Effort) { $ToolArgs += @('--effort', $Effort) }
}

$ModelLabel  = if ($Model)  { $Model }  else { '(CLI default)' }
$EffortLabel = if ($Effort) { $Effort } else { '(CLI default)' }

# Exit before the archive step below: a dry run must not archive prd.json,
# reset progress.txt or rewrite .last-branch.
if ($DryRun) {
  Write-Host "Dry run - would pipe $PromptFile into:"
  Write-Host "  $Tool $($ToolArgs -join ' ')"
  Write-Host "  model: $ModelLabel  effort: $EffortLabel  max iterations: $MaxIterations"
  exit 0
}

# --- Archive previous run if branch changed --------------------------------

if ((Test-Path -LiteralPath $PrdFile) -and (Test-Path -LiteralPath $LastBranchFile)) {
  $currentBranch = Get-BranchName -Path $PrdFile

  $lastBranch = ''
  try { $lastBranch = ((Get-Content -Raw -Encoding UTF8 -LiteralPath $LastBranchFile) -replace '\s+$', '') } catch { }

  if ($currentBranch -and $lastBranch -and ($currentBranch -ne $lastBranch)) {
    # Archive the previous run
    $date = Get-Date -Format 'yyyy-MM-dd'
    # Strip "ralph/" prefix from branch name for folder
    $folderName = $lastBranch -replace '^ralph/', ''
    $archiveFolder = Join-Path $ArchiveDir "$date-$folderName"

    Write-Host "Archiving previous run: $lastBranch"
    New-Item -ItemType Directory -Force -Path $archiveFolder | Out-Null
    if (Test-Path -LiteralPath $PrdFile)      { Copy-Item -LiteralPath $PrdFile      -Destination $archiveFolder }
    if (Test-Path -LiteralPath $ProgressFile) { Copy-Item -LiteralPath $ProgressFile -Destination $archiveFolder }
    if (Test-Path -LiteralPath $PatternsFile) { Copy-Item -LiteralPath $PatternsFile -Destination $archiveFolder }
    Write-Host "   Archived to: $archiveFolder"

    # Reset progress file for new run
    Reset-ProgressFile -Path $ProgressFile
  }
}

# Track current branch
if (Test-Path -LiteralPath $PrdFile) {
  $currentBranch = Get-BranchName -Path $PrdFile
  if ($currentBranch) {
    Write-TextFile -Path $LastBranchFile -Text "$currentBranch`r`n"
  }
}

# Initialize progress file if it doesn't exist
if (-not (Test-Path -LiteralPath $ProgressFile)) {
  Reset-ProgressFile -Path $ProgressFile
}

# --- Main loop -------------------------------------------------------------

Write-Host "Starting Ralph - Tool: $Tool - Model: $ModelLabel - Effort: $EffortLabel - Max iterations: $MaxIterations"

# NOTE: `for` rather than `1..$MaxIterations` - PowerShell's range operator
# counts DOWN when the upper bound is below 1, so `1..0` would run twice.
for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
  Write-Host ''
  Write-Host '==============================================================='
  Write-Host "  Ralph Iteration $iteration of $MaxIterations ($Tool, model: $ModelLabel, effort: $EffortLabel)"
  Write-Host '==============================================================='

  # Run the selected tool with the ralph prompt.
  # Merging a native command's stderr with 2>&1 wraps each line in an
  # ErrorRecord in Windows PowerShell 5.1, which would abort the loop under
  # 'Stop'. Relaxing the preference here is the equivalent of ralph.sh's `|| true`.
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  $lines = New-Object System.Collections.Generic.List[string]
  try {
    # `Get-Content -Raw | & tool` is the equivalent of both `cat f | tool` and `tool < f`
    Get-Content -Raw -Encoding UTF8 -LiteralPath $PromptFile | & $Tool @ToolArgs 2>&1 | ForEach-Object {
      $line = [string]$_
      $lines.Add($line)
      Write-Host $line
    }
  } catch {
    $lines.Add([string]$_)
    Write-Host ([string]$_)
  } finally {
    $ErrorActionPreference = $previousPreference
  }

  $output = $lines -join "`n"

  # Check for completion signal
  if ($output.Contains('<promise>COMPLETE</promise>')) {
    Write-Host ''
    Write-Host 'Ralph completed all tasks!'
    Write-Host "Completed at iteration $iteration of $MaxIterations"
    exit 0
  }

  Write-Host "Iteration $iteration complete. Continuing..."
  Start-Sleep -Seconds 2
}

Write-Host ''
Write-Host "Ralph reached max iterations ($MaxIterations) without completing all tasks."
Write-Host "Check $ProgressFile for status."
exit 1
