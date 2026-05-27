<#
.SYNOPSIS
Installs an appropriate Windows SDK and analyzes the newest BSOD dump files.

.DESCRIPTION
Detects the current OS build, selects a recommended Windows SDK target, attempts
an unattended install (winget first, then SDK web installer), and analyzes the
latest crash dump files using CDB from the Windows SDK Debugging Tools.

SDK installation behavior is controlled by the -SdkInstallMode parameter.
If not provided, falls back to the $env:requiredSdkInstallation environment
variable. Accepts "Force" or "Skip". Defaults to "Force" if neither is set.

.PARAMETER DumpCount
How many of the newest dump files to analyze. Valid range 1-5. Default is 3.

.PARAMETER SymbolsPath
Local symbol cache folder.

.PARAMETER SdkInstallMode
Controls SDK installation. 'Force' always installs, 'Skip' bypasses entirely.
Falls back to $env:requiredSdkInstallation if omitted.

.EXAMPLE
.\Analyze-BSODs.ps1 -Verbose

.EXAMPLE
.\Analyze-BSODs.ps1 -DumpCount 2 -SdkInstallMode Skip
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateRange(1, 5)]
    [int]$DumpCount = 5,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SymbolsPath = 'C:\Windows\Temp\WinDbgSymbols',

    [Parameter()]
    [ValidateSet('Force', 'Skip')]
    [string]$SdkInstallMode,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WysiwygFieldName = 'blueScreenHistory'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    throw 'This script requires Windows (Windows SDK and crash dump analysis).'
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsBuildInfo {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    [PSCustomObject]@{
        Caption     = $os.Caption
        Version     = $os.Version
        BuildNumber = [int]$os.BuildNumber
    }
}

function Get-RecommendedSdkTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$OsInfo
    )

    $build = $OsInfo.BuildNumber
    if ($build -ge 26100) {
        return [PSCustomObject]@{
            SdkVersion  = '10.0.26100'
            WingetIds   = @('Microsoft.WindowsSDK.10.0.26100')
            DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=2272610'
        }
    }

    if ($build -ge 22621) {
        return [PSCustomObject]@{
            SdkVersion  = '10.0.22621'
            WingetIds   = @('Microsoft.WindowsSDK.10.0.22621')
            DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=2196241'
        }
    }

    if ($build -ge 22000) {
        return [PSCustomObject]@{
            SdkVersion  = '10.0.22000'
            WingetIds   = @('Microsoft.WindowsSDK.10.0.22000')
            DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=2166460'
        }
    }

    return [PSCustomObject]@{
        SdkVersion  = '10.0.19041'
        WingetIds   = @('Microsoft.WindowsSDK.10.0.19041')
        DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=2120843'
    }
}

function Get-CdbPath {
    [CmdletBinding()]
    param()

    $candidatePaths = @(
        'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe',
        'C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe',
        'C:\Program Files\Windows Kits\10\Debuggers\arm64\cdb.exe'
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -Path $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }

    return $null
}

function Install-SdkWithWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$WingetIds
    )

    $resolveWingetPath = Resolve-Path "$env:ProgramW6432\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue
    if (-not $resolveWingetPath) {
        Write-Verbose 'winget.exe not found in WindowsApps (PATH is not populated in SYSTEM context); skipping winget install.'
        return $false
    }
    $wingetCommand = $resolveWingetPath[-1].Path

    foreach ($id in $WingetIds) {
        Write-Verbose "Trying winget install for package ID: $id"

        $arguments = @(
            'install',
            '--id', $id,
            '--exact',
            '--silent',
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--disable-interactivity'
        )

        $process = Start-Process -FilePath $wingetCommand -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        # 0 = success; 3010 = success, reboot required
        if ($process.ExitCode -in @(0, 3010)) {
            Write-Verbose "winget installed SDK package ID: $id (exit $($process.ExitCode))"
            return $true
        }

        Write-Verbose "winget install failed for $id with exit code $($process.ExitCode)."
    }

    return $false
}

function Install-SdkWithBootstrapper {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DownloadUrl
    )

    $downloadPath = Join-Path -Path $env:TEMP -ChildPath 'winsdksetup.exe'

    try {
        Write-Verbose "Downloading Windows SDK bootstrapper from $DownloadUrl"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloadPath -UseBasicParsing -TimeoutSec 120

        $arguments = '/features OptionId.WindowsDesktopDebuggers /quiet /norestart'
        $process = Start-Process -FilePath $downloadPath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

        # 0 = success; 3010 = success, reboot required
        if ($process.ExitCode -in @(0, 3010)) {
            Write-Verbose "SDK bootstrapper install completed (exit $($process.ExitCode))."
            return $true
        }

        Write-Verbose "SDK bootstrapper install failed with exit code $($process.ExitCode)."
        return $false
    } finally {
        if (Test-Path -Path $downloadPath -PathType Leaf) {
            Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-LatestDumpFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Count
    )

    $miniDumpPath = 'C:\Windows\Minidump'
    $kernelDumpPath = 'C:\Windows\MEMORY.DMP'

    $dumpFiles = @(
        if (Test-Path -Path $miniDumpPath -PathType Container) {
            Get-ChildItem -Path $miniDumpPath -Filter '*.dmp' -File -ErrorAction SilentlyContinue
        }
        if (Test-Path -Path $kernelDumpPath -PathType Leaf) {
            Get-Item -Path $kernelDumpPath -ErrorAction SilentlyContinue
        }
    )

    return $dumpFiles |
    Sort-Object -Property LastWriteTime -Descending |
    Select-Object -First $Count
}

function Get-AnalysisField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$FieldName
    )

    if (-not $Lines) { return $null }

    foreach ($line in $Lines) {
        if ($line -and $line -match ('^\s*' + [regex]::Escape($FieldName) + ':\s+(\S.*)')) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function ConvertTo-BsodHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object[]]$Results
    )

    if (-not $Results -or $Results.Count -eq 0) {
        return '<p>No BSOD dump files found on this device.</p>'
    }

    $entries = foreach ($r in $Results) {
        $fields = [ordered]@{
            'Bug Check'   = $r.BugCheck
            'Crash Time'  = $r.CrashTime
            'Uptime'      = $r.SystemUptimeAtCrashTime
            'Driver'      = $r.FaultingDriver
            'Driver Ver'  = $r.DriverVersion
            'Symbol'      = $r.SymbolName
            'Process'     = $r.ProcessName
            'Hardware ID' = $r.HardwareId
            'Bucket'      = $r.FailureBucket
            'Args'        = $r.BugCheckArgs
            'Dump File'   = $r.DumpFile
        }

        $tableRows = foreach ($key in $fields.Keys) {
            $val = if ($fields[$key]) { [System.Net.WebUtility]::HtmlEncode($fields[$key]) } else { continue }
            "<tr><td style=`"white-space: nowrap; font-weight: bold; padding-right: 8px;`">$key</td><td style=`"word-break: break-all;`">$val</td></tr>"
        }

        $title = if ($r.BugCheck) { [System.Net.WebUtility]::HtmlEncode($r.BugCheck) } else { 'Unknown' }

        @"
<div class="card" style="margin-bottom: 8px;">
<div class="card-title-box"><div class="card-title"><i class="fas fa-circle-exclamation"></i>&nbsp;&nbsp;$title</div></div>
<div class="card-body"><table style="width: 100%; border-collapse: collapse;">
$($tableRows -join "`n")
</table></div>
</div>
"@
    }

    return $entries -join "`n"
}

function Invoke-DumpAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CdbPath,

        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$DumpFiles,

        [Parameter(Mandatory)]
        [string]$SymbolsPath
    )

    if (-not (Test-Path -Path $SymbolsPath -PathType Container)) {
        New-Item -Path $SymbolsPath -ItemType Directory -Force | Out-Null
    }

    $symbolPath = "srv*$SymbolsPath*https://msdl.microsoft.com/download/symbols"
    $reportRoot = Join-Path -Path $env:TEMP -ChildPath ('BsodAnalysis_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -Path $reportRoot -ItemType Directory -Force | Out-Null

    # CDB command sequence:
    #   !analyze -v  - verbose automated crash analysis (sets thread/frame context)
    #   .bugcheck    - formatted display of bug check code and parameters
    #   kv           - call stack with frame pointer omission info
    #   lm           - list loaded modules (identifies third-party drivers)
    #   q            - quit
    $analysisCommand = '!analyze -v; .bugcheck; kv; lm; q'

    $results = foreach ($dumpFile in $DumpFiles) {
        $safeName = $dumpFile.Name -replace '[^a-zA-Z0-9._-]', '_'
        $logPath = Join-Path -Path $reportRoot -ChildPath ($safeName + '.analysis.txt')

        Write-Verbose "Analyzing dump file: $($dumpFile.FullName)"

        # Build a single quoted argument string — required in PS 5.1 where Start-Process
        # does NOT auto-quote array elements that contain spaces.
        $argumentString = "-y `"$symbolPath`" -z `"$($dumpFile.FullName)`" -logo `"$logPath`" -c `"$analysisCommand`""

        $process = Start-Process -FilePath $CdbPath -ArgumentList $argumentString -PassThru -WindowStyle Hidden
        $completed = $process.WaitForExit(300000)  # 5-minute timeout
        if (-not $completed) {
            Write-Warning "CDB timed out analyzing '$($dumpFile.Name)'; terminating the process."
            try { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
            catch { Write-Verbose "Process already exited before Kill(): $($_.Exception.Message)" }
        }
        $exitCode = if ($completed) { $process.ExitCode } else { -1 }

        $bugCheck = $null
        $faultingDriver = $null
        $driverVersion = $null
        $failureBucket = $null
        $symbolName = $null
        $processName = $null
        $hardwareId = $null
        $crashTime = $null
        $systemUptime = $null
        $bugCheckArgs = $null

        if (Test-Path -Path $logPath -PathType Leaf) {
            $logContent = Get-Content -Path $logPath -Raw

            if ($logContent) {
                $logLines = $logContent -split '\r?\n'

                # Match the human-readable bugcheck name, e.g. "DRIVER_POWER_STATE_FAILURE (9f)"
                $bugCheckNameLine = $logLines | Where-Object { $_ -cmatch '^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+\s+\([0-9a-fA-F]+\)' } | Select-Object -First 1
                if ($bugCheckNameLine) {
                    $bugCheck = $bugCheckNameLine.Trim()
                } else {
                    $bugCheck = Get-AnalysisField -Lines $logLines -FieldName 'BUGCHECK_STR'
                }

                $faultingDriver = Get-AnalysisField -Lines $logLines -FieldName 'IMAGE_NAME'
                $driverVersion = Get-AnalysisField -Lines $logLines -FieldName 'IMAGE_VERSION'
                $failureBucket = Get-AnalysisField -Lines $logLines -FieldName 'FAILURE_BUCKET_ID'
                $symbolName = Get-AnalysisField -Lines $logLines -FieldName 'SYMBOL_NAME'
                $processName = Get-AnalysisField -Lines $logLines -FieldName 'PROCESS_NAME'
                $hardwareId = Get-AnalysisField -Lines $logLines -FieldName 'HARDWARE_ID'

                if ($logContent -match 'Debug session time:\s*(.+)') {
                    $crashTime = $Matches[1].Trim()
                }
                if ($logContent -match 'System Uptime:\s*(.+)') {
                    $systemUptime = $Matches[1].Trim()
                }

                # Bugcheck arguments (Arg1 through Arg4)
                $argLines = $logLines | Where-Object { $_ -match '^\s*Arg[1-4]:\s+' } | ForEach-Object { $_.Trim() }
                if ($argLines) {
                    $bugCheckArgs = $argLines -join '; '
                }
            }
        }

        [PSCustomObject]@{
            DumpFile                = $dumpFile.FullName
            LogPath                 = $logPath
            LastWriteTime           = $dumpFile.LastWriteTime
            CrashTime               = $crashTime
            SystemUptimeAtCrashTime = $systemUptime
            AnalyzerExit            = $exitCode
            BugCheck                = $bugCheck
            BugCheckArgs            = $bugCheckArgs
            FaultingDriver          = $faultingDriver
            DriverVersion           = $driverVersion
            SymbolName              = $symbolName
            ProcessName             = $processName
            HardwareId              = $hardwareId
            FailureBucket           = $failureBucket
        }
    }

    return [PSCustomObject]@{
        ReportDirectory = $reportRoot
        Results         = $results
    }
}

try {
    $osInfo = Get-OsBuildInfo
    $sdkTarget = Get-RecommendedSdkTarget -OsInfo $osInfo

    Write-Output ('Detected OS: {0} ({1}, build {2})' -f $osInfo.Caption, $osInfo.Version, $osInfo.BuildNumber)
    Write-Output ('Recommended SDK target: {0}' -f $sdkTarget.SdkVersion)

    $cdbPath = Get-CdbPath

    $sdkMode = if ($SdkInstallMode) { $SdkInstallMode } elseif ($env:requiredSdkInstallation) { $env:requiredSdkInstallation } else { 'Force' }
    if ($sdkMode -notin @('Force', 'Skip')) {
        throw "Invalid SDK install mode '$sdkMode'. Must be 'Force' or 'Skip'."
    }
    Write-Verbose "SDK installation mode: $sdkMode"

    if ($sdkMode -eq 'Skip') {
        Write-Verbose 'SDK installation skipped.'
    } else {
        if (-not $cdbPath) {
            if (-not (Test-IsAdministrator)) {
                throw 'SDK installation requires running PowerShell as Administrator. Use -SdkInstallMode Skip or set $env:requiredSdkInstallation = "Skip" to bypass.'
            }

            if ($PSCmdlet.ShouldProcess('Windows SDK', 'Install SDK with Debugging Tools for Windows')) {
                $installed = Install-SdkWithWinget -WingetIds $sdkTarget.WingetIds
                if (-not $installed) {
                    Write-Verbose 'winget installation did not succeed; trying SDK bootstrapper fallback.'
                    $installed = Install-SdkWithBootstrapper -DownloadUrl $sdkTarget.DownloadUrl
                }

                if (-not $installed) {
                    throw 'Failed to install Windows SDK with both winget and bootstrapper methods.'
                }
            }

            $cdbPath = Get-CdbPath
            if (-not $cdbPath) {
                throw 'Windows SDK installation finished, but cdb.exe was not found. Ensure Debugging Tools for Windows is installed.'
            }
        } else {
            Write-Output ('SDK debug tools already present: {0}' -f $cdbPath)
        }
    }

    if (-not $cdbPath) {
        throw 'cdb.exe was not found. Install Windows SDK Debugging Tools or use -SdkInstallMode Force.'
    }

    $latestDumps = Get-LatestDumpFiles -Count $DumpCount
    if (-not $latestDumps -or $latestDumps.Count -eq 0) {
        Write-Warning 'No dump files found in C:\Windows\Minidump or C:\Windows\MEMORY.DMP.'
        try {
            Set-NinjaProperty -Name $WysiwygFieldName -Value (ConvertTo-BsodHtml -Results $null) -Type 'WYSIWYG'
        } catch {
            Write-Verbose "Unable to write to NinjaOne WYSIWYG field: $($_.Exception.Message)"
        }
        return
    }

    Write-Output ('Found {0} dump file(s) for analysis.' -f $latestDumps.Count)
    $analysis = Invoke-DumpAnalysis -CdbPath $cdbPath -DumpFiles @($latestDumps) -SymbolsPath $SymbolsPath

    Write-Output ('Analysis logs directory: {0}' -f $analysis.ReportDirectory)
    $analysis.Results | Sort-Object -Property LastWriteTime -Descending

    try {
        $sortedResults = $analysis.Results | Sort-Object -Property LastWriteTime -Descending
        $html = ConvertTo-BsodHtml -Results @($sortedResults)
        Set-NinjaProperty -Name $WysiwygFieldName -Value $html -Type 'WYSIWYG'
        Write-Verbose "BSOD analysis written to NinjaOne $WysiwygFieldName field."
    } catch {
        Write-Verbose "Unable to write to NinjaOne WYSIWYG field: $($_.Exception.Message)"
    }
} catch {
    Write-Error ('Script failed: {0}' -f $_.Exception.Message)
    exit 1
}
