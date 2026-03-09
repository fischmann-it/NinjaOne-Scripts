#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Hyper-V host health report for NinjaOne — checks disk, RAM, CPU, replication, checkpoint, and cluster storage health.

.DESCRIPTION
    Collects capacity and health data from a Hyper-V host and writes an HTML summary card to the
    NinjaOne WYSIWYG custom field 'hypervHealth'. Can be used as a NinjaOne Condition (exit-code based)
    or as a scheduled Automation to keep the custom field current.

    Checks performed:
      - Disk: flags drives where provisioned virtual space leaves less than $diskWarnThresholdGB GB headroom
      - RAM:  flags startup RAM sum vs total host memory (cannot cold-boot all VMs simultaneously)
      - CPU:  flags vCPU:pCore oversubscription ratio and per-VM NUMA span issues
      - Replication: reports Hyper-V Replica health and last replication time per VM
      - Checkpoints: flags long-lived, oversized, or deep checkpoint chains per VM
      - Cluster Storage: reports CSV free space on clustered hosts (section hidden on non-clustered hosts)

    Exit codes (usable as a NinjaOne Condition):
      0 — No enabled alert categories are breached
      1 — At least one enabled category is in a Warning state
      2 — At least one enabled category is in a Critical state

    Requires: Hyper-V PowerShell module, Administrator privileges, SYSTEM or Domain account context.

.NOTES
    NinjaOne Custom Field (WYSIWYG): hypervHealth
    Designed for: NinjaOne Automation / Condition on Hyper-V hosts
    Run As: SYSTEM

    Script Variables (all optional — configure in NinjaOne to override defaults):
    ┌──────────────────────────────┬──────────┬─────────┬──────────────────────────────────────────────────────┐
    │ Variable Name                │ Type     │ Default │ Description                                          │
    ├──────────────────────────────┼──────────┼─────────┼──────────────────────────────────────────────────────┤
    │ diskWarnThresholdGb          │ Integer  │ 100     │ GB of free headroom (capacity minus provisioned)     │
    │                              │          │         │ below which a drive is flagged as a warning.         │
    ├──────────────────────────────┼──────────┼─────────┼──────────────────────────────────────────────────────┤
    │ checkpointWarnAgeDays        │ Integer  │ 7       │ Age in days before a checkpoint is a warning.        │
    │ checkpointCritAgeDays        │ Integer  │ 14      │ Age in days before a checkpoint is critical.         │
    │ checkpointWarnSizeGB         │ Decimal  │ 50      │ Total AVHDX footprint (GB) per VM — warning level.  │
    │ checkpointCritSizeGB         │ Decimal  │ 100     │ Total AVHDX footprint (GB) per VM — critical level. │
    │ checkpointWarnChainDepth     │ Integer  │ 2       │ Checkpoint chain depth — warning level.              │
    │ checkpointCritChainDepth     │ Integer  │ 5       │ Checkpoint chain depth — critical level.             │
    ├──────────────────────────────┼──────────┼─────────┼──────────────────────────────────────────────────────┤
    │ alertOnDiskOverprovisioning  │ Boolean  │ true    │ Include disk overprovisioning in exit code.          │
    │ alertOnRAMOverprovisioning   │ Boolean  │ true    │ Include RAM overprovisioning in exit code.           │
    │ alertOnCPUOverprovisioning   │ Boolean  │ false   │ Include CPU overprovisioning in exit code.           │
    │ alertOnReplicationWarning    │ Boolean  │ false   │ Include replication Warning health in exit code.     │
    │ alertOnReplicationCritical   │ Boolean  │ true    │ Include replication Critical health in exit code.    │
    │ alertOnCheckpointWarning     │ Boolean  │ false   │ Include checkpoint warnings in exit code.            │
    │ alertOnCheckpointCritical    │ Boolean  │ true    │ Include checkpoint critical findings in exit code.   │
    ├──────────────────────────────┼──────────┼─────────┼──────────────────────────────────────────────────────┤
    │ csvWarnThresholdPct          │ Integer  │ 15      │ CSV % free below which a volume is flagged Warning.  │
    │ csvCritThresholdPct          │ Integer  │ 5       │ CSV % free below which a volume is flagged Critical. │
    │ alertOnCSVWarning            │ Boolean  │ false   │ Include CSV Warning state in exit code.              │
    │ alertOnCSVCritical           │ Boolean  │ true    │ Include CSV Critical state in exit code.             │
    └──────────────────────────────┴──────────┴─────────┴──────────────────────────────────────────────────────┘

    Alert flags let you suppress noisy categories from affecting the Condition exit code while still
    surfacing them in the HTML report. For example: disable alertOnCPUOverprovisioning on hosts where
    moderate oversubscription is intentional, while keeping the visual report accurate.

    Script variables are optional — defaults work out of the box. Configure them in NinjaOne to customise
    behaviour per device or Condition. For example: set up multiple Conditions with different alert
    categories enabled per environment, or override a threshold at the device level for edge cases.

    TODO:
    - NICs, Teaming?
    - More Clustering data.
    - VM Auto-Start when a cluster role, should reflect cluster config
    - VM Details should show if powered off and on the receiving end of replication.
#>

# --- Guard checks ---

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Warning 'Not running on a Hyper-V host. Exiting.'
    exit 0
}

$allVMs = Get-VM
if (-not $allVMs) {
    Write-Warning 'No VMs found on this host. Exiting.'
    exit 0
}

function Test-IsSystem {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return $id.IsSystem -or $id.Name -like 'NT AUTHORITY*'
}
if (-not (Test-IsSystem)) {
    Write-Error -Message 'Access Denied. Please run as SYSTEM'
    exit 1
}

function Get-EnvWithDefault {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Default,
        [Parameter(Mandatory)] [type]$Type
    )
    $raw = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrEmpty($raw)) {
        if ($Type -eq [bool]) { return 'true', '1', 'yes' -icontains $raw }
        $result = $raw -as $Type
        if ($null -ne $result) { return $result }
    }
    return $Default
}

# --- Script Variables (NinjaOne script variables override these defaults) ---

# Disk capacity: drives with less than this many GB of headroom after provisioned space are flagged
$diskWarnThresholdGB = Get-EnvWithDefault -Name 'diskWarnThresholdGb' -Default 100 -Type ([int])

# Checkpoint age thresholds (days)
$checkpointWarnAgeDays = Get-EnvWithDefault -Name 'checkpointWarnAgeDays' -Default 7 -Type ([int])
$checkpointCritAgeDays = Get-EnvWithDefault -Name 'checkpointCritAgeDays' -Default 14 -Type ([int])

# Checkpoint total AVHDX size per VM thresholds (GB)
$checkpointWarnSizeGB = Get-EnvWithDefault -Name 'checkpointWarnSizeGB' -Default 50 -Type ([double])
$checkpointCritSizeGB = Get-EnvWithDefault -Name 'checkpointCritSizeGB' -Default 100 -Type ([double])

# Checkpoint chain depth thresholds (number of checkpoints per VM)
$checkpointWarnChainDepth = Get-EnvWithDefault -Name 'checkpointWarnChainDepth' -Default 2 -Type ([int])
$checkpointCritChainDepth = Get-EnvWithDefault -Name 'checkpointCritChainDepth' -Default 5 -Type ([int])

# Alert flags — set to $false to suppress a category from contributing to the exit code
$alertOnDiskOverprovisioning = Get-EnvWithDefault -Name 'alertOnDiskOverprovisioning' -Default $true -Type ([bool])
$alertOnRAMOverprovisioning = Get-EnvWithDefault -Name 'alertOnRAMOverprovisioning' -Default $true -Type ([bool])
$alertOnCPUOverprovisioning = Get-EnvWithDefault -Name 'alertOnCPUOverprovisioning' -Default $false -Type ([bool])
$alertOnReplicationWarning = Get-EnvWithDefault -Name 'alertOnReplicationWarning' -Default $false -Type ([bool])
$alertOnReplicationCritical = Get-EnvWithDefault -Name 'alertOnReplicationCritical' -Default $true -Type ([bool])
$alertOnCheckpointWarning = Get-EnvWithDefault -Name 'alertOnCheckpointWarning' -Default $false -Type ([bool])
$alertOnCheckpointCritical = Get-EnvWithDefault -Name 'alertOnCheckpointCritical' -Default $true -Type ([bool])

# Cluster Shared Volume (CSV) thresholds — only used when the host is part of a Failover Cluster
$csvWarnThresholdPct = Get-EnvWithDefault -Name 'csvWarnThresholdPct' -Default 15 -Type ([int])
$csvCritThresholdPct = Get-EnvWithDefault -Name 'csvCritThresholdPct' -Default 5 -Type ([int])
$alertOnCSVWarning = Get-EnvWithDefault -Name 'alertOnCSVWarning' -Default $false -Type ([bool])
$alertOnCSVCritical = Get-EnvWithDefault -Name 'alertOnCSVCritical' -Default $true -Type ([bool])

# --- Helper Functions ---

function ConvertTo-HtmlEncoded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )
    $Value `
        -replace '&', '&amp;' `
        -replace '<', '&lt;' `
        -replace '>', '&gt;' `
        -replace '"', '&quot;' `
        -replace "'", '&#39;'
}

function Get-NinjaOneCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string]$Body,
        [string]$Icon,
        [string]$TitleLink,
        [string]$Classes
    )
    [System.Collections.Generic.List[string]]$OutputHTML = @()

    $OutputHTML.Add('<div class="card flex-grow-1' + $(if ($Classes) {
                ' ' + $Classes
            }) + '" style="width:100%" >')

    if ($Title) {
        $OutputHTML.Add('<div class="card-title-box"><div class="card-title" >' + $(if ($Icon) {
                    '<i class="' + $Icon + '"></i>&nbsp;&nbsp;'
                }) + $Title + '</div>')

        if ($TitleLink) {
            $OutputHTML.Add('<div class="card-link-box"><a href="' + $TitleLink + '" target="_blank" class="card-link" ><i class="fas fa-arrow-up-right-from-square" style="color: #337ab7;"></i></a></div>')
        }

        $OutputHTML.Add('</div>')
    }

    $OutputHTML.Add('<div class="card-body" >')
    $OutputHTML.Add('<p class="card-text" >' + $Body + '</p>')
    $OutputHTML.Add('</div></div>')

    return $OutputHTML -join ''
}

function New-HtmlTable {
    [CmdletBinding()]
    param(
        [string]$Title,
        [string]$Icon,
        [string[]]$Headers,
        [string]$Rows,
        [string]$EmptyMessage = ''
    )
    $heading = if ($Title) {
        $iconHtml = if ($Icon) { "<i class='$Icon'></i>&nbsp;&nbsp;" } else { '' }
        "<h3>$iconHtml$Title</h3>"
    } else { '' }

    if (-not $Rows) {
        if ($EmptyMessage) { return "$heading<p class='text-success'>$EmptyMessage</p>" }
        return ''
    }
    $thead = ($Headers | ForEach-Object { "<th>$_</th>" }) -join ''
    return @"
$heading<table>
    <thead>
        <tr>$thead</tr>
    </thead>
    <tbody>
        $Rows
    </tbody>
</table>
"@
}

function New-HtmlInfoCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('error', 'warning', 'info')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string]$Description
    )
    # NOTE: $Title and $Description are injected directly into HTML. Callers MUST pre-encode
    # any user-controlled data (e.g. VM names) with ConvertTo-HtmlEncoded before passing here.
    $icon = if ($Level -eq 'error') { 'fa-solid fa-circle-exclamation' } else { 'fa-solid fa-triangle-exclamation' }
    return "<div class='info-card $Level'><i class='info-icon $icon'></i><div class='info-text'><div class='info-title'>$Title</div><div class='info-description'>$Description</div></div></div>"
}

function Get-AlertColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('danger', 'warning', 'success')]
        [string]$Level
    )
    switch ($Level) {
        'danger' { return '#d9534f' }
        'warning' { return '#f0ad4e' }
        default { return '#5cb85c' }
    }
}

function Get-ProgressBarColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$Percent,
        [int]$WarnPct = 70,
        [int]$CritPct = 90
    )
    if ($Percent -ge $CritPct) { return '#d9534f' }
    if ($Percent -ge $WarnPct) { return '#f0ad4e' }
    return '#5cb85c'
}

function New-HtmlProgressBar {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$Color,
        [Parameter(Mandatory)] [double]$Percent
    )
    $barPct = [math]::Min(100, [math]::Max(0, $Percent))
    return "<div>$Label</div><div style='background-color:#e8e8e8;border-radius:2px;height:6px;margin-top:3px;overflow:hidden;'><div style='background-color:$Color;width:$barPct%;height:6px;border-radius:2px;'></div></div>"
}

function New-HyperVWarningsSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Parameter(Mandatory)]
        [pscustomobject]$Summary,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$ReplicationInfo,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$CpuNumaFindings,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$CheckpointFindings,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$CsvData,
        [Parameter(Mandatory)]
        [int]$CsvCritThresholdPct,
        [Parameter(Mandatory)]
        [int]$CsvWarnThresholdPct
    )
    $items = [System.Collections.Generic.List[string]]::new()

    if ($Summary) {
        if ($Summary.OverprovisionedDisk) {
            $items.Add((New-HtmlInfoCard -Level 'error' -Title 'Disk Overprovisioned' -Description 'Total provisioned virtual disk space exceeds total physical capacity.'))
        }
        if ($Summary.OverprovisionedRAM) {
            $items.Add((New-HtmlInfoCard -Level 'error' -Title 'RAM Overprovisioned' -Description 'Total configured startup RAM exceeds total host memory &mdash; the host cannot start all VMs simultaneously.'))
        }
        if ($Summary.OverprovisionedCPU) {
            $items.Add((New-HtmlInfoCard -Level 'warning' -Title 'CPU Overprovisioned' -Description "Total assigned vCPUs ($($Summary.TotalAssignedCPUs)) exceeds total host logical cores ($($Summary.TotalHostCores))."))
        }
    }

    foreach ($r in @($ReplicationInfo | Where-Object { $_.Health -in 'Warning', 'Critical' })) {
        $level = if ($r.Health -eq 'Critical') { 'error' } else { 'warning' }
        $items.Add((New-HtmlInfoCard -Level $level -Title "Replication $($r.Health): $(ConvertTo-HtmlEncoded $r.Vm)" -Description "State: $(ConvertTo-HtmlEncoded $r.State)"))
    }

    # Info-level CPU/NUMA findings (e.g. processor flags, CPU caps) are intentionally excluded
    # from the warnings section — they appear in the CPU/NUMA detail table below the fold.
    foreach ($f in @($CpuNumaFindings | Where-Object { $_.Level -eq 'Warning' })) {
        $items.Add((New-HtmlInfoCard -Level 'warning' -Title "CPU/NUMA: $(ConvertTo-HtmlEncoded $f.Vm)" -Description (ConvertTo-HtmlEncoded $f.Message)))
    }

    foreach ($f in @($CheckpointFindings | Where-Object { $_.Level -in 'Warning', 'Critical' })) {
        $level = if ($f.Level -eq 'Critical') { 'error' } else { 'warning' }
        $items.Add((New-HtmlInfoCard -Level $level -Title "Checkpoint $($f.Level): $(ConvertTo-HtmlEncoded $f.Vm)" -Description (ConvertTo-HtmlEncoded $f.Message)))
    }

    $csvCrit = @($CsvData | Where-Object { $_.RowColor -eq 'danger' })
    $csvWarn = @($CsvData | Where-Object { $_.RowColor -eq 'warning' })
    if ($csvCrit.Count -gt 0) {
        $items.Add((New-HtmlInfoCard -Level 'error' -Title 'CSV Storage Critical' -Description "$($csvCrit.Count) volume(s) are below $CsvCritThresholdPct% free space."))
    }
    if ($csvWarn.Count -gt 0) {
        $items.Add((New-HtmlInfoCard -Level 'warning' -Title 'CSV Storage Warning' -Description "$($csvWarn.Count) volume(s) are below $CsvWarnThresholdPct% free space."))
    }

    if ($items.Count -eq 0) { return '' }
    $colItems = ($items | ForEach-Object { "<div class='col'>$_</div>" }) -join ''
    return "<h3><i class='fas fa-triangle-exclamation'></i>&nbsp;&nbsp;Warnings</h3><div class='row row-cols-1 row-cols-md-2 g-2'>$colItems</div>"
}

function New-HyperVVmDetailsSectionHtml {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$AllVMs,
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$AllVirtualDisks,
        [Parameter(Mandatory)]
        [int]$LogicalCoresPerNuma
    )
    # Manual hashtable build: Group-Object -AsHashTable returns a case-sensitive Hashtable;
    # @{} is case-insensitive, so VM name lookups work regardless of casing differences.
    $disksByVm = @{}
    foreach ($d in $AllVirtualDisks) {
        $disksByVm[$d.Vm] += @($d)
    }

    $vmDetails = $AllVMs | ForEach-Object {
        $vm = $_
        [pscustomobject]@{
            Vm                   = $vm.Name
            State                = $vm.State
            AssignedCPUs         = [int]($vm.ProcessorCount)
            AssignedRAMGB        = [math]::Round($vm.MemoryAssigned / 1GB, 2)
            StartupRAMGB         = [math]::Round($vm.MemoryStartup / 1GB, 2)
            AutomaticStartAction = [string]$vm.AutomaticStartAction
            AutomaticStartDelay  = [int]$vm.AutomaticStartDelay
            Disks                = $disksByVm[$vm.Name]
        }
    }

    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in $vmDetails) {
        $vmName = ConvertTo-HtmlEncoded $vm.Vm
        $stateText = ConvertTo-HtmlEncoded $vm.State
        $stateColor = switch ($vm.State) {
            'Running' { 'color: #3c763d' }
            'Off' { 'color: #777' }
            'Paused' { 'color: #8a6d3b' }
            'Saved' { 'color: #8a6d3b' }
            default { '' }
        }
        $stateSpan = if ($stateColor) {
            "<span style='$stateColor'>[$stateText]</span>"
        } else {
            "<span>[$stateText]</span>"
        }

        $numaFlag = if ($vm.AssignedCPUs -gt $LogicalCoresPerNuma) {
            ' &#9888; NUMA span'
        } else {
            ''
        }

        $ramDisplay = if ($vm.AssignedRAMGB -gt 0) {
            "$($vm.AssignedRAMGB) GB"
        } else {
            "$($vm.StartupRAMGB) GB (startup config - VM is $($vm.State))"
        }

        $autoStartDisplay = $vm.AutomaticStartAction
        if ($vm.AutomaticStartDelay -gt 0) { $autoStartDisplay += " (delay: $($vm.AutomaticStartDelay)s)" }

        $accentColor = switch ($vm.State) {
            'Running' { '#3c763d' }
            'Off' { '#777' }
            'Paused' { '#8a6d3b' }
            'Saved' { '#8a6d3b' }
            default { '#ccc' }
        }
        $rows.Add("<tr><th colspan='5' style='background:#f5f5f5;border-left:4px solid $accentColor;text-align:left;font-weight:normal;padding-left:8px'><strong>$vmName</strong> &nbsp; $stateSpan &nbsp;&nbsp; vCPUs: $($vm.AssignedCPUs)$numaFlag &nbsp;|&nbsp; RAM: $ramDisplay &nbsp;|&nbsp; Auto-start: $autoStartDisplay</th></tr>")

        if ($vm.Disks -and $vm.Disks.Count -gt 0) {
            foreach ($disk in $vm.Disks) {
                $driveLetter = ConvertTo-HtmlEncoded $disk.PhysicalDriveLetter
                $diskName = ConvertTo-HtmlEncoded $disk.VirtualDiskName
                $fileName = ConvertTo-HtmlEncoded $disk.FileName
                $diskType = ConvertTo-HtmlEncoded $disk.VirtualDiskType
                $provisioned = [math]::Round($disk.ProvisionedVirtualGB, 2)
                $committed = [math]::Round($disk.CommittedVirtualGB, 2)
                $pct = if ($provisioned -gt 0) {
                    [math]::Min(100, [math]::Round($committed / $provisioned * 100, 1))
                } else { 0 }
                $barColor = if ($disk.VirtualDiskType -eq 'Fixed') { '#337ab7' } elseif ($pct -ge 85) { '#d9534f' } elseif ($pct -ge 70) { '#f0ad4e' } else { '#5cb85c' }
                $diskCell = New-HtmlProgressBar -Label "$provisioned / $committed GB ($pct%)" -Color $barColor -Percent $pct
                $rows.Add("<tr><td>$driveLetter</td><td>$diskName</td><td>$fileName</td><td>$diskType</td><td>$diskCell</td></tr>")
            }
        } else {
            $rows.Add("<tr><td colspan='5'>No virtual disks attached</td></tr>")
        }
    }

    $table = "<table><thead><tr><th>Drive</th><th>Disk Name</th><th>File Name</th><th>Type</th><th>Provisioned / Committed (GB)</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
    return "<h3><i class='fas fa-desktop'></i>&nbsp;&nbsp;VM Details</h3>$table"
}

function Get-VirtualDiskInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return $AllVMs | ForEach-Object {
        $Vm = $_
        $_.HardDrives | ForEach-Object {
            try {
                $GetVhd = Get-VHD -Path $_.Path -ErrorAction Stop
                $vhdType = $GetVhd.VhdType
                $provisionedGB = [double]($GetVhd.Size / 1GB)
                $committedGB = [double]($GetVhd.FileSize / 1GB)
            } catch {
                Write-Warning "Failed to read VHD '$($_.Path)': $_"
                $vhdType = '[Error]'
                $provisionedGB = 0
                $committedGB = 0
            }

            $diskPath = Split-Path $_.Path -Parent
            try {
                $physicalDriveLetter = (Get-Item $diskPath -ErrorAction Stop).PSDrive.Name
                $physicalDriveInfo = Get-PSDrive -Name $physicalDriveLetter -ErrorAction Stop
            } catch {
                $physicalDriveLetter = 'Unknown'
                $physicalDriveInfo = $null
            }

            [pscustomobject]@{
                Vm                      = $Vm.Name
                VirtualDiskName         = $_.Name
                VirtualDiskType         = $vhdType
                ProvisionedVirtualGB    = $provisionedGB
                CommittedVirtualGB      = $committedGB
                FileName                = [System.IO.Path]::GetFileName($_.Path)
                IsOnCsv                 = ([string]$_.Path -like '*\ClusterStorage\*')
                PhysicalDriveLetter     = $physicalDriveLetter
                PhysicalDriveCapacityGB = if ($physicalDriveInfo) {
                    [double](($physicalDriveInfo.Used + $physicalDriveInfo.Free) / 1GB) 
                } else {
                    0 
                }
                PhysicalDriveFreeGB     = if ($physicalDriveInfo) {
                    [double]($physicalDriveInfo.Free / 1GB) 
                } else {
                    0 
                }
            }
        }
    }
}

function Get-MemoryInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return $AllVMs | ForEach-Object {
        [pscustomobject]@{
            Vm                   = $_.Name
            DynamicMemoryEnabled = [bool]$_.DynamicMemoryEnabled
            StartupRAMGB         = [double]($_.MemoryStartup / 1GB)
            AssignedRAMGB        = [double]($_.MemoryAssigned / 1GB)
            DynamicMaxCeilingGB  = if ($_.DynamicMemoryEnabled) {
                [double]($_.MemoryMaximum / 1GB) 
            } else {
                0 
            }
        }
    }
}

function Get-VMProcessorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return $AllVMs | ForEach-Object {
        $proc = Get-VMProcessor -VMName $_.Name -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-Warning "Get-VMProcessor returned nothing for VM '$($_.Name)'. CPU config checks will be skipped for this VM."
        }
        [pscustomobject]@{
            Vm                           = $_.Name
            AssignedCPUs                 = [int]$_.ProcessorCount
            IsRunning                    = ($_.State -eq 'Running')
            ProcReadFailed               = ($null -eq $proc)
            MaxCountPerNumaNode          = if ($proc) {
                [int]$proc.MaximumCountPerNumaNode 
            } else {
                0 
            }
            MaxCountPerNumaSocket        = if ($proc) {
                [int]$proc.MaximumCountPerNumaSocket 
            } else {
                0 
            }
            CompatibilityForMigration    = if ($proc) {
                [bool]$proc.CompatibilityForMigrationEnabled 
            } else {
                $false 
            }
            CompatibilityForOlderOS      = if ($proc) {
                [bool]$proc.CompatibilityForOlderOperatingSystemsEnabled 
            } else {
                $false 
            }
            EnableHostResourceProtection = if ($proc) {
                [bool]$proc.EnableHostResourceProtection 
            } else {
                $false 
            }
            Reserve                      = if ($proc) {
                [int]$proc.Reserve 
            } else {
                0 
            }
            Maximum                      = if ($proc) {
                [int]$proc.Maximum 
            } else {
                0 
            }
        }
    }
}

function Get-ReplicationInfo {
    [CmdletBinding()]
    param()
    try {
        return Get-VMReplication -ErrorAction Stop | ForEach-Object {
            $freqSec = if ($_.FrequencyOfReplication) {
                [int]$_.FrequencyOfReplication.TotalSeconds
            } else {
                300 
            }
            [pscustomobject]@{
                Vm                          = $_.VMName
                ReplicationMode             = [string]$_.ReplicationMode
                ReplicationRelationshipType = [string]$_.ReplicationRelationshipType
                Health                      = [string]$_.Health
                State                       = [string]$_.State
                PrimaryServer               = [string]$_.PrimaryServerName
                ReplicaServer               = [string]$_.ReplicaServerName
                LastReplicationTime         = $_.LastReplicationTime
                FrequencyOfReplicationSec   = $freqSec
            }
        }
    } catch {
        Write-Warning "Get-VMReplication failed: $_"
        return @()
    }
}

function Get-CPUNUMAFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$VMProcessors,
        [Parameter(Mandatory)]
        [int]$LogicalCoresPerNuma,
        [Parameter(Mandatory)]
        [int]$TotalHostCores
    )
    $findings = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($vm in $VMProcessors) {
        $vcpus = $vm.AssignedCPUs

        # Use the VM's configured per-NUMA limit if available; fall back to host heuristic
        $effectiveNumaSize = if ($vm.MaxCountPerNumaNode -gt 0) {
            $vm.MaxCountPerNumaNode 
        } else {
            $LogicalCoresPerNuma 
        }
        if ($effectiveNumaSize -gt 0 -and -not $vm.ProcReadFailed -and $vcpus -gt $effectiveNumaSize) {
            $findings.Add([pscustomobject]@{
                    Vm      = $vm.Vm
                    Level   = 'Warning'
                    Message = "vCPU count ($vcpus) exceeds NUMA node size ($effectiveNumaSize logical CPUs). VM spans NUMA nodes, which can reduce memory bandwidth and increase latency."
                })
        }

        if ($TotalHostCores -gt 0 -and -not $vm.ProcReadFailed -and $vcpus -gt ($TotalHostCores / 2)) {
            $findings.Add([pscustomobject]@{
                    Vm      = $vm.Vm
                    Level   = 'Info'
                    Message = "vCPU count ($vcpus) exceeds host physical core count. VM relies on hyperthreading headroom."
                })
        }

        if (-not $vm.ProcReadFailed) {
            if ($vm.CompatibilityForMigration) {
                $findings.Add([pscustomobject]@{
                        Vm      = $vm.Vm
                        Level   = 'Info'
                        Message = 'Processor Compatibility for Migration is enabled. CPU features are masked for live migration compatibility, which may reduce performance.'
                    })
            }

            if ($vm.CompatibilityForOlderOS) {
                $findings.Add([pscustomobject]@{
                        Vm      = $vm.Vm
                        Level   = 'Info'
                        Message = 'Compatibility for Older Operating Systems is enabled. Restricts exposed CPU feature set.'
                    })
            }

            if ($vm.EnableHostResourceProtection) {
                $findings.Add([pscustomobject]@{
                        Vm      = $vm.Vm
                        Level   = 'Info'
                        Message = 'Host Resource Protection is enabled. Hyper-V may throttle CPU bursts for this VM to protect host responsiveness.'
                    })
            }

            if ($vm.Reserve -gt 0) {
                $findings.Add([pscustomobject]@{
                        Vm      = $vm.Vm
                        Level   = 'Info'
                        Message = "CPU Reserve is set to $($vm.Reserve)%. This guarantees a CPU floor but reduces scheduling flexibility."
                    })
            }

            if ($vm.Maximum -lt 100 -and $vm.Maximum -gt 0) {
                $findings.Add([pscustomobject]@{
                        Vm      = $vm.Vm
                        Level   = 'Info'
                        Message = "CPU Maximum is capped at $($vm.Maximum)%. VM cannot use full host CPU capacity."
                    })
            }
        }
    }

    $totalVcpus = ($VMProcessors | Measure-Object -Property AssignedCPUs -Sum).Sum
    $vcpuRatioWarnThreshold = 8   # > 8:1 vCPU:pCore is heavy oversubscription — triggers Warning finding
    $vcpuRatioInfoThreshold = 4   # > 4:1 is moderate — triggers Info finding only
    if ($TotalHostCores -eq 0) {
        Write-Warning 'TotalHostCores is 0 - Win32_Processor query may have failed. vCPU ratio checks will be skipped.'
    } elseif ($TotalHostCores -gt 0) {
        $ratio = [math]::Round($totalVcpus / $TotalHostCores, 1)
        if ($ratio -gt $vcpuRatioWarnThreshold) {
            $findings.Add([pscustomobject]@{
                    Vm      = '(Host)'
                    Level   = 'Warning'
                    Message = "Overall vCPU:pCore ratio is $($ratio):1 (threshold: $($vcpuRatioWarnThreshold):1). Heavy oversubscription can cause CPU-ready latency across all VMs."
                })
        } elseif ($ratio -gt $vcpuRatioInfoThreshold) {
            $findings.Add([pscustomobject]@{
                    Vm      = '(Host)'
                    Level   = 'Info'
                    Message = "Overall vCPU:pCore ratio is $($ratio):1. Moderate oversubscription - monitor CPU-ready counters under load."
                })
        }
    }

    return $findings
}

function Get-PhysicalDriveSummary {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$AllVirtualDisks,
        [string[]]$CsvDriveLetters = @()
    )
    return $AllVirtualDisks | Group-Object -Property PhysicalDriveLetter | ForEach-Object {
        $physicalDriveLetter = $_.Name
        $physicalDriveCapacity = [double]($_.Group | Select-Object -First 1 | ForEach-Object { $_.PhysicalDriveCapacityGB })
        $totalProvisionedVirtual = [double](($_.Group | Measure-Object -Property ProvisionedVirtualGB -Sum).Sum)
        $totalCommittedVirtual = [double](($_.Group | Measure-Object -Property CommittedVirtualGB -Sum).Sum)
        $physicalDriveFree = [double]($_.Group | Select-Object -First 1 | ForEach-Object { $_.PhysicalDriveFreeGB })

        # Headroom: free space remaining if all VMs grew to their fully provisioned size
        # = actual free space - (provisioned max - currently committed)
        $headroomGB = [double]($physicalDriveFree - ($totalProvisionedVirtual - $totalCommittedVirtual))

        # Row color based on overprovisioning risk (CSV drives tracked separately)
        $rowColor = if ($physicalDriveLetter -in $CsvDriveLetters) {
            'success'
        } elseif ($headroomGB -le 0) {
            'danger'
        } elseif ($headroomGB -le $diskWarnThresholdGB) {
            'warning'
        } else {
            'success'
        }

        [pscustomobject]@{
            PhysicalDriveLetter               = $physicalDriveLetter
            PhysicalDriveCapacityGB           = $physicalDriveCapacity
            PhysicalDriveFreeGB               = $physicalDriveFree
            TotalProvisionedVirtualGB         = $totalProvisionedVirtual
            TotalCommittedVirtualGB           = $totalCommittedVirtual
            NonVmFilesGB                      = [double]($physicalDriveCapacity - $totalCommittedVirtual - $physicalDriveFree)
            HeadroomGB                        = $headroomGB
            CapacityMinusCommittedVirtualGB   = [double]($physicalDriveCapacity - $totalCommittedVirtual)
            CapacityMinusProvisionedVirtualGB = [double]($physicalDriveCapacity - $totalProvisionedVirtual)
            RowColor                          = $rowColor
        }
    }
}

function Test-Overprovisioning {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$PhysicalDrives,
        [Parameter(Mandatory)]
        [object[]]$AllMemory,
        [Parameter(Mandatory)]
        [object[]]$AllCpu,
        [Parameter(Mandatory)]
        [double]$TotalHostMemory,
        [Parameter(Mandatory)]
        [int]$TotalHostCores
    )
    if ($PhysicalDrives.Count -eq 0) {
        return [pscustomobject]@{
            TotalPhysicalCapacityGB   = 0
            TotalProvisionedVirtualGB = 0
            TotalCommittedVirtualGB   = 0
            TotalPhysicalFreeGB       = 0
            TotalAssignedRAMGB        = [double](($AllMemory | Measure-Object -Property AssignedRAMGB -Sum).Sum)
            TotalStartupRAMGB         = [double](($AllMemory | Measure-Object -Property StartupRAMGB -Sum).Sum)
            TotalHostMemoryGB         = $TotalHostMemory
            TotalAssignedCPUs         = [double](($AllCpu | Measure-Object -Property AssignedCPUs -Sum).Sum)
            TotalLiveCPUs             = [double](($AllCpu | Where-Object { $_.IsRunning } | Measure-Object -Property AssignedCPUs -Sum).Sum)
            TotalHostCores            = $TotalHostCores
            OverprovisionedDisk       = $false
            OverprovisionedRAM        = $false
            OverprovisionedCPU        = $false
        }
    }
    $totalPhysicalCapacity = [double](($PhysicalDrives | Measure-Object -Property PhysicalDriveCapacityGB -Sum).Sum)
    $totalProvisionedVirtual = [double](($PhysicalDrives | Measure-Object -Property TotalProvisionedVirtualGB -Sum).Sum)
    $totalCommittedVirtual = [double](($PhysicalDrives | Measure-Object -Property TotalCommittedVirtualGB -Sum).Sum)
    $totalPhysicalFree = [double](($PhysicalDrives | Measure-Object -Property PhysicalDriveFreeGB -Sum).Sum)
    $totalAssignedRAM = [double](($AllMemory | Measure-Object -Property AssignedRAMGB -Sum).Sum)
    $totalStartupRAM = [double](($AllMemory | Measure-Object -Property StartupRAMGB -Sum).Sum)
    $totalAssignedCPUs = [double](($AllCpu | Measure-Object -Property AssignedCPUs -Sum).Sum)

    [pscustomobject]@{
        TotalPhysicalCapacityGB   = $totalPhysicalCapacity
        TotalProvisionedVirtualGB = $totalProvisionedVirtual
        TotalCommittedVirtualGB   = $totalCommittedVirtual
        TotalPhysicalFreeGB       = $totalPhysicalFree
        TotalAssignedRAMGB        = $totalAssignedRAM
        TotalStartupRAMGB         = $totalStartupRAM
        TotalHostMemoryGB         = $TotalHostMemory
        TotalAssignedCPUs         = $totalAssignedCPUs
        TotalLiveCPUs             = [double](($AllCpu | Where-Object { $_.IsRunning } | Measure-Object -Property AssignedCPUs -Sum).Sum)
        TotalHostCores            = $TotalHostCores
        OverprovisionedDisk       = ($totalPhysicalFree - ($totalProvisionedVirtual - $totalCommittedVirtual)) -lt 0
        OverprovisionedRAM        = $totalStartupRAM -gt $TotalHostMemory
        OverprovisionedCPU        = $totalAssignedCPUs -gt $TotalHostCores
    }
}

function Add-ThresholdFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[pscustomobject]]$FindingsList,
        [Parameter(Mandatory)]
        [string]$VmName,
        [Parameter(Mandatory)]
        [string]$Category,
        [Parameter(Mandatory)]
        [double]$Value,
        [Parameter(Mandatory)]
        [double]$CritThreshold,
        [Parameter(Mandatory)]
        [double]$WarnThreshold,
        [Parameter(Mandatory)]
        [string]$CritMessage,
        [Parameter(Mandatory)]
        [string]$WarnMessage
    )
    if ($Value -ge $CritThreshold) {
        $FindingsList.Add([pscustomobject]@{ Vm = $VmName; Level = 'Critical'; Category = $Category; Message = $CritMessage })
    } elseif ($Value -ge $WarnThreshold) {
        $FindingsList.Add([pscustomobject]@{ Vm = $VmName; Level = 'Warning'; Category = $Category; Message = $WarnMessage })
    }
}

function Get-CheckpointFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs,
        [int]$WarnAgeDays = 7,
        [int]$CritAgeDays = 14,
        [double]$WarnSizeGB = 10,
        [double]$CritSizeGB = 50,
        [int]$WarnChainDepth = 3,
        [int]$CritChainDepth = 5
    )
    $findings = [System.Collections.Generic.List[pscustomobject]]::new()
    $vhdCache = @{}
    $now = Get-Date

    foreach ($vm in $AllVMs) {
        $checkpoints = @(Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue)
        if ($checkpoints.Count -eq 0) { continue }

        # Chain depth check (per VM)
        $chainDepth = $checkpoints.Count
        Add-ThresholdFinding -FindingsList $findings -VmName $vm.Name -Category 'ChainDepth' `
            -Value $chainDepth -CritThreshold $CritChainDepth -WarnThreshold $WarnChainDepth `
            -CritMessage "VM has $chainDepth checkpoints in chain (critical threshold: $CritChainDepth). Deep chains cause significant read overhead and complex merges." `
            -WarnMessage "VM has $chainDepth checkpoints in chain (warning threshold: $WarnChainDepth)."

        # Total AVHDX footprint check (per VM): walk all hard drive differencing chains.
        # Results are cached by path to avoid redundant Get-VHD calls when disks share chain links.
        $totalAvhdxGB = 0
        foreach ($hdd in $vm.HardDrives) {
            $chainPath = $hdd.Path
            while ($chainPath -and $chainPath -like '*.avhdx') {
                try {
                    if (-not $vhdCache.ContainsKey($chainPath)) {
                        $vhdCache[$chainPath] = Get-VHD -Path $chainPath -ErrorAction Stop
                    }
                    $vhd = $vhdCache[$chainPath]
                    $totalAvhdxGB += $vhd.FileSize / 1GB
                    $chainPath = $vhd.ParentPath
                } catch {
                    break
                }
            }
        }
        $totalAvhdxGB = [math]::Round($totalAvhdxGB, 2)

        Add-ThresholdFinding -FindingsList $findings -VmName $vm.Name -Category 'Size' `
            -Value $totalAvhdxGB -CritThreshold $CritSizeGB -WarnThreshold $WarnSizeGB `
            -CritMessage "Total checkpoint data is $totalAvhdxGB GB (critical threshold: $CritSizeGB GB). Merging will be a significant I/O event." `
            -WarnMessage "Total checkpoint data is $totalAvhdxGB GB (warning threshold: $WarnSizeGB GB)."

        # Age check (per checkpoint)
        foreach ($cp in $checkpoints) {
            $ageDays = [math]::Round(($now - $cp.CreationTime).TotalDays, 1)
            $cpName = $cp.Name
            $cpType = if ($cp.CheckpointType) { [string]$cp.CheckpointType } else { 'Unknown' }

            Add-ThresholdFinding -FindingsList $findings -VmName $vm.Name -Category 'Age' `
                -Value $ageDays -CritThreshold $CritAgeDays -WarnThreshold $WarnAgeDays `
                -CritMessage "Checkpoint '$cpName' ($cpType) is $ageDays days old (critical threshold: $CritAgeDays days)." `
                -WarnMessage "Checkpoint '$cpName' ($cpType) is $ageDays days old (warning threshold: $WarnAgeDays days)."
        }
    }

    return $findings
}

function Test-IsClusteredHost {
    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $null = Get-ClusterNode -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-ClusterSharedVolumeInfo {
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($csv in (Get-ClusterSharedVolume -ErrorAction Stop)) {
        $vol = $csv.SharedVolumeInfo[0]
        $sizeGB = [math]::Round($vol.Partition.Size / 1GB, 2)
        $freeGB = [math]::Round($vol.Partition.FreeSpace / 1GB, 2)
        $usedGB = [math]::Round(($vol.Partition.Size - $vol.Partition.FreeSpace) / 1GB, 2)
        $pctFree = if ($vol.Partition.Size -gt 0) {
            [math]::Round($vol.Partition.FreeSpace / $vol.Partition.Size * 100, 1)
        } else {
            0
        }
        $rowColor = if ($pctFree -le $csvCritThresholdPct) { 'danger' }
        elseif ($pctFree -le $csvWarnThresholdPct) { 'warning' }
        else { 'success' }
        $results.Add([pscustomobject]@{
                Name        = $csv.Name
                Path        = $vol.FriendlyVolumeName
                OwnerNode   = $csv.OwnerNode.Name
                SizeGB      = $sizeGB
                FreeGB      = $freeGB
                UsedGB      = $usedGB
                PercentFree = $pctFree
                RowColor    = $rowColor
            })
    }
    return $results
}

# --- Data collection ---

$totalHostMemory = [double]((Get-CimInstance -ClassName CIM_OperatingSystem).TotalVisibleMemorySize * 1KB / 1GB)
$totalHostCores = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors | Measure-Object -Sum | Select-Object -ExpandProperty Sum

$numaNodeCount = (Get-VMHostNumaNodeStatus -ErrorAction SilentlyContinue).Count
if (-not $numaNodeCount -or $numaNodeCount -eq 0) {
    $numaNodeCount = 1 
}
$logicalCoresPerNuma = [int]($totalHostCores / $numaNodeCount)

$allVirtualDisks = Get-VirtualDiskInfo -AllVMs $allVMs
$localVirtualDisks = @($allVirtualDisks | Where-Object { -not $_.IsOnCsv })
$allMemory = Get-MemoryInfo -AllVMs $allVMs
$allCpu = Get-VMProcessorConfig -AllVMs $allVMs

$isClustered = Test-IsClusteredHost
$csvData = if ($isClustered) {
    try {
        @(Get-ClusterSharedVolumeInfo)
    } catch {
        Write-Warning "Failed to collect CSV data: $_"
        @()
    }
} else {
    @()
}
$csvCriticalVolumes = @($csvData | Where-Object { $_.RowColor -eq 'danger' })
$csvWarningVolumes = @($csvData | Where-Object { $_.RowColor -eq 'warning' })
$csvDriveLetters = @(
    $csvData |
    ForEach-Object { $_.Path } |
    Where-Object { $_ -match '^([A-Za-z]):' } |
    ForEach-Object { $Matches[1].ToUpper() } |
    Select-Object -Unique
)

$physicalDrives = @(Get-PhysicalDriveSummary -AllVirtualDisks $localVirtualDisks -CsvDriveLetters $csvDriveLetters)
$nonCsvDrives = @($physicalDrives | Where-Object { $_.PhysicalDriveLetter -notin $csvDriveLetters })
$summary = Test-Overprovisioning -PhysicalDrives $nonCsvDrives -AllMemory $allMemory -AllCpu $allCpu -TotalHostMemory $totalHostMemory -TotalHostCores $totalHostCores
$cpuNumaFindings = try {
    @(Get-CPUNUMAFindings -VMProcessors $allCpu -LogicalCoresPerNuma $logicalCoresPerNuma -TotalHostCores $totalHostCores)
} catch {
    Write-Warning "Failed to collect CPU/NUMA findings: $_"
    @()
}
$replicationInfo = try {
    @(Get-ReplicationInfo)
} catch {
    Write-Warning "Failed to collect replication info: $_"
    @()
}
$replicatedVmNames = @($replicationInfo | Select-Object -ExpandProperty Vm -Unique)
$unreplicatedVms = @($allVMs | Where-Object { $replicatedVmNames -notcontains $_.Name })
$checkpointFindings = @(Get-CheckpointFindings -AllVMs $allVMs `
        -WarnAgeDays $checkpointWarnAgeDays -CritAgeDays $checkpointCritAgeDays `
        -WarnSizeGB $checkpointWarnSizeGB -CritSizeGB $checkpointCritSizeGB `
        -WarnChainDepth $checkpointWarnChainDepth -CritChainDepth $checkpointCritChainDepth)

# Pre-process replication rows (sorting + age/frequency labels)
$replNow = Get-Date
$sortedRepl = @($replicationInfo | Sort-Object {
        switch ($_.Health) { 'Critical' { 0 } 'Warning' { 1 } default { 2 } }
    }, {
        if ($_.LastReplicationTime) { $_.LastReplicationTime } else { [datetime]::MinValue }
    })
$replRows = if ($replicationInfo.Count -gt 0) {
    @(
        $sortedRepl | ForEach-Object {
            $rowClass = switch ($_.Health) {
                'Critical' { 'danger' } 'Warning' { 'warning' } default { 'success' }
            }
            $lastReplAge = if ($_.LastReplicationTime) {
                $span = $replNow - $_.LastReplicationTime
                if ($span.TotalDays -ge 1) { "$([math]::Round($span.TotalDays, 1)) days ago" }
                elseif ($span.TotalHours -ge 1) { "$([math]::Round($span.TotalHours, 1)) hrs ago" }
                else { "$([math]::Round($span.TotalMinutes, 0)) min ago" }
            } else { 'Never' }
            $freqLabel = switch ($_.FrequencyOfReplicationSec) {
                30 { '30 sec' } 300 { '5 min' } 900 { '15 min' } default { "$($_.FrequencyOfReplicationSec) sec" }
            }
            "<tr class='$rowClass'><td>$(ConvertTo-HtmlEncoded $_.Vm)</td><td>$(ConvertTo-HtmlEncoded $_.Health)</td><td>$(ConvertTo-HtmlEncoded $_.State)</td><td>$(ConvertTo-HtmlEncoded $_.ReplicationMode)</td><td>$freqLabel</td><td>$(ConvertTo-HtmlEncoded $lastReplAge)</td></tr>"
        }
        $unreplicatedVms | ForEach-Object {
            "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>Not configured</td><td>N/A</td><td>N/A</td><td>N/A</td><td>N/A</td></tr>"
        }
    ) -join "`n"
} else { $null }

# --- Report generation ---

$reportBody = @(
    New-HyperVWarningsSectionHtml -Summary $summary -ReplicationInfo $replicationInfo `
        -CpuNumaFindings $cpuNumaFindings -CheckpointFindings $checkpointFindings `
        -CsvData $csvData -CsvCritThresholdPct $csvCritThresholdPct `
        -CsvWarnThresholdPct $csvWarnThresholdPct

    # Resource Report
    New-HtmlTable -Title 'Resource Report' -Icon 'fas fa-gauge-high' `
        -Headers @('Resource', 'Usage', 'Available') `
        -Rows ((@(
                # RAM (Assigned - Live)
                $ramAssignedPct = if ($summary.TotalHostMemoryGB -gt 0) {
                    [math]::Round($summary.TotalAssignedRAMGB / $summary.TotalHostMemoryGB * 100, 1)
                } else { 0 }
                $ramAssignedBar = New-HtmlProgressBar `
                    -Label "$([math]::Round($summary.TotalAssignedRAMGB,2)) / $([math]::Round($summary.TotalHostMemoryGB,2)) GB ($ramAssignedPct%)" `
                    -Color (Get-ProgressBarColor -Percent $ramAssignedPct) `
                    -Percent $ramAssignedPct
                "<tr><td>RAM (Assigned - Live)</td><td>$ramAssignedBar</td><td>$([math]::Round($summary.TotalHostMemoryGB - $summary.TotalAssignedRAMGB, 2)) GB free</td></tr>"
                # RAM (Startup - All VMs)
                $ramStartupPct = if ($summary.TotalHostMemoryGB -gt 0) {
                    [math]::Round($summary.TotalStartupRAMGB / $summary.TotalHostMemoryGB * 100, 1)
                } else { 0 }
                $ramStartupBar = New-HtmlProgressBar `
                    -Label "$([math]::Round($summary.TotalStartupRAMGB,2)) / $([math]::Round($summary.TotalHostMemoryGB,2)) GB ($ramStartupPct%)" `
                    -Color (Get-ProgressBarColor -Percent $ramStartupPct) `
                    -Percent $ramStartupPct
                "<tr><td>RAM (Startup - All VMs)</td><td>$ramStartupBar</td><td>$([math]::Round($summary.TotalHostMemoryGB - $summary.TotalStartupRAMGB, 2)) GB free</td></tr>"
                # CPU (Assigned - Live)
                $cpuLivePct = if ($summary.TotalHostCores -gt 0) {
                    [math]::Round($summary.TotalLiveCPUs / $summary.TotalHostCores * 100, 1)
                } else { 0 }
                $cpuLiveBar = New-HtmlProgressBar `
                    -Label "$($summary.TotalLiveCPUs) / $($summary.TotalHostCores) CPUs ($cpuLivePct%)" `
                    -Color (Get-ProgressBarColor -Percent $cpuLivePct) `
                    -Percent $cpuLivePct
                "<tr><td>CPU (Assigned - Live)</td><td>$cpuLiveBar</td><td>$($summary.TotalHostCores - $summary.TotalLiveCPUs) cores free</td></tr>"
                # CPU (All VMs)
                $cpuAllPct = if ($summary.TotalHostCores -gt 0) {
                    [math]::Round($summary.TotalAssignedCPUs / $summary.TotalHostCores * 100, 1)
                } else { 0 }
                $cpuAllBar = New-HtmlProgressBar `
                    -Label "$($summary.TotalAssignedCPUs) / $($summary.TotalHostCores) CPUs ($cpuAllPct%)" `
                    -Color (Get-ProgressBarColor -Percent $cpuAllPct) `
                    -Percent $cpuAllPct
                "<tr><td>CPU (All VMs)</td><td>$cpuAllBar</td><td>$($summary.TotalHostCores - $summary.TotalAssignedCPUs) cores free</td></tr>"
            ) | Where-Object { $_ -match '^<tr' }) -join "`n")

    # Physical Drives (hidden when all VHDs are on CSVs)
    if ($physicalDrives.Count -gt 0) {
        New-HtmlTable -Title 'Physical Drives' -Icon 'fas fa-hard-drive' `
            -Headers @('Drive', 'Capacity', 'Provisioned / Committed', 'Other Files', 'Free (GB)') `
            -Rows (($physicalDrives | ForEach-Object {
                    $drivePct = [math]::Round($_.TotalCommittedVirtualGB / $_.PhysicalDriveCapacityGB * 100, 1)
                    $driveBarColor = Get-AlertColor -Level $_.RowColor
                    $provCommCell = New-HtmlProgressBar `
                        -Label "$([math]::Round($_.TotalProvisionedVirtualGB,2)) / $([math]::Round($_.TotalCommittedVirtualGB,2)) GB ($drivePct%)" `
                        -Color $driveBarColor `
                        -Percent $drivePct
                    "<tr class='$($_.RowColor)'><td>$(ConvertTo-HtmlEncoded $_.PhysicalDriveLetter)</td><td>$([math]::Round($_.PhysicalDriveCapacityGB,2)) GB</td><td>$provCommCell</td><td>$([math]::Round($_.NonVmFilesGB,2)) GB</td><td>$([math]::Round($_.HeadroomGB,2)) GB</td></tr>"
                }) -join "`n")
    }

    # Cluster Shared Volumes (clustered hosts only)
    if ($isClustered) {
        New-HtmlTable -Title 'Cluster Shared Volumes' -Icon 'fas fa-server' `
            -Headers @('CSV Name', 'Volume Path', 'Owner Node', 'Capacity (GB)', 'Used / Free', 'Free (GB)') `
            -Rows (($csvData | ForEach-Object {
                    $csvUsedPct = [math]::Round(100 - $_.PercentFree, 1)
                    $csvBarColor = Get-AlertColor -Level $_.RowColor
                    $csvUsageBar = New-HtmlProgressBar `
                        -Label "$($_.UsedGB) / $($_.SizeGB) GB ($($_.PercentFree)% free)" `
                        -Color $csvBarColor `
                        -Percent $csvUsedPct
                    "<tr class='$($_.RowColor)'><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>$(ConvertTo-HtmlEncoded $_.Path)</td><td>$(ConvertTo-HtmlEncoded $_.OwnerNode)</td><td>$($_.SizeGB)</td><td>$csvUsageBar</td><td>$($_.FreeGB) GB</td></tr>"
                }) -join "`n") `
            -EmptyMessage 'No Cluster Shared Volumes found.'
    }

    New-HyperVVmDetailsSectionHtml -AllVMs $allVMs -AllVirtualDisks $allVirtualDisks `
        -LogicalCoresPerNuma $logicalCoresPerNuma

    # CPU / NUMA Configuration
    "<h3><i class='fas fa-microchip'></i>&nbsp;&nbsp;CPU / NUMA Configuration</h3>" +
    "<p>Host NUMA nodes: $numaNodeCount &nbsp;|&nbsp; Logical CPUs per NUMA node: $logicalCoresPerNuma</p>" +
    (New-HtmlTable -Headers @('VM', 'Severity', 'Finding') `
        -Rows (($cpuNumaFindings | ForEach-Object {
                $rowClass = if ($_.Level -eq 'Warning') { " class='warning'" } else { '' }
                "<tr$rowClass><td>$(ConvertTo-HtmlEncoded $_.Vm)</td><td>$(ConvertTo-HtmlEncoded $_.Level)</td><td>$(ConvertTo-HtmlEncoded $_.Message)</td></tr>"
            }) -join "`n") `
        -EmptyMessage 'No CPU/NUMA configuration concerns found.') +
    "<p><strong>Guidance: </strong><a href='https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn282282(v=ws.11)' target='_blank'>NUMA &amp; vCPU Sizing</a> &nbsp;|&nbsp; <a href='https://blog.workinghardinit.work/2016/06/21/the-hyper-v-processor-virtual-machine-reserve/' target='_blank'>CPU Reserve &amp; Maximum</a> &nbsp;|&nbsp; <a href='https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/configure-processor-compatibility-mode' target='_blank'>Processor Compatibility Mode</a> &nbsp;|&nbsp; <a href='https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-minroot-2016' target='_blank'>Host Resource Protection</a></p>"

    # Replication Health
    New-HtmlTable -Title 'Replication Health' -Icon 'fas fa-copy' `
        -Headers @('VM Name', 'Health', 'State', 'Mode', 'Frequency', 'Last Replicated') `
        -Rows $replRows

    # Checkpoint Health
    New-HtmlTable -Title 'Checkpoint Health' -Icon 'fas fa-camera' `
        -Headers @('VM', 'Severity', 'Category', 'Finding') `
        -Rows (($checkpointFindings | ForEach-Object {
                $rowClass = if ($_.Level -eq 'Critical') { " class='danger'" } elseif ($_.Level -eq 'Warning') { " class='warning'" } else { '' }
                "<tr$rowClass><td>$(ConvertTo-HtmlEncoded $_.Vm)</td><td>$(ConvertTo-HtmlEncoded $_.Level)</td><td>$(ConvertTo-HtmlEncoded $_.Category)</td><td>$(ConvertTo-HtmlEncoded $_.Message)</td></tr>"
            }) -join "`n") `
        -EmptyMessage 'No checkpoint concerns found.'
) -join "`n"

$summaryReportHTML = Get-NinjaOneCard -Title 'Hyper-V Health' -Body $reportBody -Icon 'fas fa-hard-drive'
try {
    $summaryReportHTML | Ninja-Property-Set-Piped -Name hypervHealth
} catch {
    Write-Warning "Failed to set NinjaOne field: $_"
}

# Alerting — console warnings for log visibility
if ($summary.OverprovisionedDisk) {
    Write-Warning 'Disk Overprovisioned: Total provisioned virtual disk space exceeds total physical capacity.'
}
if ($summary.OverprovisionedRAM) {
    Write-Warning 'RAM Overprovisioned: Total configured startup RAM exceeds total host memory.'
}
if ($summary.OverprovisionedCPU) {
    Write-Warning 'CPU Overprovisioned: Total assigned vCPUs exceed total host logical cores.'
}
foreach ($f in @($checkpointFindings | Where-Object { $_.Level -in 'Warning', 'Critical' })) {
    Write-Warning "Checkpoint $($f.Level) [$($f.Category)] - $($f.Vm): $($f.Message)"
}
foreach ($v in $csvCriticalVolumes) {
    Write-Warning "CSV Critical: $($v.Name) ($($v.Path)) - $($v.PercentFree)% free ($($v.FreeGB) GB of $($v.SizeGB) GB)."
}
foreach ($v in $csvWarningVolumes) {
    Write-Warning "CSV Warning: $($v.Name) ($($v.Path)) - $($v.PercentFree)% free ($($v.FreeGB) GB of $($v.SizeGB) GB)."
}

# Exit code: 0 = healthy, 1 = warning, 2 = critical
# Each category's contribution is gated by its alert flag.
# Severity rationale:
#   Disk/RAM overprovisioning (Level 2): host cannot cold-boot all VMs — hard capacity failure.
#   CPU overprovisioning (Level 1):      scheduling pressure, but VMs continue running — recoverable.
$exitChecks = @(
    [pscustomobject]@{ Flag = $alertOnDiskOverprovisioning; Condition = $summary.OverprovisionedDisk; Level = 2 }
    [pscustomobject]@{ Flag = $alertOnRAMOverprovisioning; Condition = $summary.OverprovisionedRAM; Level = 2 }
    [pscustomobject]@{ Flag = $alertOnCPUOverprovisioning; Condition = $summary.OverprovisionedCPU; Level = 1 }
    [pscustomobject]@{ Flag = $alertOnReplicationCritical; Condition = (@($replicationInfo | Where-Object { $_.Health -eq 'Critical' }).Count -gt 0); Level = 2 }
    [pscustomobject]@{ Flag = $alertOnReplicationWarning; Condition = (@($replicationInfo | Where-Object { $_.Health -eq 'Warning' }).Count -gt 0); Level = 1 }
    [pscustomobject]@{ Flag = $alertOnCheckpointCritical; Condition = (@($checkpointFindings | Where-Object { $_.Level -eq 'Critical' }).Count -gt 0); Level = 2 }
    [pscustomobject]@{ Flag = $alertOnCheckpointWarning; Condition = (@($checkpointFindings | Where-Object { $_.Level -eq 'Warning' }).Count -gt 0); Level = 1 }
    [pscustomobject]@{ Flag = $alertOnCSVCritical; Condition = ($csvCriticalVolumes.Count -gt 0); Level = 2 }
    [pscustomobject]@{ Flag = $alertOnCSVWarning; Condition = ($csvWarningVolumes.Count -gt 0); Level = 1 }
)
$exitLevel = 0
foreach ($check in $exitChecks) {
    if ($check.Flag -and $check.Condition) { $exitLevel = [math]::Max($exitLevel, $check.Level) }
}

exit $exitLevel