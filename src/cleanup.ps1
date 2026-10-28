<#
.SYNOPSIS
    Smart disk cleanup for Windows with AI-powered recommendations.

.DESCRIPTION
    Scans for development caches, temporary files, and reclaimable space.
    Integrates with corey-coder for intelligent recommendations.
    Part of the free-space-available repo.

.PARAMETER Full
    Scan entire machine (all drives)

.PARAMETER Path
    Scan specific path

.PARAMETER Scan
    Scan default paths from config

.PARAMETER DryRun
    Show what would be deleted/archived without making changes

.PARAMETER Force
    Skip confirmation prompts

.PARAMETER Archive
    Move to archive instead of permanent delete

.PARAMETER Ask
    Ask corey-coder about disk usage

.PARAMETER Explain
    Explain what item number is

.PARAMETER Config
    Show current configuration

.PARAMETER Verbose
    Show detailed output

.EXAMPLE
    .\cleanup.ps1
    # Interactive mode: pick drive, scan, select, delete/archive

.EXAMPLE
    .\cleanup.ps1 -Full
    # Scan entire machine

.EXAMPLE
    .\cleanup.ps1 -Archive
    # Move to archive instead of delete

.EXAMPLE
    .\cleanup.ps1 -Ask "What is node_modules?"
    # Ask corey-coder
#>

[CmdletBinding()]
param(
    [switch]$Full,
    [string]$Path,
    [switch]$Scan,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Archive,
    [string]$Ask,
    [int]$Explain,
    [switch]$Config,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION DEFAULTS
# ═══════════════════════════════════════════════════════════════════════════

$script:Settings = @{
    SCAN_PATHS = "$env:USERPROFILE\Documents\github,$env:USERPROFILE"
    SCAN_ENTIRE_MACHINE = $false
    MIN_AGE_DAYS = 0
    MIN_SIZE_KB = 100
    ARCHIVE_MODE = $false
    ARCHIVE_DIR = "$env:USERPROFILE\.cleanup-archive"
    ARCHIVE_COMPRESS = $true
    ARCHIVE_RETENTION_DAYS = 30
    COREY_ENDPOINT = "http://corey-router.corey-coder.svc.cluster.local:8081"
    COREY_MODEL = "corey-coder:latest"
    COREY_FALLBACK_MODEL = "qwen3.8:latest"
    AI_ENABLED = $true
    SAFE_MODE_ONLY = $false
    REQUIRE_CONFIRMATION = $true
    DRY_RUN_DEFAULT = $false
    EXTRA_CACHE_PATHS = ""
    EXCLUDE_PATHS = "**/node_modules/**/node_modules,**/.git"
    LOG_FILE = "$env:USERPROFILE\.cleanup-dev-caches.log"
    LOG_LEVEL = "INFO"
}

# Load .env file
function Load-EnvFile {
    $envPaths = @(
        "$RepoDir\.env",
        "$env:USERPROFILE\.cleanup-dev-caches.env",
        "$env:USERPROFILE\.config\free-space-available\.env"
    )

    foreach ($envPath in $envPaths) {
        if (Test-Path $envPath) {
            Get-Content $envPath | ForEach-Object {
                $line = $_.Trim()
                if ($line -and -not $line.StartsWith('#')) {
                    $parts = $line -split '=', 2
                    if ($parts.Count -eq 2) {
                        $key = $parts[0].Trim()
                        $value = $parts[1].Trim().Trim('"').Trim("'")
                        # Expand ~ and %USERPROFILE%
                        $value = $value -replace '^~', $env:USERPROFILE
                        $value = [Environment]::ExpandEnvironmentVariables($value)
                        if ($script:Settings.ContainsKey($key)) {
                            # Convert string booleans
                            if ($script:Settings[$key] -is [bool]) {
                                $script:Settings[$key] = $value -eq 'true'
                            } else {
                                $script:Settings[$key] = $value
                            }
                        }
                    }
                }
            }
            break
        }
    }
}

Load-EnvFile

# Apply CLI overrides
if ($Archive) { $script:Settings.ARCHIVE_MODE = $true }
if ($DryRun) { $script:Settings.DRY_RUN_DEFAULT = $true }
if ($Force) { $script:Settings.REQUIRE_CONFIRMATION = $false }
if ($Full) { $script:Settings.SCAN_ENTIRE_MACHINE = $true }

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

function Write-Log { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "[X] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }

function Write-LogFile {
    param([string]$Message)
    if ($script:Settings.LOG_FILE) {
        $logPath = $script:Settings.LOG_FILE -replace '^~', $env:USERPROFILE
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logPath -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
    }
}

function Format-Size {
    param([long]$SizeKB)
    if ($SizeKB -ge 1048576) {
        return "{0:N1}GB" -f ($SizeKB / 1048576)
    } elseif ($SizeKB -ge 1024) {
        return "{0:N1}MB" -f ($SizeKB / 1024)
    } else {
        return "${SizeKB}KB"
    }
}

function Get-DirSizeKB {
    param([string]$Path)
    try {
        $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        return [math]::Floor($size / 1024)
    } catch {
        return 0
    }
}

function Get-SafetyLabel {
    param([int]$Safety)
    switch ($Safety) {
        1 { Write-Host "[SAFE]" -ForegroundColor Green -NoNewline }
        2 { Write-Host "[CAUTION]" -ForegroundColor Yellow -NoNewline }
        3 { Write-Host "[REVIEW]" -ForegroundColor Red -NoNewline }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# COREY-CODER INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════

function Invoke-CoreyQuery {
    param(
        [string]$Question,
        [string]$Context = "General disk cleanup query"
    )

    if (-not $script:Settings.AI_ENABLED) {
        return "AI disabled. Enable with AI_ENABLED=true in .env"
    }

    $body = @{
        model = $script:Settings.COREY_MODEL
        messages = @(
            @{
                role = "system"
                content = "You are a disk cleanup expert. You help users understand what files and caches are safe to delete on Windows/macOS/Linux development machines. Be concise and direct. Context: $Context"
            },
            @{
                role = "user"
                content = $Question
            }
        )
        max_tokens = 500
        temperature = 0.3
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri "$($script:Settings.COREY_ENDPOINT)/v1/chat/completions" `
            -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
        return $response.choices[0].message.content
    } catch {
        # Try fallback
        try {
            $body = @{
                model = $script:Settings.COREY_FALLBACK_MODEL
                messages = @(@{ role = "user"; content = $Question })
                max_tokens = 500
            } | ConvertTo-Json -Depth 10

            $response = Invoke-RestMethod -Uri "$($script:Settings.COREY_ENDPOINT)/v1/chat/completions" `
                -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
            return $response.choices[0].message.content
        } catch {
            return "Unable to reach corey-coder. Check COREY_ENDPOINT in .env"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# FINDINGS STORAGE
# ═══════════════════════════════════════════════════════════════════════════

$script:Findings = [System.Collections.ArrayList]::new()

function Add-Finding {
    param(
        [int]$Safety,
        [string]$Type,
        [long]$SizeKB,
        [string]$Path,
        [string]$Description = ""
    )

    if ($SizeKB -gt $script:Settings.MIN_SIZE_KB) {
        $null = $script:Findings.Add(@{
            Safety = $Safety
            Type = $Type
            SizeKB = $SizeKB
            Path = $Path
            Description = $Description
        })
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# SCANNING FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

function Scan-Pattern {
    param(
        [int]$Safety,
        [string]$Description,
        [string]$Pattern,
        [string]$SearchPath,
        [string]$Explanation = "Regenerates automatically"
    )

    if (-not (Test-Path $SearchPath)) { return }

    Get-ChildItem -Path $SearchPath -Directory -Filter $Pattern -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $sizeKB = Get-DirSizeKB $_.FullName
            Add-Finding -Safety $Safety -Type $Description -SizeKB $sizeKB -Path $_.FullName -Description $Explanation
        }
}

function Scan-Dir {
    param(
        [int]$Safety,
        [string]$Description,
        [string]$Dir,
        [string]$Explanation = "Regenerates automatically"
    )

    if (Test-Path $Dir) {
        $sizeKB = Get-DirSizeKB $Dir
        Add-Finding -Safety $Safety -Type $Description -SizeKB $sizeKB -Path $Dir -Description $Explanation
    }
}

function Scan-Location {
    param([string]$BasePath)

    Write-Info "Scanning: $BasePath"
    Write-Host "  This may take a while for large directories..." -ForegroundColor DarkGray

    # ═══════════════════════════════════════════════════════════════════
    # SAFE - 100% regenerates automatically (safety=1)
    # ═══════════════════════════════════════════════════════════════════

    # JavaScript/Node
    Scan-Pattern 1 "node_modules" "node_modules" $BasePath "npm/yarn dependencies - run 'npm install' to restore"
    Scan-Pattern 1 "Next.js cache (.next)" ".next" $BasePath "Next.js build output"
    Scan-Pattern 1 "Nuxt cache (.nuxt)" ".nuxt" $BasePath "Nuxt.js build output"
    Scan-Pattern 1 "Vite cache" ".vite" $BasePath "Vite build cache"
    Scan-Pattern 1 "Parcel cache" ".parcel-cache" $BasePath "Parcel bundler cache"
    Scan-Pattern 1 "Webpack cache" ".cache" $BasePath "Webpack/bundler cache"
    Scan-Pattern 1 "Turborepo cache" ".turbo" $BasePath "Turborepo monorepo cache"
    Scan-Pattern 1 "Storybook cache" "storybook-static" $BasePath "Storybook build output"
    Scan-Pattern 1 "Jest cache" ".jest-cache" $BasePath "Jest test cache"
    Scan-Pattern 1 "Bower components" "bower_components" $BasePath "Bower dependencies"

    # Python
    Scan-Pattern 1 "Python cache (__pycache__)" "__pycache__" $BasePath "Python bytecode"
    Scan-Pattern 1 "pytest cache" ".pytest_cache" $BasePath "pytest cache"
    Scan-Pattern 1 "mypy cache" ".mypy_cache" $BasePath "mypy type checker cache"
    Scan-Pattern 1 "Ruff cache" ".ruff_cache" $BasePath "Ruff linter cache"
    Scan-Pattern 1 "tox cache" ".tox" $BasePath "tox test environments"

    # Android
    Scan-Pattern 1 "Android NDK cache (.cxx)" ".cxx" $BasePath "Android NDK build cache"
    Scan-Pattern 1 "Gradle cache (.gradle)" ".gradle" $BasePath "Gradle build cache"

    # Rust
    Scan-Pattern 1 "Rust target" "target" $BasePath "Rust/Cargo builds"

    # .NET
    Scan-Pattern 1 ".NET bin" "bin" $BasePath ".NET build output"
    Scan-Pattern 1 ".NET obj" "obj" $BasePath ".NET intermediate files"
    Scan-Pattern 1 "NuGet packages" "packages" $BasePath "NuGet packages"

    # Claude Code
    Scan-Pattern 1 "Claude worktrees" "worktrees" $BasePath "Claude Code git worktrees"

    # System-level caches (when scanning user profile or entire machine)
    if ($BasePath -like "$env:USERPROFILE*" -or $script:Settings.SCAN_ENTIRE_MACHINE) {
        # Package managers
        Scan-Dir 1 "npm cache" "$env:APPDATA\npm-cache" "npm global cache"
        Scan-Dir 1 "yarn cache" "$env:LOCALAPPDATA\Yarn\Cache" "Yarn cache"
        Scan-Dir 1 "pnpm store" "$env:LOCALAPPDATA\pnpm-store" "pnpm store"
        Scan-Dir 1 "Cargo registry" "$env:USERPROFILE\.cargo\registry" "Rust crates"
        Scan-Dir 1 "Cargo git" "$env:USERPROFILE\.cargo\git" "Rust git deps"
        Scan-Dir 1 "Go mod cache" "$env:USERPROFILE\go\pkg\mod" "Go modules"
        Scan-Dir 1 "Gradle global" "$env:USERPROFILE\.gradle\caches" "Gradle global cache"
        Scan-Dir 1 "Maven cache" "$env:USERPROFILE\.m2\repository" "Maven artifacts"
        Scan-Dir 1 "pip cache" "$env:LOCALAPPDATA\pip\Cache" "pip cache"
        Scan-Dir 1 "NuGet cache" "$env:USERPROFILE\.nuget\packages" "NuGet packages"

        # IDE caches
        Scan-Dir 1 "VS Code cache" "$env:APPDATA\Code\Cache" "VS Code cache"
        Scan-Dir 1 "VS Code CachedData" "$env:APPDATA\Code\CachedData" "VS Code cached data"
        Scan-Dir 1 "VS Code CachedExtensions" "$env:APPDATA\Code\CachedExtensionVSIXs" "VS Code extension cache"
        Scan-Dir 1 "JetBrains cache" "$env:LOCALAPPDATA\JetBrains" "JetBrains IDEs"
        Scan-Dir 1 "Visual Studio cache" "$env:LOCALAPPDATA\Microsoft\VisualStudio" "Visual Studio cache"

        # Browser testing
        Scan-Dir 1 "Playwright" "$env:LOCALAPPDATA\ms-playwright" "Playwright browsers"
        Scan-Dir 1 "Cypress" "$env:APPDATA\Cypress\Cache" "Cypress cache"

        # App caches
        Scan-Dir 1 "Spotify cache" "$env:LOCALAPPDATA\Spotify\Data" "Spotify cache"
        Scan-Dir 1 "Discord cache" "$env:APPDATA\discord\Cache" "Discord cache"
        Scan-Dir 1 "Teams cache" "$env:APPDATA\Microsoft\Teams\Cache" "Teams cache"
        Scan-Dir 1 "Slack cache" "$env:APPDATA\Slack\Cache" "Slack cache"

        # ═══════════════════════════════════════════════════════════════════
        # CAUTION - Usually safe but verify (safety=2)
        # ═══════════════════════════════════════════════════════════════════

        Scan-Dir 2 "Chrome cache" "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache" "Chrome cache"
        Scan-Dir 2 "Edge cache" "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache" "Edge cache"
        Scan-Dir 2 "Firefox cache" "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles" "Firefox profiles"
        Scan-Dir 2 "Windows Temp" "$env:TEMP" "Windows temp files"
        Scan-Dir 2 "Windows Temp (System)" "C:\Windows\Temp" "System temp files"

        # ═══════════════════════════════════════════════════════════════════
        # REVIEW - Check before deleting (safety=3)
        # ═══════════════════════════════════════════════════════════════════

        Scan-Dir 3 "Recycle Bin" "C:\`$Recycle.Bin" "Deleted files"
        Scan-Dir 3 "Downloads" "$env:USERPROFILE\Downloads" "Downloads folder"

        # Virtual environments
        Scan-Pattern 3 "Python venv" ".venv" $BasePath "Virtual environment"
        Scan-Pattern 3 "Python venv" "venv" $BasePath "Virtual environment"
    }

    # Docker (if available)
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        try {
            $dockerInfo = docker system df --format "{{.Reclaimable}}" 2>$null | Select-Object -First 1
            if ($dockerInfo) {
                $sizeKB = 0
                if ($dockerInfo -match '(\d+\.?\d*)GB') { $sizeKB = [long]($Matches[1] * 1048576) }
                elseif ($dockerInfo -match '(\d+\.?\d*)MB') { $sizeKB = [long]($Matches[1] * 1024) }
                elseif ($dockerInfo -match '(\d+\.?\d*)kB') { $sizeKB = [long]$Matches[1] }

                if ($sizeKB -gt 100) {
                    Add-Finding -Safety 2 -Type "Docker reclaimable" -SizeKB $sizeKB -Path "SYSTEM:docker" -Description "Use 'docker system prune -a'"
                }
            }
        } catch { }
    }
}

function Get-AllDrives {
    Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Used -gt 0 -and $_.Root -match "^[A-Z]:\\"
    } | ForEach-Object { $_.Root }
}

function Show-Drives {
    Write-Host ""
    Write-Host "Available Drives:" -ForegroundColor White -NoNewline
    Write-Host ""
    Write-Host ""
    Write-Host ("  {0,-4} {1,-25} {2,12} {3,12} {4,10}" -f "#", "Drive", "Size", "Used", "Free") -ForegroundColor White
    Write-Host ("  {0,-4} {1,-25} {2,12} {3,12} {4,10}" -f "----", "-------------------------", "------------", "------------", "----------")

    $script:AvailableVolumes = @()
    $idx = 1

    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } | ForEach-Object {
        $total = $_.Used + $_.Free
        $totalGB = "{0:N1}GB" -f ($total / 1GB)
        $usedGB = "{0:N1}GB" -f ($_.Used / 1GB)
        $freeGB = "{0:N1}GB" -f ($_.Free / 1GB)

        $script:AvailableVolumes += $_.Root
        Write-Host ("  [{0}]  {1,-25} {2,12} {3,12} {4,10}" -f $idx, "$($_.Name): ($($_.Description))", $totalGB, $usedGB, $freeGB) -ForegroundColor Cyan
        $idx++
    }

    # Quick scan locations
    Write-Host ""
    Write-Host "  Quick scan locations:" -ForegroundColor White

    $scanPaths = $script:Settings.SCAN_PATHS -split ','
    foreach ($p in $scanPaths) {
        $p = $p.Trim() -replace '^~', $env:USERPROFILE
        $p = [Environment]::ExpandEnvironmentVariables($p)
        if (Test-Path $p) {
            $script:AvailableVolumes += $p
            $displayPath = $p -replace [regex]::Escape($env:USERPROFILE), '~'
            Write-Host ("  [{0}]  {1}" -f $idx, $displayPath) -ForegroundColor Cyan
            $idx++
        }
    }

    Write-Host ""
    Write-Host "  [a]  All of the above" -ForegroundColor Cyan
    Write-Host "  [f]  Full machine scan (all drives)" -ForegroundColor Cyan
    Write-Host "  [q]  Quit" -ForegroundColor Cyan
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════
# ARCHIVE/DELETE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

function Archive-Path {
    param([string]$SrcPath)

    $archiveBase = $script:Settings.ARCHIVE_DIR -replace '^~', $env:USERPROFILE

    # Create archive directory
    if (-not (Test-Path $archiveBase)) {
        New-Item -ItemType Directory -Path $archiveBase -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $basename = Split-Path -Leaf $SrcPath
    $archiveName = "${timestamp}_${basename}"

    if ($script:Settings.ARCHIVE_COMPRESS) {
        # Compress to zip
        $archiveFile = Join-Path $archiveBase "$archiveName.zip"
        Compress-Archive -Path $SrcPath -DestinationPath $archiveFile -Force
        Remove-Item -Path $SrcPath -Recurse -Force
        return $archiveFile
    } else {
        # Just move
        $archiveDest = Join-Path $archiveBase $archiveName
        Move-Item -Path $SrcPath -Destination $archiveDest -Force
        return $archiveDest
    }
}

function Remove-OldArchives {
    if ($script:Settings.ARCHIVE_RETENTION_DAYS -gt 0) {
        $archiveBase = $script:Settings.ARCHIVE_DIR -replace '^~', $env:USERPROFILE
        if (Test-Path $archiveBase) {
            $cutoffDate = (Get-Date).AddDays(-$script:Settings.ARCHIVE_RETENTION_DAYS)
            Get-ChildItem -Path $archiveBase -File | Where-Object { $_.LastWriteTime -lt $cutoffDate } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-CacheType {
    param([string]$Type)

    $deleted = 0

    $script:Findings | Where-Object { $_.Type -eq $Type } | ForEach-Object {
        # Skip if SAFE_MODE_ONLY and not safe
        if ($script:Settings.SAFE_MODE_ONLY -and $_.Safety -ne 1) {
            return
        }

        $path = $_.Path

        if ($path -eq "SYSTEM:docker") {
            Write-Info "Running docker system prune..."
            docker system prune -af 2>$null
            $deleted += $_.SizeKB
            Write-LogFile "Ran docker system prune"
        }
        elseif (Test-Path $path) {
            if ($script:Settings.ARCHIVE_MODE) {
                $archiveDest = Archive-Path $path
                $deleted += $_.SizeKB
                if ($Verbose) {
                    Write-Log "Archived: $path -> $archiveDest"
                }
                Write-LogFile "Archived: $path -> $archiveDest"
            }
            else {
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                $deleted += $_.SizeKB
                if ($Verbose) {
                    Write-Log "Deleted: $path"
                }
                Write-LogFile "Deleted: $path"
            }
        }
    }

    # Special cleanup for npm
    if ($Type -eq "npm cache") {
        npm cache clean --force 2>$null
    }

    return $deleted
}

# ═══════════════════════════════════════════════════════════════════════════
# SHOW CONFIG
# ═══════════════════════════════════════════════════════════════════════════

if ($Config) {
    Write-Host ""
    Write-Host "Current Configuration:" -ForegroundColor White
    Write-Host ""
    Write-Host "  Scan Paths:          $($script:Settings.SCAN_PATHS)"
    Write-Host "  Scan Entire Machine: $($script:Settings.SCAN_ENTIRE_MACHINE)"
    Write-Host "  Archive Mode:        $($script:Settings.ARCHIVE_MODE)"
    Write-Host "  Archive Dir:         $($script:Settings.ARCHIVE_DIR)"
    Write-Host "  Archive Compress:    $($script:Settings.ARCHIVE_COMPRESS)"
    Write-Host "  Archive Retention:   $($script:Settings.ARCHIVE_RETENTION_DAYS) days"
    Write-Host "  AI Enabled:          $($script:Settings.AI_ENABLED)"
    Write-Host "  Corey Endpoint:      $($script:Settings.COREY_ENDPOINT)"
    Write-Host "  Corey Model:         $($script:Settings.COREY_MODEL)"
    Write-Host "  Safe Mode Only:      $($script:Settings.SAFE_MODE_ONLY)"
    Write-Host "  Min Size:            $($script:Settings.MIN_SIZE_KB) KB"
    Write-Host ""
    Write-Host "  Config files checked:"
    Write-Host "    - $RepoDir\.env"
    Write-Host "    - $env:USERPROFILE\.cleanup-dev-caches.env"
    Write-Host "    - $env:USERPROFILE\.config\free-space-available\.env"
    Write-Host ""
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# HANDLE --ASK
# ═══════════════════════════════════════════════════════════════════════════

if ($Ask) {
    Write-Host ""
    Write-Host "Asking corey-coder..." -ForegroundColor White
    Write-Host ""
    Write-Host (Invoke-CoreyQuery -Question $Ask)
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "+==============================================================+" -ForegroundColor Cyan
Write-Host "|       Free Space Available - Smart Disk Cleanup              |" -ForegroundColor Cyan
Write-Host "|                 Powered by corey-coder                       |" -ForegroundColor Cyan
Write-Host "+==============================================================+" -ForegroundColor Cyan
Write-Host ""

# Show mode
if ($script:Settings.ARCHIVE_MODE) {
    Write-Info "Mode: ARCHIVE (files moved to $($script:Settings.ARCHIVE_DIR))"
} else {
    Write-Info "Mode: DELETE (permanent removal)"
}

# Current disk usage
Write-Info "Current disk usage:"
$mainDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
$usedGB = "{0:N1}GB" -f ($mainDrive.Used / 1GB)
$totalGB = "{0:N1}GB" -f (($mainDrive.Used + $mainDrive.Free) / 1GB)
$freeGB = "{0:N1}GB" -f ($mainDrive.Free / 1GB)
$pct = [math]::Round(($mainDrive.Used / ($mainDrive.Used + $mainDrive.Free)) * 100)
Write-Host "  Used: $usedGB / $totalGB ($pct% full), Available: $freeGB"
Write-Host ""

# Clean old archives
if ($script:Settings.ARCHIVE_MODE) {
    Remove-OldArchives
}

# Drive selection
$scanPaths = @()

if ($Path) {
    $scanPaths += $Path
}
elseif ($script:Settings.SCAN_ENTIRE_MACHINE) {
    Write-Warn "Full machine scan - this may take a while..."
    $scanPaths = Get-AllDrives
}
elseif ($Scan) {
    $scanPaths = $script:Settings.SCAN_PATHS -split ',' | ForEach-Object {
        $p = $_.Trim() -replace '^~', $env:USERPROFILE
        [Environment]::ExpandEnvironmentVariables($p)
    }
}
else {
    Show-Drives

    $selection = Read-Host "Select drive/location to scan"

    switch ($selection.ToLower()) {
        'q' { Write-Warn "Aborted."; exit 0 }
        'a' { $scanPaths = $script:AvailableVolumes }
        'f' {
            Write-Warn "Full machine scan - this may take a while..."
            $scanPaths = Get-AllDrives
        }
        default {
            if ($selection -match '^\d+$') {
                $idx = [int]$selection - 1
                if ($idx -ge 0 -and $idx -lt $script:AvailableVolumes.Count) {
                    $scanPaths += $script:AvailableVolumes[$idx]
                } else {
                    Write-Err "Invalid selection"
                    exit 1
                }
            } else {
                Write-Err "Invalid selection"
                exit 1
            }
        }
    }
}

Write-Host ""

# Scanning
foreach ($path in $scanPaths) {
    if (Test-Path $path) {
        Scan-Location $path
    }
}

if ($script:Findings.Count -eq 0) {
    Write-Host ""
    Write-Log "No caches found to clean!"
    exit 0
}

# Calculate totals
$totalKB = 0; $safeKB = 0; $cautionKB = 0; $reviewKB = 0

foreach ($f in $script:Findings) {
    $totalKB += $f.SizeKB
    switch ($f.Safety) {
        1 { $safeKB += $f.SizeKB }
        2 { $cautionKB += $f.SizeKB }
        3 { $reviewKB += $f.SizeKB }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "                    SCAN RESULTS                               " -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""

Write-Host "Summary:" -ForegroundColor White
Write-Host "  " -NoNewline; Write-Host "[SAFE]" -ForegroundColor Green -NoNewline; Write-Host "     $(Format-Size $safeKB) - 100% safe"
Write-Host "  " -NoNewline; Write-Host "[CAUTION]" -ForegroundColor Yellow -NoNewline; Write-Host "  $(Format-Size $cautionKB) - Usually safe"
Write-Host "  " -NoNewline; Write-Host "[REVIEW]" -ForegroundColor Red -NoNewline; Write-Host "   $(Format-Size $reviewKB) - Check first"
Write-Host "  TOTAL      $(Format-Size $totalKB)" -ForegroundColor White
Write-Host ""

# Group by type
$grouped = $script:Findings | Group-Object -Property Type | Sort-Object { ($_.Group | Measure-Object -Property SizeKB -Sum).Sum } -Descending

Write-Host ("  {0,-4} {1,-12} {2,-30} {3,10} {4,6}" -f "#", "Safety", "Type", "Size", "Items") -ForegroundColor White
Write-Host ("  {0,-4} {1,-12} {2,-30} {3,10} {4,6}" -f "----", "------------", "------------------------------", "----------", "------")

$menuNum = 1
$menuTypes = @()
$menuSafety = @()
$menuDescs = @()

foreach ($group in $grouped) {
    $typeSize = ($group.Group | Measure-Object -Property SizeKB -Sum).Sum
    $typeSafety = $group.Group[0].Safety
    $typeDesc = $group.Group[0].Description
    $count = $group.Count

    $menuTypes += $group.Name
    $menuSafety += $typeSafety
    $menuDescs += $typeDesc

    Write-Host "  " -NoNewline
    Write-Host "[" -NoNewline -ForegroundColor Cyan
    Write-Host ("{0,2}" -f $menuNum) -NoNewline -ForegroundColor Cyan
    Write-Host "] " -NoNewline -ForegroundColor Cyan
    Get-SafetyLabel $typeSafety
    Write-Host (" {0,-30} {1,10} {2,6}" -f $group.Name, (Format-Size $typeSize), $count)

    $menuNum++
}

Write-Host ""

# Handle --Explain
if ($Explain -gt 0) {
    $idx = $Explain - 1
    if ($idx -ge 0 -and $idx -lt $menuTypes.Count) {
        Write-Host "Explanation for: $($menuTypes[$idx])" -ForegroundColor White
        Write-Host "  Safety: " -NoNewline; Get-SafetyLabel $menuSafety[$idx]; Write-Host ""
        Write-Host "  Description: $($menuDescs[$idx])"
        Write-Host ""
        if ($script:Settings.AI_ENABLED) {
            Write-Info "Asking corey-coder..."
            Write-Host (Invoke-CoreyQuery -Question "What is '$($menuTypes[$idx])'? Is it safe to delete?" -Context "Type: $($menuTypes[$idx]), Desc: $($menuDescs[$idx])")
        }
    }
    exit 0
}

if ($Verbose) {
    Write-Host "All directories:" -ForegroundColor White
    foreach ($f in $script:Findings) {
        Write-Host ("  {0,10}  " -f (Format-Size $f.SizeKB)) -NoNewline
        Get-SafetyLabel $f.Safety
        Write-Host "  $($f.Path)"
    }
    Write-Host ""
}

Write-Host "Recommendations:" -ForegroundColor White
if ($safeKB -gt 0) {
    $action = if ($script:Settings.ARCHIVE_MODE) { "Archive" } else { "Delete" }
    Write-Host "  " -NoNewline; Write-Host "->" -ForegroundColor Green -NoNewline
    Write-Host " $action all " -NoNewline; Write-Host "[SAFE]" -ForegroundColor Green -NoNewline; Write-Host " items: $(Format-Size $safeKB) (enter 'r')"
}
Write-Host ""

if ($script:Settings.DRY_RUN_DEFAULT) {
    Write-Warn "DRY RUN - no changes made."
    exit 0
}

Write-Host "Select what to clean:" -ForegroundColor White
Write-Host "  Enter numbers (1 3 5), 'r' for recommended, 'a' for all, 'q' to quit" -ForegroundColor DarkGray
Write-Host ""

if ($Force) {
    $selection = "r"
    Write-Host "Selection: r (-Force mode)"
} else {
    $selection = Read-Host "Selection"
}

if ($selection -eq 'q' -or $selection -eq 'Q') {
    Write-Warn "Aborted."
    exit 0
}

$selectedTypes = @()

switch ($selection.ToLower()) {
    'r' {
        for ($i = 0; $i -lt $menuSafety.Count; $i++) {
            if ($menuSafety[$i] -eq 1) {
                $selectedTypes += $menuTypes[$i]
            }
        }
    }
    'a' { $selectedTypes = $menuTypes }
    default {
        foreach ($num in ($selection -split '\s+')) {
            if ($num -match '^\d+$') {
                $idx = [int]$num - 1
                if ($idx -ge 0 -and $idx -lt $menuTypes.Count) {
                    $selectedTypes += $menuTypes[$idx]
                }
            }
        }
    }
}

if ($selectedTypes.Count -eq 0) {
    Write-Warn "Nothing selected."
    exit 0
}

Write-Host ""
$actionWord = if ($script:Settings.ARCHIVE_MODE) { "archive" } else { "delete" }
Write-Host "Will ${actionWord}:" -ForegroundColor White

$selectedTotal = 0
foreach ($type in $selectedTypes) {
    $typeFindings = $script:Findings | Where-Object { $_.Type -eq $type }
    $typeSize = ($typeFindings | Measure-Object -Property SizeKB -Sum).Sum
    $typeSafety = $typeFindings[0].Safety

    Write-Host "  " -NoNewline
    Get-SafetyLabel $typeSafety
    Write-Host " $type ($(Format-Size $typeSize))"
    $selectedTotal += $typeSize
}

Write-Host ""
Write-Host "  Total: $(Format-Size $selectedTotal)" -ForegroundColor White
Write-Host ""

if ($script:Settings.REQUIRE_CONFIRMATION -and -not $Force) {
    $confirm = Read-Host "Proceed? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Warn "Aborted."
        exit 0
    }
}

Write-Host ""
Write-Info "Processing..."

$deletedKB = 0
foreach ($type in $selectedTypes) {
    Write-Info "Cleaning: $type"
    $freed = Remove-CacheType $type
    $deletedKB += $freed
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor White

if ($script:Settings.ARCHIVE_MODE) {
    Write-Log "Archived: $(Format-Size $deletedKB) to $($script:Settings.ARCHIVE_DIR)"
} else {
    Write-Log "Reclaimed: $(Format-Size $deletedKB)"
}

Write-Host ""
Write-Info "Updated disk usage:"
$mainDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
$usedGB = "{0:N1}GB" -f ($mainDrive.Used / 1GB)
$totalGB = "{0:N1}GB" -f (($mainDrive.Used + $mainDrive.Free) / 1GB)
$freeGB = "{0:N1}GB" -f ($mainDrive.Free / 1GB)
$pct = [math]::Round(($mainDrive.Used / ($mainDrive.Used + $mainDrive.Free)) * 100)
Write-Host "  Used: $usedGB / $totalGB ($pct% full), Available: $freeGB"
Write-Host ""
Write-Log "Done!"
