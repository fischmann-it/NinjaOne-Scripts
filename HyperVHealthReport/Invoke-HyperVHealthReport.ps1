#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Hyper-V host health report for NinjaOne — audits disk, RAM, CPU/NUMA, replication, checkpoint,
    networking, and cluster storage health, then publishes an HTML dashboard and a machine-parseable
    JSON snapshot to custom fields and returns a Warning/Critical exit code for use as a Condition.

.DESCRIPTION
    Collects capacity and health data from a Hyper-V host. Supports two operation modes:

    Automation mode ($writeHtmlReport = $true, default):
      Generates a full HTML report and writes it to the NinjaOne WYSIWYG custom field 'hypervHealth'.
      Use on a scheduled Automation to keep the field current.

    Condition mode ($writeHtmlReport = $false):
      Skips HTML generation and field writes entirely — only evaluates exit codes and writes
      console warnings. Use when deploying as a NinjaOne Condition to avoid redundant field updates
      on every polling cycle.

    Checks performed:
      - Disk: flags drives where provisioned virtual space leaves less than $diskWarnThresholdGB GB headroom
      - RAM:  flags startup RAM sum vs total host memory (cannot cold-boot all VMs simultaneously)
      - CPU:  flags vCPU:pCore oversubscription ratio and per-VM NUMA span issues
      - Replication: reports Hyper-V Replica health, relationship, primary/replica servers, and last
        replication time per VM; powered-off replica targets are shown as healthy, not stopped
      - Checkpoints: flags long-lived, oversized, or deep checkpoint chains per VM
      - Networking: reports host NICs, IP config, virtual switches, NIC teams, and per-VM adapters/VLANs (report-only)
      - Cluster Storage: reports CSV free space on clustered hosts (section hidden on non-clustered hosts)

    Exit codes (usable as a NinjaOne Condition):
      0 — No enabled alert categories are breached
      1 — At least one enabled category is in a Warning state
      2 — At least one enabled category is in a Critical state

    Requires: Hyper-V PowerShell module, Administrator privileges, SYSTEM or Domain account context.

.NOTES
    NinjaOne Custom Field (WYSIWYG): hypervHealth
    NinjaOne Custom Field (MultiLine): hypervHealthData — machine-parseable JSON of all collected
        data (host/summary/VMs/disks/replication/checkpoints/networking) plus a unified findings
        list, for retrieval and parsing via the NinjaOne API.
        Schema 1.1 emits raw integer byte counts and full file paths alongside the rounded GB
        fields (which the HTML report still consumes) so downstream tools (SQL/BrightGauge) can
        format values themselves. Byte/path additions: host.totalMemoryBytes; per-VM vmId,
        assigned/startup/minimum/maximumRAMBytes, uptimeSeconds; per-disk Path, ParentPath,
        VirtualSizeBytes, FileSizeBytes, PhysicalDriveCapacity/FreeBytes; physicalDrives and
        clusterSharedVolumes *Bytes fields; and a checkpointInventory[] array (one entry per
        checkpoint: Vm, Name, CheckpointType, ParentName, CreationTime, SizeBytes/SizeGB) that is
        separate from the threshold-based checkpoints findings list.
    Designed for: NinjaOne Automation / Condition on Hyper-V hosts
    Run As: SYSTEM

    Script Variables (all optional — I recommend configuring in NinjaOne to override defaults instead of hardcoding changes, that way updates to the script can be drop-in without losing custom thresholds or alert flags):
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
    ├──────────────────────────────┼──────────┼─────────┼──────────────────────────────────────────────────────┤
    │ writeHtmlReport              │ Boolean  │ true    │ Generate the HTML dashboard and write 'hypervHealth'.│
    │                              │          │         │ Set false for Condition use to skip field writes.    │
    │ writeJsonReport              │ Boolean  │ true    │ Generate JSON and write 'hypervHealthData'.          │
    └──────────────────────────────┴──────────┴─────────┴──────────────────────────────────────────────────────┘

    Alert flags let you suppress noisy categories from affecting the Condition exit code while still
    surfacing them in the HTML report. For example: disable alertOnCPUOverprovisioning on hosts where
    moderate oversubscription is intentional, while keeping the visual report accurate.

    Script variables are optional — defaults work out of the box. Configure them in NinjaOne to customise
    behaviour per device or Condition. For example: set up multiple Conditions with different alert
    categories enabled per environment, or override a threshold at the device level for edge cases.

    TODO:
    - More Clustering data.
    - VM Auto-Start when a cluster role, should reflect cluster config
    - CPU ratio labeling: messages say "vCPU:pCore" but the denominator is NumberOfLogicalProcessors
      (SMT threads), so the ratio is actually vCPU:LP. This matches Microsoft's VP:LP metric and the
      8:1 warn / 4:1 info thresholds are correct against LP — only the "pCore" label is wrong.
      Rename to "vCPU:LP" (lines ~24, ~837, ~847, ~853, and the CPU overprovision messages).
    - Per-VM "exceeds host physical core count" check uses ($TotalHostCores / 2) to guess physical
      cores (assumes SMT=2). Use actual Win32_Processor.NumberOfCores instead (breaks when SMT off).
    - Consider Core Scheduler awareness (default since Server 2019): only one VM per physical core,
      so threads-based vCPU:LP overstates real density — effective ceiling is nearer vCPU:physical-core.
#>

#region Helper Functions

function Test-IsSystem {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return $id.IsSystem -or $id.Name -like 'NT AUTHORITY*'
}

function Get-EnvWithDefault {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Default,
        [Parameter(Mandatory)] [type]$Type
    )
    $raw = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrEmpty($raw)) {
        if ($Type -eq [bool]) {
            return 'true', '1', 'yes' -icontains $raw
        }
        $result = $raw -as $Type
        if ($null -ne $result) {
            return $result
        }
    }
    return $Default
}

function ConvertTo-HtmlEncoded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }
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
        $iconHtml = if ($Icon) {
            "<i class='$Icon'></i>&nbsp;&nbsp;"
        } else {
            ''
        }
        "<h3>$iconHtml$Title</h3>"
    } else {
        ''
    }

    if (-not $Rows) {
        if ($EmptyMessage) {
            return "$heading<p class='text-success'>$EmptyMessage</p>"
        }
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
    $icon = if ($Level -eq 'error') {
        'fa-solid fa-circle-exclamation'
    } else {
        'fa-solid fa-triangle-exclamation'
    }

    # Style configuration for each level with dark mode support
    $styles = @{
        'error'   = @{
            bgColor     = '#f2dede'
            borderColor = '#d9534f'
            textColor   = '#a94442'
            iconColor   = '#d9534f'
        }
        'warning' = @{
            bgColor     = '#fcf8e3'
            borderColor = '#f0ad4e'
            textColor   = '#8a6d3b'
            iconColor   = '#f0ad4e'
        }
        'info'    = @{
            bgColor     = '#d9edf7'
            borderColor = '#5bc0de'
            textColor   = '#31708f'
            iconColor   = '#5bc0de'
        }
    }

    $style = $styles[$Level]
    $cardStyle = "background-color:$($style.bgColor);border:1px solid $($style.borderColor);border-radius:4px;padding:12px;display:flex;align-items:flex-start;gap:12px;"
    $iconStyle = "color:$($style.iconColor);font-size:20px;flex-shrink:0;margin-top:2px;"
    $textStyle = 'flex:1;min-width:0;'
    $titleStyle = "font-weight:600;margin-bottom:4px;color:$($style.textColor);"
    $descStyle = "font-size:14px;line-height:1.4;color:$($style.textColor);"

    return "<div class='info-card $Level' style='$cardStyle'><i class='info-icon $icon' style='$iconStyle'></i><div class='info-text' style='$textStyle'><div class='info-title' style='$titleStyle'>$Title</div><div class='info-description' style='$descStyle'>$Description</div></div></div>"
}

function Get-AlertColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('danger', 'warning', 'success')]
        [string]$Level
    )
    switch ($Level) {
        'danger' {
            return '#d9534f'
        }
        'warning' {
            return '#f0ad4e'
        }
        default {
            return '#5cb85c'
        }
    }
}

function Get-ProgressBarColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double]$Percent,
        [int]$WarnPct = 70,
        [int]$CritPct = 90
    )
    if ($Percent -ge $CritPct) {
        return '#d9534f'
    }
    if ($Percent -ge $WarnPct) {
        return '#f0ad4e'
    }
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
        [int]$CsvWarnThresholdPct,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [string[]]$ReplicationCriticalStates,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [string[]]$ReplicationWarningStates
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

    foreach ($r in @($ReplicationInfo | Where-Object {
                $_.Health -in 'Warning', 'Critical' -or
                $_.State -in $ReplicationCriticalStates -or
                $_.State -in $ReplicationWarningStates
            })) {
        $isCritical = $r.Health -eq 'Critical' -or $r.State -in $ReplicationCriticalStates
        $level = if ($isCritical) { 'error' } else { 'warning' }
        $severity = if ($isCritical) { 'Critical' } else { 'Warning' }
        $items.Add((New-HtmlInfoCard -Level $level -Title "Replication $severity`: $(ConvertTo-HtmlEncoded $r.Vm)" -Description "State: $(ConvertTo-HtmlEncoded $r.State)"))
    }

    # Info-level CPU/NUMA findings (e.g. processor flags, CPU caps) are intentionally excluded
    # from the warnings section — they appear in the CPU/NUMA detail table below the fold.
    foreach ($f in @($CpuNumaFindings | Where-Object { $_.Level -eq 'Warning' })) {
        $items.Add((New-HtmlInfoCard -Level 'warning' -Title "CPU/NUMA: $(ConvertTo-HtmlEncoded $f.Vm)" -Description $(ConvertTo-HtmlEncoded $f.Message)))
    }

    foreach ($f in @($CheckpointFindings | Where-Object { $_.Level -in 'Warning', 'Critical' })) {
        $level = if ($f.Level -eq 'Critical') {
            'error'
        } else {
            'warning'
        }
        $items.Add((New-HtmlInfoCard -Level $level -Title "Checkpoint $($f.Level): $(ConvertTo-HtmlEncoded $f.Vm)" -Description $(ConvertTo-HtmlEncoded $f.Message)))
    }

    $csvCrit = @($CsvData | Where-Object { $_.RowColor -eq 'danger' })
    $csvWarn = @($CsvData | Where-Object { $_.RowColor -eq 'warning' })
    if ($csvCrit.Count -gt 0) {
        $items.Add((New-HtmlInfoCard -Level 'error' -Title 'CSV Storage Critical' -Description "$($csvCrit.Count) volume(s) are below $CsvCritThresholdPct% free space."))
    }
    if ($csvWarn.Count -gt 0) {
        $items.Add((New-HtmlInfoCard -Level 'warning' -Title 'CSV Storage Warning' -Description "$($csvWarn.Count) volume(s) are below $CsvWarnThresholdPct% free space."))
    }

    if ($items.Count -eq 0) {
        return ''
    }
    $colItems = ($items | ForEach-Object { "<div class='col'>$_</div>" }) -join ''
    return "<h3><i class='fas fa-triangle-exclamation'></i>&nbsp;&nbsp;Warnings</h3><div class='row row-cols-1 row-cols-md-2 g-2'>$colItems</div>"
}

function Format-VlanLabel {
    [CmdletBinding()]
    param(
        [string]$VlanMode,
        [int]$AccessVlanId,
        [int]$NativeVlanId,
        [AllowEmptyCollection()]
        [object[]]$AllowedVlanIds = @()
    )
    switch ($VlanMode) {
        'Access' {
            return "VLAN $AccessVlanId (Access)"
        }
        'Trunk' {
            $allowed = (@($AllowedVlanIds) -join ', ')
            if ($allowed) {
                return "Trunk (native $NativeVlanId; allowed $allowed)"
            }
            return "Trunk (native $NativeVlanId)"
        }
        default {
            return 'Untagged'
        }
    }
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
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$AllVmNics,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$AllVmIntegrationServices,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$ReplicationInfo,
        [Parameter(Mandatory)]
        [int]$LogicalCoresPerNuma
    )
    # Manual hashtable build: Group-Object -AsHashTable returns a case-sensitive Hashtable;
    # @{} is case-insensitive, so VM name lookups work regardless of casing differences.
    $disksByVm = @{}
    foreach ($d in $AllVirtualDisks) {
        $disksByVm[$d.Vm] += @($d)
    }
    $nicsByVm = @{}
    foreach ($n in $AllVmNics) {
        $nicsByVm[$n.Vm] += @($n)
    }
    $integByVm = @{}
    foreach ($s in $AllVmIntegrationServices) {
        $integByVm[$s.Vm] += @($s)
    }

    # VM names that are the receiving end of replication (Replica / Extended Replica). A replica
    # target is expected to be powered off until failover, so it is treated as healthy, not stopped.
    $replicaTargetVms = @($ReplicationInfo | Where-Object { $_.ReplicationMode -in 'Replica', 'ExtendedReplica' } | ForEach-Object { $_.Vm })

    $vmDetails = $AllVMs | ForEach-Object {
        $vm = $_
        [pscustomobject]@{
            Vm                       = $vm.Name
            State                    = $vm.State
            AssignedCPUs             = [int]($vm.ProcessorCount)
            AssignedRAMGB            = [math]::Round($vm.MemoryAssigned / 1GB, 2)
            StartupRAMGB             = [math]::Round($vm.MemoryStartup / 1GB, 2)
            AutomaticStartAction     = [string]$vm.AutomaticStartAction
            AutomaticStartDelay      = [int]$vm.AutomaticStartDelay
            Generation               = [int]$vm.Generation
            ConfigVersion            = [string]$vm.Version
            Uptime                   = $vm.Uptime
            IntegrationServicesState = [string]$vm.IntegrationServicesState
            Disks                    = $disksByVm[$vm.Name]
            Nics                     = $nicsByVm[$vm.Name]
            Integrations             = $integByVm[$vm.Name]
        }
    }

    $cards = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in $vmDetails) {
        $vmName = $(ConvertTo-HtmlEncoded $vm.Vm)
        $stateText = $(ConvertTo-HtmlEncoded $vm.State)
        $isOffReplicaTarget = ($vm.State -eq 'Off') -and ($replicaTargetVms -contains $vm.Vm)
        $stateColor = if ($isOffReplicaTarget) {
            '#3c763d'
        } else {
            switch ($vm.State) {
                'Running' {
                    '#3c763d'
                }
                'Off' {
                    '#777'
                }
                'Paused' {
                    '#8a6d3b'
                }
                'Saved' {
                    '#8a6d3b'
                }
                default {
                    '#ccc'
                }
            }
        }
        $stateLabel = if ($isOffReplicaTarget) {
            "$stateText &middot; Replica target"
        } else {
            $stateText
        }
        $stateBadge = "<span style='color:$stateColor'>[$stateLabel]</span>"


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
        if ($vm.AutomaticStartDelay -gt 0) {
            $autoStartDisplay += " (delay: $($vm.AutomaticStartDelay)s)"
        }

        $specLine = "<p>vCPUs: $($vm.AssignedCPUs)$numaFlag &nbsp;|&nbsp; RAM: $ramDisplay &nbsp;|&nbsp; Auto-start: $(ConvertTo-HtmlEncoded $autoStartDisplay)</p>"

        $uptimeDisplay = if ($vm.State -eq 'Running' -and $vm.Uptime -and $vm.Uptime.TotalSeconds -gt 0) {
            $u = $vm.Uptime
            if ($u.TotalDays -ge 1) {
                "$([int]$u.TotalDays)d $($u.Hours)h $($u.Minutes)m"
            } elseif ($u.TotalHours -ge 1) {
                "$($u.Hours)h $($u.Minutes)m"
            } else {
                "$($u.Minutes)m"
            }
        } else {
            '&mdash;'
        }
        $integStateDisplay = if ($vm.IntegrationServicesState) {
            $(ConvertTo-HtmlEncoded $vm.IntegrationServicesState)
        } else {
            '&mdash;'
        }
        $specLine2 = "<p>Generation: Gen $($vm.Generation) &nbsp;|&nbsp; Config Version: $(ConvertTo-HtmlEncoded $vm.ConfigVersion) &nbsp;|&nbsp; Uptime: $uptimeDisplay &nbsp;|&nbsp; Integration Services: $integStateDisplay</p>"

        $integTags = if ($vm.Integrations -and @($vm.Integrations).Count -gt 0) {
            (@($vm.Integrations) | ForEach-Object {
                $svcName = $(ConvertTo-HtmlEncoded $_.Name)
                $tagClass = if (-not $_.Enabled) {
                    'tag disabled'
                } elseif ($_.PrimaryStatus -and $_.PrimaryStatus -ne 'OK') {
                    'tag expired'
                } else {
                    'tag'
                }
                "<div class='$tagClass'>$svcName</div>"
            }) -join ' '
        } else {
            "<p class='text-success'>No integration services reported.</p>"
        }
        $integCaption = "<div style='margin-top:12px;margin-bottom:4px;'><strong><i class='fas fa-plug'></i>&nbsp;&nbsp;Integration Services</strong></div>"

        $diskRows = if ($vm.Disks -and $vm.Disks.Count -gt 0) {
            (@($vm.Disks) | ForEach-Object {
                $disk = $_
                $driveLetter = $(ConvertTo-HtmlEncoded $disk.PhysicalDriveLetter)
                $diskName = $(ConvertTo-HtmlEncoded $disk.VirtualDiskName)
                $fileName = $(ConvertTo-HtmlEncoded $disk.FileName)
                $diskType = $(ConvertTo-HtmlEncoded $disk.VirtualDiskType)
                $provisioned = [math]::Round($disk.ProvisionedVirtualGB, 2)
                $committed = [math]::Round($disk.CommittedVirtualGB, 2)
                $pct = if ($provisioned -gt 0) {
                    [math]::Min(100, [math]::Round($committed / $provisioned * 100, 1))
                } else {
                    0
                }
                $barColor = if ($disk.VirtualDiskType -eq 'Fixed') {
                    '#337ab7'
                } elseif ($pct -ge 85) {
                    '#d9534f'
                } elseif ($pct -ge 70) {
                    '#f0ad4e'
                } else {
                    '#5cb85c'
                }
                $diskCell = New-HtmlProgressBar -Label "$committed / $provisioned GB ($pct%)" -Color $barColor -Percent $pct
                "<tr><td>$driveLetter</td><td>$diskName</td><td>$fileName</td><td>$diskType</td><td>$diskCell</td></tr>"
            }) -join "`n"
        } else {
            $null
        }
        $diskTable = New-HtmlTable -Headers @('Drive', 'Disk Name', 'File Name', 'Type', 'Committed / Provisioned (GB)') -Rows $diskRows -EmptyMessage 'No virtual disks attached.'

        $nicRows = if ($vm.Nics -and $vm.Nics.Count -gt 0) {
            (@($vm.Nics) | ForEach-Object {
                $nic = $_
                $vlanLabel = $(ConvertTo-HtmlEncoded (Format-VlanLabel -VlanMode $nic.VlanMode -AccessVlanId $nic.AccessVlanId -NativeVlanId $nic.NativeVlanId -AllowedVlanIds $nic.AllowedVlanIds))
                $nicName = $(ConvertTo-HtmlEncoded $nic.AdapterName)
                $nicSwitch = $(ConvertTo-HtmlEncoded $nic.SwitchName)
                $nicMac = $(ConvertTo-HtmlEncoded $nic.MacAddress)
                $nicIps = if (@($nic.IPAddresses).Count -gt 0) {
                    (@($nic.IPAddresses) | ForEach-Object { ConvertTo-HtmlEncoded $_ }) -join ', '
                } else {
                    '&mdash;'
                }
                $nicConn = if ($nic.IsConnected) { 'Connected' } else { 'Disconnected' }
                "<tr><td>$nicName</td><td>$nicSwitch</td><td>$vlanLabel</td><td>$nicMac</td><td>$nicIps</td><td>$nicConn</td></tr>"
            }) -join "`n"
        } else {
            $null
        }
        $nicTable = New-HtmlTable -Headers @('Adapter', 'Switch', 'VLAN', 'MAC', 'IP', 'Status') -Rows $nicRows -EmptyMessage 'No network adapters attached.'

        $diskCaption = "<div style='margin-top:8px;margin-bottom:4px;'><strong><i class='fas fa-hard-drive'></i>&nbsp;&nbsp;Disks</strong></div>"
        $nicCaption = "<div style='margin-top:12px;margin-bottom:4px;'><strong><i class='fas fa-ethernet'></i>&nbsp;&nbsp;Network Adapters</strong></div>"

        $card = @"
<div class="col-12 d-flex">
<div class="card flex-grow-1" style="border-left:4px solid $stateColor;">
<div class="card-title-box"><div class="card-title">$vmName &nbsp; $stateBadge</div></div>
<div class="card-body">$specLine$specLine2$integCaption$integTags$diskCaption$diskTable$nicCaption$nicTable</div>
</div>
</div>
"@
        $cards.Add($card)
    }

    $grid = "<div class=`"row g-3`">$($cards -join "`n")</div>"
    return "<h3><i class='fas fa-desktop'></i>&nbsp;&nbsp;VM Details</h3>$grid"
}

function Get-VirtualDiskInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return [array]($AllVMs | ForEach-Object {
            $Vm = $_
            $_.HardDrives | ForEach-Object {
                try {
                    $GetVhd = Get-VHD -Path $_.Path -ErrorAction Stop
                    $vhdType = [string]$GetVhd.VhdType
                    $virtualSizeBytes = [long]$GetVhd.Size
                    $fileSizeBytes = [long]$GetVhd.FileSize
                    $parentPath = [string]$GetVhd.ParentPath
                } catch {
                    Write-Warning "Failed to read VHD '$($_.Path)': $_"
                    $vhdType = '[Error]'
                    $virtualSizeBytes = [long]0
                    $fileSizeBytes = [long]0
                    $parentPath = ''
                }
                $provisionedGB = [double]($virtualSizeBytes / 1GB)
                $committedGB = [double]($fileSizeBytes / 1GB)

                $diskPath = Split-Path $_.Path -Parent
                try {
                    $physicalDriveLetter = (Get-Item $diskPath -ErrorAction Stop).PSDrive.Name
                    $physicalDriveInfo = Get-PSDrive -Name $physicalDriveLetter -ErrorAction Stop
                } catch {
                    $physicalDriveLetter = 'Unknown'
                    $physicalDriveInfo = $null
                }
                $physicalDriveCapacityBytes = if ($physicalDriveInfo) { [long]($physicalDriveInfo.Used + $physicalDriveInfo.Free) } else { [long]0 }
                $physicalDriveFreeBytes = if ($physicalDriveInfo) { [long]$physicalDriveInfo.Free } else { [long]0 }

                [pscustomobject]@{
                    Vm                         = $Vm.Name
                    VirtualDiskName            = $_.Name
                    VirtualDiskType            = $vhdType
                    Path                       = [string]$_.Path
                    ParentPath                 = $parentPath
                    VirtualSizeBytes           = $virtualSizeBytes
                    FileSizeBytes              = $fileSizeBytes
                    ProvisionedVirtualGB       = $provisionedGB
                    CommittedVirtualGB         = $committedGB
                    FileName                   = [System.IO.Path]::GetFileName($_.Path)
                    IsOnCsv                    = ([string]$_.Path -like '*\ClusterStorage\*')
                    PhysicalDriveLetter        = $physicalDriveLetter
                    PhysicalDriveCapacityBytes = $physicalDriveCapacityBytes
                    PhysicalDriveFreeBytes     = $physicalDriveFreeBytes
                    PhysicalDriveCapacityGB    = [double]($physicalDriveCapacityBytes / 1GB)
                    PhysicalDriveFreeGB        = [double]($physicalDriveFreeBytes / 1GB)
                }
            }
        })
}

function Get-MemoryInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return [array]($AllVMs | ForEach-Object {
            [pscustomobject]@{
                Vm                   = $_.Name
                DynamicMemoryEnabled = [bool]$_.DynamicMemoryEnabled
                StartupRAMBytes      = [long]$_.MemoryStartup
                AssignedRAMBytes     = [long]$_.MemoryAssigned
                MinimumRAMBytes      = if ($_.DynamicMemoryEnabled) { [long]$_.MemoryMinimum } else { [long]0 }
                MaximumRAMBytes      = if ($_.DynamicMemoryEnabled) { [long]$_.MemoryMaximum } else { [long]0 }
                StartupRAMGB         = [double]($_.MemoryStartup / 1GB)
                AssignedRAMGB        = [double]($_.MemoryAssigned / 1GB)
                DynamicMaxCeilingGB  = if ($_.DynamicMemoryEnabled) {
                    [double]($_.MemoryMaximum / 1GB)
                } else {
                    0
                }
            }
        })
}

function Get-VMProcessorConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return [array]($AllVMs | ForEach-Object {
            $proc = Get-VMProcessor -VMName $_.Name -ErrorAction SilentlyContinue
            if (-not $proc) {
                Write-Warning "Get-VMProcessor returned nothing for VM '$($_.Name)'. CPU config checks will be skipped for this VM."
            }
            [pscustomobject]@{
                Vm                           = $_.Name
                AssignedCPUs                 = [int]$_.ProcessorCount
                IsRunning                    = ($_.State -eq 'Running')
                ProcReadFailed               = ($null -eq $proc)
                MaxCountPerNumaNode          = if ($proc) { [int]$proc.MaximumCountPerNumaNode } else { 0 }
                MaxCountPerNumaSocket        = if ($proc) { [int]$proc.MaximumCountPerNumaSocket } else { 0 }
                CompatibilityForMigration    = if ($proc) { [bool]$proc.CompatibilityForMigrationEnabled } else { $false }
                CompatibilityForOlderOS      = if ($proc) { [bool]$proc.CompatibilityForOlderOperatingSystemsEnabled } else { $false }
                EnableHostResourceProtection = if ($proc) { [bool]$proc.EnableHostResourceProtection } else { $false }
                Reserve                      = if ($proc) { [int]$proc.Reserve } else { 0 }
                Maximum                      = if ($proc) { [int]$proc.Maximum } else { 0 }
            }
        })
}

function Get-ReplicationInfo {
    [CmdletBinding()]
    param()
    try {
        return [array](Get-VMReplication -ErrorAction Stop | ForEach-Object {
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
            })
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
        $effectiveNumaSize = if ($vm.MaxCountPerNumaNode -gt 0) { $vm.MaxCountPerNumaNode } else { $LogicalCoresPerNuma }
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
    if (@($AllVirtualDisks).Length -eq 0) {
        return @()
    }
    return [array]($AllVirtualDisks | Group-Object -Property PhysicalDriveLetter | ForEach-Object {
            $physicalDriveLetter = $_.Name
            $physicalDriveCapacityBytes = [long]($_.Group | Select-Object -First 1 | ForEach-Object { $_.PhysicalDriveCapacityBytes })
            $physicalDriveFreeBytes = [long]($_.Group | Select-Object -First 1 | ForEach-Object { $_.PhysicalDriveFreeBytes })
            $totalProvisionedVirtualBytes = [long](($_.Group | Measure-Object -Property VirtualSizeBytes -Sum).Sum)
            $totalCommittedVirtualBytes = [long](($_.Group | Measure-Object -Property FileSizeBytes -Sum).Sum)

            $physicalDriveCapacity = [double]($physicalDriveCapacityBytes / 1GB)
            $physicalDriveFree = [double]($physicalDriveFreeBytes / 1GB)
            $totalProvisionedVirtual = [double]($totalProvisionedVirtualBytes / 1GB)
            $totalCommittedVirtual = [double]($totalCommittedVirtualBytes / 1GB)

            # Headroom: free space remaining if all VMs grew to their fully provisioned size
            # = actual free space - (provisioned max - currently committed)
            $headroomBytes = [long]($physicalDriveFreeBytes - ($totalProvisionedVirtualBytes - $totalCommittedVirtualBytes))
            $headroomGB = [double]($headroomBytes / 1GB)

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
                PhysicalDriveCapacityBytes        = $physicalDriveCapacityBytes
                PhysicalDriveFreeBytes            = $physicalDriveFreeBytes
                TotalProvisionedVirtualBytes      = $totalProvisionedVirtualBytes
                TotalCommittedVirtualBytes        = $totalCommittedVirtualBytes
                NonVmFilesBytes                   = [long]($physicalDriveCapacityBytes - $totalCommittedVirtualBytes - $physicalDriveFreeBytes)
                HeadroomBytes                     = $headroomBytes
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
        })
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
    # Empty $PhysicalDrives (e.g. an all-CSV clustered host) is handled by the sums below:
    # Measure-Object -Sum over an empty set yields $null -> [double]0, so disk evaluates false while
    # RAM/CPU (independent of local disks) are still computed correctly.
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
        [AllowEmptyCollection()]
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
        if ($checkpoints.Count -eq 0) {
            continue
        }

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
            $cpType = if ($cp.CheckpointType) {
                [string]$cp.CheckpointType
            } else {
                'Unknown'
            }

            Add-ThresholdFinding -FindingsList $findings -VmName $vm.Name -Category 'Age' `
                -Value $ageDays -CritThreshold $CritAgeDays -WarnThreshold $WarnAgeDays `
                -CritMessage "Checkpoint '$cpName' ($cpType) is $ageDays days old (critical threshold: $CritAgeDays days)." `
                -WarnMessage "Checkpoint '$cpName' ($cpType) is $ageDays days old (warning threshold: $WarnAgeDays days)."
        }
    }

    return $findings
}

function Get-CheckpointInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    $inventory = [System.Collections.Generic.List[pscustomobject]]::new()
    $vhdCache = @{}

    foreach ($vm in $AllVMs) {
        $checkpoints = @(Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue)
        foreach ($cp in $checkpoints) {
            # Per-checkpoint size: sum the FileSize of the AVHDX diff disks attached at this checkpoint.
            $sizeBytes = [long]0
            foreach ($hdd in @($cp.HardDrives)) {
                $cpPath = $hdd.Path
                if (-not $cpPath) {
                    continue
                }
                try {
                    if (-not $vhdCache.ContainsKey($cpPath)) {
                        $vhdCache[$cpPath] = Get-VHD -Path $cpPath -ErrorAction Stop
                    }
                    $sizeBytes += [long]$vhdCache[$cpPath].FileSize
                } catch {
                    continue
                }
            }
            $inventory.Add([pscustomobject]@{
                    Vm             = [string]$vm.Name
                    Name           = [string]$cp.Name
                    CheckpointType = if ($cp.CheckpointType) { [string]$cp.CheckpointType } else { 'Unknown' }
                    ParentName     = [string]$cp.ParentSnapshotName
                    CreationTime   = if ($cp.CreationTime) { $cp.CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
                    SizeBytes      = $sizeBytes
                    SizeGB         = [math]::Round($sizeBytes / 1GB, 2)
                })
        }
    }

    return [array]$inventory
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
        $sizeBytes = [long]$vol.Partition.Size
        $freeBytes = [long]$vol.Partition.FreeSpace
        $usedBytes = [long]($sizeBytes - $freeBytes)
        $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
        $freeGB = [math]::Round($freeBytes / 1GB, 2)
        $usedGB = [math]::Round($usedBytes / 1GB, 2)
        $pctFree = if ($sizeBytes -gt 0) {
            [math]::Round($freeBytes / $sizeBytes * 100, 1)
        } else {
            0
        }
        $rowColor = if ($pctFree -le $csvCritThresholdPct) {
            'danger'
        } elseif ($pctFree -le $csvWarnThresholdPct) {
            'warning'
        } else {
            'success'
        }
        $results.Add([pscustomobject]@{
                Name        = $csv.Name
                Path        = $vol.FriendlyVolumeName
                OwnerNode   = $csv.OwnerNode.Name
                SizeBytes   = $sizeBytes
                FreeBytes   = $freeBytes
                UsedBytes   = $usedBytes
                SizeGB      = $sizeGB
                FreeGB      = $freeGB
                UsedGB      = $usedGB
                PercentFree = $pctFree
                RowColor    = $rowColor
            })
    }
    return $results
}

function Get-HostNetworkAdapterInfo {
    [CmdletBinding()]
    param()
    try {
        return [array](Get-NetAdapter -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name                 = [string]$_.Name
                    InterfaceDescription = [string]$_.InterfaceDescription
                    IfIndex              = [int]$_.ifIndex
                    MacAddress           = [string]$_.MacAddress
                    LinkSpeed            = [string]$_.LinkSpeed
                    Status               = [string]$_.Status
                    MediaType            = [string]$_.MediaType
                    DriverVersion        = [string]$_.DriverVersion
                    IsVirtual            = [bool]$_.Virtual
                }
            })
    } catch {
        Write-Warning "Get-NetAdapter failed: $_"
        return @()
    }
}

function Get-VirtualSwitchInfo {
    [CmdletBinding()]
    param()
    try {
        return [array](Get-VMSwitch -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name                           = [string]$_.Name
                    SwitchType                     = [string]$_.SwitchType
                    NetAdapterInterfaceDescription = [string]$_.NetAdapterInterfaceDescription
                    EmbeddedTeamingEnabled         = [bool]$_.EmbeddedTeamingEnabled
                    AllowManagementOS              = [bool]$_.AllowManagementOS
                    BandwidthReservationMode       = [string]$_.BandwidthReservationMode
                    IovEnabled                     = [bool]$_.IovEnabled
                }
            })
    } catch {
        Write-Warning "Get-VMSwitch failed: $_"
        return @()
    }
}

function Get-NicTeamInfo {
    [CmdletBinding()]
    param()
    $teams = [System.Collections.Generic.List[pscustomobject]]::new()

    # LBFO teams: Get-NetLbfoTeam is absent on Server Core / when the LBFO feature is unavailable
    if (Get-Command -Name 'Get-NetLbfoTeam' -ErrorAction SilentlyContinue) {
        try {
            foreach ($t in @(Get-NetLbfoTeam -ErrorAction Stop)) {
                $teams.Add([pscustomobject]@{
                        TeamType      = 'LBFO'
                        Name          = [string]$t.Name
                        TeamingMode   = [string]$t.TeamingMode
                        LoadBalancing = [string]$t.LoadBalancingAlgorithm
                        Status        = [string]$t.Status
                        Members       = @($t.Members)
                    })
            }
        } catch {
            Write-Warning "Get-NetLbfoTeam failed: $_"
        }
    }

    # SET (Switch Embedded Teaming) teams are exposed on the vSwitch. Querying a non-teamed switch
    # emits a benign "Teaming is not enabled" error, so enumerate only embedded-teaming switches.
    if (Get-Command -Name 'Get-VMSwitchTeam' -ErrorAction SilentlyContinue) {
        foreach ($sw in @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.EmbeddedTeamingEnabled })) {
            try {
                $st = Get-VMSwitchTeam -Name $sw.Name -ErrorAction Stop
                $teams.Add([pscustomobject]@{
                        TeamType      = 'SET'
                        Name          = [string]$st.Name
                        TeamingMode   = [string]$st.TeamingMode
                        LoadBalancing = [string]$st.LoadBalancingAlgorithm
                        Status        = ''
                        Members       = @($st.NetAdapterInterfaceDescription)
                    })
            } catch {
                Write-Warning "Get-VMSwitchTeam failed for '$($sw.Name)': $_"
            }
        }
    }

    return [array]$teams
}

function Get-VMNetworkAdapterInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return [array]($AllVMs | ForEach-Object {
            $vmName = $_.Name
            Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue | ForEach-Object {
                $adapter = $_
                $vlan = $null
                try {
                    $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -ErrorAction Stop
                } catch {
                    $vlan = $null
                }
                [pscustomobject]@{
                    Vm             = [string]$vmName
                    AdapterName    = [string]$adapter.Name
                    SwitchName     = [string]$adapter.SwitchName
                    MacAddress     = [string]$adapter.MacAddress
                    DynamicMac     = [bool]$adapter.DynamicMacAddressEnabled
                    IsConnected    = [bool]$adapter.Connected
                    IsLegacy       = [bool]$adapter.IsLegacy
                    Status         = [string[]]@($adapter.Status | ForEach-Object { [string]$_ })
                    IPAddresses    = [string[]]@($adapter.IPAddresses | ForEach-Object { [string]$_ })
                    VlanMode       = if ($vlan) { [string]$vlan.OperationMode } else { 'Untagged' }
                    AccessVlanId   = if ($vlan) { [int]$vlan.AccessVlanId } else { 0 }
                    NativeVlanId   = if ($vlan) { [int]$vlan.NativeVlanId } else { 0 }
                    AllowedVlanIds = [int[]]@(if ($vlan -and $vlan.AllowedVlanIdList) { $vlan.AllowedVlanIdList } else { @() })
                }
            }
        })
}

function Get-VMIntegrationServiceInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AllVMs
    )
    return [array]($AllVMs | ForEach-Object {
            $vmName = $_.Name
            Get-VMIntegrationService -VMName $vmName -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{
                    Vm            = [string]$vmName
                    Name          = [string]$_.Name
                    Enabled       = [bool]$_.Enabled
                    PrimaryStatus = [string]$_.PrimaryStatusDescription
                }
            }
        })
}

function Get-HostIPConfiguration {
    [CmdletBinding()]
    param()
    try {
        return [array](Get-NetIPConfiguration -Detailed -ErrorAction Stop | ForEach-Object {
                $cfg = $_
                [pscustomobject]@{
                    InterfaceAlias       = [string]$cfg.InterfaceAlias
                    InterfaceDescription = [string]$cfg.InterfaceDescription
                    IfIndex              = [int]$cfg.InterfaceIndex
                    IPv4Subnets          = @($cfg.IPv4Address | ForEach-Object {
                            [pscustomobject]@{
                                IPAddress    = [string]$_.IPAddress
                                PrefixLength = [int]$_.PrefixLength
                            }
                        })
                    IPv6Addresses        = @($cfg.IPv6Address | ForEach-Object { [string]$_.IPAddress })
                    DefaultGateway       = if ($cfg.IPv4DefaultGateway) { [string]$cfg.IPv4DefaultGateway.NextHop } else { '' }
                    DnsServers           = if ($cfg.DNSServer) { @($cfg.DNSServer | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ }) } else { @() }
                }
            })
    } catch {
        Write-Warning "Get-NetIPConfiguration failed: $_"
        return @()
    }
}

function Get-HyperVFindings {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [pscustomobject]$Summary,
        [AllowNull()][AllowEmptyCollection()]
        [object[]]$CpuNumaFindings,
        [AllowNull()][AllowEmptyCollection()]
        [object[]]$CheckpointFindings,
        [AllowNull()][AllowEmptyCollection()]
        [object[]]$ReplicationInfo,
        [AllowNull()][AllowEmptyCollection()]
        [object[]]$CsvData,
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$ReplicationCriticalStates,
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$ReplicationWarningStates
    )
    $findings = [System.Collections.Generic.List[pscustomobject]]::new()

    if ($Summary) {
        if ($Summary.OverprovisionedDisk) {
            $findings.Add([pscustomobject]@{ Category = 'Disk'; Severity = 'Critical'; Target = '(Host)'; Message = 'Total provisioned virtual disk space exceeds total physical capacity.' })
        }
        if ($Summary.OverprovisionedRAM) {
            $findings.Add([pscustomobject]@{ Category = 'RAM'; Severity = 'Critical'; Target = '(Host)'; Message = 'Total configured startup RAM exceeds total host memory; cannot cold-boot all VMs simultaneously.' })
        }
        if ($Summary.OverprovisionedCPU) {
            $findings.Add([pscustomobject]@{ Category = 'CPU'; Severity = 'Warning'; Target = '(Host)'; Message = "Total assigned vCPUs ($($Summary.TotalAssignedCPUs)) exceed total host logical cores ($($Summary.TotalHostCores))." })
        }
    }

    foreach ($f in @($CpuNumaFindings)) {
        $findings.Add([pscustomobject]@{ Category = 'CPU/NUMA'; Severity = [string]$f.Level; Target = [string]$f.Vm; Message = [string]$f.Message })
    }

    foreach ($f in @($CheckpointFindings)) {
        $findings.Add([pscustomobject]@{ Category = "Checkpoint/$($f.Category)"; Severity = [string]$f.Level; Target = [string]$f.Vm; Message = [string]$f.Message })
    }

    foreach ($r in @($ReplicationInfo)) {
        $isCritical = $r.Health -eq 'Critical' -or $r.State -in $ReplicationCriticalStates
        $isWarning = $r.Health -eq 'Warning' -or $r.State -in $ReplicationWarningStates
        if ($isCritical -or $isWarning) {
            $severity = if ($isCritical) { 'Critical' } else { 'Warning' }
            $findings.Add([pscustomobject]@{ Category = 'Replication'; Severity = $severity; Target = [string]$r.Vm; Message = "Health '$($r.Health)', State '$($r.State)'." })
        }
    }

    foreach ($v in @($CsvData)) {
        if ($v.RowColor -eq 'danger') {
            $findings.Add([pscustomobject]@{ Category = 'CSV'; Severity = 'Critical'; Target = [string]$v.Name; Message = "$($v.PercentFree)% free ($($v.FreeGB) GB of $($v.SizeGB) GB)." })
        } elseif ($v.RowColor -eq 'warning') {
            $findings.Add([pscustomobject]@{ Category = 'CSV'; Severity = 'Warning'; Target = [string]$v.Name; Message = "$($v.PercentFree)% free ($($v.FreeGB) GB of $($v.SizeGB) GB)." })
        }
    }

    return [array]$findings
}

function New-HyperVNetworkSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$HostAdapters,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$VirtualSwitches,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$NicTeams,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$HostIpConfig
    )
    $sections = [System.Collections.Generic.List[string]]::new()

    $nicRows = (@($HostAdapters) | ForEach-Object {
            $type = if ($_.IsVirtual) { 'Virtual' } else { 'Physical' }
            "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>$(ConvertTo-HtmlEncoded $_.InterfaceDescription)</td><td>$(ConvertTo-HtmlEncoded $_.MacAddress)</td><td>$(ConvertTo-HtmlEncoded $_.LinkSpeed)</td><td>$(ConvertTo-HtmlEncoded $_.Status)</td><td>$type</td></tr>"
        }) -join "`n"
    $sections.Add((New-HtmlTable -Title 'Host Network Adapters' -Icon 'fas fa-ethernet' `
                -Headers @('Name', 'Description', 'MAC', 'Link Speed', 'Status', 'Type') `
                -Rows $nicRows -EmptyMessage 'No host network adapters found.'))

    $ipRows = (@($HostIpConfig) | ForEach-Object {
            $subnetText = (@($_.IPv4Subnets) | ForEach-Object { "$(ConvertTo-HtmlEncoded $_.IPAddress)/$($_.PrefixLength)" }) -join '<br>'
            $dnsText = (@($_.DnsServers) -join ', ')
            "<tr><td>$(ConvertTo-HtmlEncoded $_.InterfaceAlias)</td><td>$subnetText</td><td>$(ConvertTo-HtmlEncoded $_.DefaultGateway)</td><td>$(ConvertTo-HtmlEncoded $dnsText)</td></tr>"
        }) -join "`n"
    $sections.Add((New-HtmlTable -Title 'Host IP Configuration' -Icon 'fas fa-network-wired' `
                -Headers @('Interface', 'IPv4 / Prefix', 'Gateway', 'DNS') `
                -Rows $ipRows -EmptyMessage 'No host IP configuration found.'))

    $swRows = (@($VirtualSwitches) | ForEach-Object {
            $uplink = if ($_.NetAdapterInterfaceDescription) { $_.NetAdapterInterfaceDescription } else { 'N/A (Internal/Private)' }
            $set = if ($_.EmbeddedTeamingEnabled) { 'Yes' } else { 'No' }
            $mgmt = if ($_.AllowManagementOS) { 'Yes' } else { 'No' }
            "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>$(ConvertTo-HtmlEncoded $_.SwitchType)</td><td>$(ConvertTo-HtmlEncoded $uplink)</td><td>$set</td><td>$mgmt</td></tr>"
        }) -join "`n"
    $sections.Add((New-HtmlTable -Title 'Virtual Switches' -Icon 'fas fa-diagram-project' `
                -Headers @('Name', 'Type', 'Uplink Adapter', 'SET', 'Mgmt OS') `
                -Rows $swRows -EmptyMessage 'No virtual switches found.'))

    $teamRows = (@($NicTeams) | ForEach-Object {
            $members = (@($_.Members) -join ', ')
            "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>$(ConvertTo-HtmlEncoded $_.TeamType)</td><td>$(ConvertTo-HtmlEncoded $_.TeamingMode)</td><td>$(ConvertTo-HtmlEncoded $_.LoadBalancing)</td><td>$(ConvertTo-HtmlEncoded $members)</td></tr>"
        }) -join "`n"
    $sections.Add((New-HtmlTable -Title 'NIC Teams' -Icon 'fas fa-layer-group' `
                -Headers @('Name', 'Type', 'Teaming Mode', 'Load Balancing', 'Members') `
                -Rows $teamRows -EmptyMessage 'No NIC teams configured.'))

    return ($sections -join "`n")
}

function New-HyperVResourceReportSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Parameter(Mandatory)]
        [pscustomobject]$Summary
    )
    $rows = (@(
            # RAM (Assigned - Live)
            $ramAssignedPct = if ($Summary.TotalHostMemoryGB -gt 0) {
                [math]::Round($Summary.TotalAssignedRAMGB / $Summary.TotalHostMemoryGB * 100, 1)
            } else {
                0
            }
            $ramAssignedBar = New-HtmlProgressBar `
                -Label "$([math]::Round($Summary.TotalAssignedRAMGB,2)) / $([math]::Round($Summary.TotalHostMemoryGB,2)) GB ($ramAssignedPct%)" `
                -Color (Get-ProgressBarColor -Percent $ramAssignedPct) `
                -Percent $ramAssignedPct
            "<tr><td>RAM (Assigned - Live)</td><td>$ramAssignedBar</td><td>$([math]::Round($Summary.TotalHostMemoryGB - $Summary.TotalAssignedRAMGB, 2)) GB free</td></tr>"
            # RAM (Startup - All VMs)
            $ramStartupPct = if ($Summary.TotalHostMemoryGB -gt 0) {
                [math]::Round($Summary.TotalStartupRAMGB / $Summary.TotalHostMemoryGB * 100, 1)
            } else {
                0
            }
            $ramStartupBar = New-HtmlProgressBar `
                -Label "$([math]::Round($Summary.TotalStartupRAMGB,2)) / $([math]::Round($Summary.TotalHostMemoryGB,2)) GB ($ramStartupPct%)" `
                -Color (Get-ProgressBarColor -Percent $ramStartupPct) `
                -Percent $ramStartupPct
            "<tr><td>RAM (Startup - All VMs)</td><td>$ramStartupBar</td><td>$([math]::Round($Summary.TotalHostMemoryGB - $Summary.TotalStartupRAMGB, 2)) GB free</td></tr>"
            # CPU (Assigned - Live)
            $cpuLivePct = if ($Summary.TotalHostCores -gt 0) {
                [math]::Round($Summary.TotalLiveCPUs / $Summary.TotalHostCores * 100, 1)
            } else {
                0
            }
            $cpuLiveBar = New-HtmlProgressBar `
                -Label "$($Summary.TotalLiveCPUs) / $($Summary.TotalHostCores) CPUs ($cpuLivePct%)" `
                -Color (Get-ProgressBarColor -Percent $cpuLivePct) `
                -Percent $cpuLivePct
            "<tr><td>CPU (Assigned - Live)</td><td>$cpuLiveBar</td><td>$($Summary.TotalHostCores - $Summary.TotalLiveCPUs) cores free</td></tr>"
            # CPU (All VMs)
            $cpuAllPct = if ($Summary.TotalHostCores -gt 0) {
                [math]::Round($Summary.TotalAssignedCPUs / $Summary.TotalHostCores * 100, 1)
            } else {
                0
            }
            $cpuAllBar = New-HtmlProgressBar `
                -Label "$($Summary.TotalAssignedCPUs) / $($Summary.TotalHostCores) CPUs ($cpuAllPct%)" `
                -Color (Get-ProgressBarColor -Percent $cpuAllPct) `
                -Percent $cpuAllPct
            "<tr><td>CPU (All VMs)</td><td>$cpuAllBar</td><td>$($Summary.TotalHostCores - $Summary.TotalAssignedCPUs) cores free</td></tr>"
        ) | Where-Object { $_ -match '^<tr' }) -join "`n"

    return New-HtmlTable -Title 'Resource Report' -Icon 'fas fa-gauge-high' `
        -Headers @('Resource', 'Allocation', 'Available Headroom') `
        -Rows $rows
}

function New-HyperVPhysicalDrivesSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$PhysicalDrives
    )
    # Hidden entirely when all VHDs are on CSVs (no local physical drives to report).
    if (-not $PhysicalDrives -or @($PhysicalDrives).Count -eq 0) {
        return ''
    }
    $rows = ($PhysicalDrives | ForEach-Object {
            $drivePct = [math]::Round($_.TotalCommittedVirtualGB / $_.PhysicalDriveCapacityGB * 100, 1)
            $driveBarColor = Get-AlertColor -Level $_.RowColor
            $provCommCell = New-HtmlProgressBar `
                -Label "$([math]::Round($_.TotalCommittedVirtualGB,2)) / $([math]::Round($_.TotalProvisionedVirtualGB,2)) GB ($drivePct%)" `
                -Color $driveBarColor `
                -Percent $drivePct
            "<tr class='$($_.RowColor)'><td>$(ConvertTo-HtmlEncoded $_.PhysicalDriveLetter)</td><td>$([math]::Round($_.PhysicalDriveCapacityGB,2)) GB</td><td>$provCommCell</td><td>$([math]::Round($_.NonVmFilesGB,2)) GB</td><td>$([math]::Round($_.HeadroomGB,2)) GB</td></tr>"
        }) -join "`n"

    return New-HtmlTable -Title 'Physical Drives' -Icon 'fas fa-hard-drive' `
        -Headers @('Drive', 'Capacity', 'Committed / Provisioned', 'Other Files', 'Free (GB)') `
        -Rows $rows
}

function New-HyperVCsvSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$CsvData,
        [Parameter(Mandatory)]
        [bool]$IsClustered
    )
    # Section is omitted entirely on non-clustered hosts.
    if (-not $IsClustered) {
        return ''
    }
    $rows = ($CsvData | ForEach-Object {
            $csvUsedPct = [math]::Round(100 - $_.PercentFree, 1)
            $csvBarColor = Get-AlertColor -Level $_.RowColor
            $csvUsageBar = New-HtmlProgressBar `
                -Label "$($_.UsedGB) / $($_.SizeGB) GB ($($_.PercentFree)% free)" `
                -Color $csvBarColor `
                -Percent $csvUsedPct
            "<tr class='$($_.RowColor)'><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>$(ConvertTo-HtmlEncoded $_.Path)</td><td>$(ConvertTo-HtmlEncoded $_.OwnerNode)</td><td>$($_.SizeGB)</td><td>$csvUsageBar</td><td>$($_.FreeGB) GB</td></tr>"
        }) -join "`n"

    return New-HtmlTable -Title 'Cluster Shared Volumes' -Icon 'fas fa-server' `
        -Headers @('CSV Name', 'Volume Path', 'Owner Node', 'Capacity (GB)', 'Used / Total', 'Free (GB)') `
        -Rows $rows `
        -EmptyMessage 'No Cluster Shared Volumes found.'
}

function New-HyperVCpuNumaSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$CpuNumaFindings,
        [Parameter(Mandatory)]
        [int]$NumaNodeCount,
        [Parameter(Mandatory)]
        [int]$LogicalCoresPerNuma
    )
    $rows = (@($CpuNumaFindings | Where-Object { $null -ne $_ }) | ForEach-Object {
            $rowClass = if ($_.Level -eq 'Warning') {
                " class='warning'"
            } else {
                ''
            }
            "<tr$rowClass><td>$(ConvertTo-HtmlEncoded $_.Vm)</td><td>$(ConvertTo-HtmlEncoded $_.Level)</td><td>$(ConvertTo-HtmlEncoded $_.Message)</td></tr>"
        }) -join "`n"

    return "<h3><i class='fas fa-microchip'></i>&nbsp;&nbsp;CPU / NUMA Configuration</h3>" +
    "<p>Host NUMA nodes: $NumaNodeCount &nbsp;|&nbsp; Logical CPUs per NUMA node: $LogicalCoresPerNuma</p>" +
    (New-HtmlTable -Headers @('VM', 'Severity', 'Finding') `
        -Rows $rows `
        -EmptyMessage 'No CPU/NUMA configuration concerns found.') +
    "<p><strong>Guidance: </strong><a href='https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn282282(v=ws.11)' target='_blank'>NUMA &amp; vCPU Sizing</a> &nbsp;|&nbsp; <a href='https://blog.workinghardinit.work/2016/06/21/the-hyper-v-processor-virtual-machine-reserve/' target='_blank'>CPU Reserve &amp; Maximum</a> &nbsp;|&nbsp; <a href='https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/configure-processor-compatibility-mode' target='_blank'>Processor Compatibility Mode</a> &nbsp;|&nbsp; <a href='https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-minroot-2016' target='_blank'>Host Resource Protection</a></p>"
}

function New-HyperVCheckpointSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$CheckpointFindings
    )
    $rows = ($CheckpointFindings | ForEach-Object {
            $rowClass = if ($_.Level -eq 'Critical') {
                " class='danger'"
            } elseif ($_.Level -eq 'Warning') {
                " class='warning'"
            } else {
                ''
            }
            "<tr$rowClass><td>$(ConvertTo-HtmlEncoded $_.Vm)</td><td>$(ConvertTo-HtmlEncoded $_.Level)</td><td>$(ConvertTo-HtmlEncoded $_.Category)</td><td>$(ConvertTo-HtmlEncoded $_.Message)</td></tr>"
        }) -join "`n"

    return New-HtmlTable -Title 'Checkpoint Health' -Icon 'fas fa-camera' `
        -Headers @('VM', 'Severity', 'Category', 'Finding') `
        -Rows $rows `
        -EmptyMessage 'No checkpoint concerns found.'
}

function New-HyperVReplicationSectionHtml {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$ReplicationInfo,
        [AllowNull()][AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$UnreplicatedVms
    )
    $replNow = Get-Date
    $sortedRepl = @($ReplicationInfo | Sort-Object {
            switch ($_.Health) {
                'Critical' {
                    0
                } 'Warning' {
                    1
                } default {
                    2
                }
            }
        }, {
            if ($_.LastReplicationTime) {
                $_.LastReplicationTime
            } else {
                [datetime]::MinValue
            }
        })

    # Only render rows when replication is configured; otherwise the table is omitted entirely,
    # preserving prior behaviour (unreplicated VMs are not listed on a host with no Replica config).
    $replRows = if ($ReplicationInfo) {
        @(
            $sortedRepl | ForEach-Object {
                $rowClass = switch ($_.Health) {
                    'Critical' {
                        'danger'
                    } 'Warning' {
                        'warning'
                    } default {
                        'success'
                    }
                }
                $lastReplAge = if ($_.LastReplicationTime) {
                    $span = $replNow - $_.LastReplicationTime
                    if ($span.TotalDays -ge 1) {
                        "$([math]::Round($span.TotalDays, 1)) days ago"
                    } elseif ($span.TotalHours -ge 1) {
                        "$([math]::Round($span.TotalHours, 1)) hrs ago"
                    } else {
                        "$([math]::Round($span.TotalMinutes, 0)) min ago"
                    }
                } else {
                    'Never'
                }
                $freqLabel = switch ($_.FrequencyOfReplicationSec) {
                    30 {
                        '30 sec'
                    } 300 {
                        '5 min'
                    } 900 {
                        '15 min'
                    } default {
                        "$($_.FrequencyOfReplicationSec) sec"
                    }
                }
                "<tr class='$rowClass'><td>$(ConvertTo-HtmlEncoded $_.Vm)</td><td>$(ConvertTo-HtmlEncoded $_.Health)</td><td>$(ConvertTo-HtmlEncoded $_.State)</td><td>$(ConvertTo-HtmlEncoded $_.ReplicationMode)</td><td>$freqLabel</td><td>$(ConvertTo-HtmlEncoded $lastReplAge)</td><td>$(ConvertTo-HtmlEncoded $_.ReplicationRelationshipType)</td><td>$(ConvertTo-HtmlEncoded $_.PrimaryServer)</td><td>$(ConvertTo-HtmlEncoded $_.ReplicaServer)</td></tr>"
            }
            $UnreplicatedVms | ForEach-Object {
                "<tr><td>$(ConvertTo-HtmlEncoded $_.Name)</td><td>Not configured</td><td>N/A</td><td>N/A</td><td>N/A</td><td>N/A</td><td>N/A</td><td>N/A</td><td>N/A</td></tr>"
            }
        ) -join "`n"
    } else {
        $null
    }

    return New-HtmlTable -Title 'Replication Health' -Icon 'fas fa-copy' `
        -Headers @('VM Name', 'Health', 'State', 'Mode', 'Frequency', 'Last Replicated', 'Relationship', 'Primary Server', 'Replica Server') `
        -Rows $replRows
}

#endregion Helper Functions

#region Guard Checks

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Warning 'Not running on a Hyper-V host. Exiting.'
    exit 0
}

$allVMs = Get-VM
if (-not $allVMs) {
    Write-Warning 'No VMs found on this host. Exiting.'
    exit 0
}

if (-not (Test-IsSystem)) {
    Write-Error -Message 'Access Denied. Please run as SYSTEM'
    exit 1
}

#endregion Guard Checks

#region Script Variables (NinjaOne script variables override these defaults)

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

# Operation mode: set to $false when running as a Condition to skip HTML generation and field writes
$writeHtmlReport = Get-EnvWithDefault -Name 'writeHtmlReport' -Default $true -Type ([bool])

# Operation mode: set to $false when running as a Condition to skip JSON generation and field writes
$writeJsonReport = Get-EnvWithDefault -Name 'writeJsonReport' -Default $true -Type ([bool])

#endregion Script Variables

#region Data Collection

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
# Strip stray nulls: Get-VMReplication yields nothing on an unconfigured host, which @() turns
# into a single-element null array (renders as [null] in JSON and a blank HTML replication row).
$replicationInfo = @($replicationInfo | Where-Object { $null -ne $_ })
$replicatedVmNames = @($replicationInfo | Select-Object -ExpandProperty Vm -Unique)
$unreplicatedVms = @($allVMs | Where-Object { $replicatedVmNames -notcontains $_.Name })

$replicationCriticalStates = @('Paused', 'Suspended', 'Error', 'FailedOver', 'FailOverWaitingCompletion')
$replicationWarningStates = @('ResynchronizationRequired', 'ReadyForInitialReplication')
$checkpointFindings = @(Get-CheckpointFindings -AllVMs $allVMs `
        -WarnAgeDays $checkpointWarnAgeDays -CritAgeDays $checkpointCritAgeDays `
        -WarnSizeGB $checkpointWarnSizeGB -CritSizeGB $checkpointCritSizeGB `
        -WarnChainDepth $checkpointWarnChainDepth -CritChainDepth $checkpointCritChainDepth)

# Raw checkpoint inventory for the JSON report (report-only — does not affect exit code)
$checkpointInventory = try {
    @(Get-CheckpointInventory -AllVMs $allVMs)
} catch {
    Write-Warning "Failed to collect checkpoint inventory: $_"
    @()
}

# Networking (report-only — does not affect exit code)
$hostNics = Get-HostNetworkAdapterInfo
$vSwitches = Get-VirtualSwitchInfo
$nicTeams = Get-NicTeamInfo
$vmNics = Get-VMNetworkAdapterInfo -AllVMs $allVMs
$vmIntegrationServices = Get-VMIntegrationServiceInfo -AllVMs $allVMs
$hostIpConfig = Get-HostIPConfiguration

# Unified findings list for the JSON report (additive — exit-code logic below is unchanged)
$findings = Get-HyperVFindings -Summary $summary -CpuNumaFindings $cpuNumaFindings `
    -CheckpointFindings $checkpointFindings -ReplicationInfo $replicationInfo -CsvData $csvData `
    -ReplicationCriticalStates $replicationCriticalStates -ReplicationWarningStates $replicationWarningStates

#endregion Data Collection

#region Report Generation

if ($writeHtmlReport) {
    $reportBody = (@(
            New-HyperVWarningsSectionHtml -Summary $summary -ReplicationInfo $replicationInfo `
                -CpuNumaFindings $cpuNumaFindings -CheckpointFindings $checkpointFindings `
                -CsvData $csvData -CsvCritThresholdPct $csvCritThresholdPct `
                -CsvWarnThresholdPct $csvWarnThresholdPct `
                -ReplicationCriticalStates $replicationCriticalStates `
                -ReplicationWarningStates $replicationWarningStates

            New-HyperVResourceReportSectionHtml -Summary $summary

            New-HyperVPhysicalDrivesSectionHtml -PhysicalDrives $physicalDrives

            New-HyperVCsvSectionHtml -CsvData $csvData -IsClustered $isClustered

            New-HyperVVmDetailsSectionHtml -AllVMs $allVMs -AllVirtualDisks $allVirtualDisks `
                -AllVmNics $vmNics -AllVmIntegrationServices $vmIntegrationServices `
                -ReplicationInfo $replicationInfo `
                -LogicalCoresPerNuma $logicalCoresPerNuma

            New-HyperVNetworkSectionHtml -HostAdapters $hostNics -VirtualSwitches $vSwitches `
                -NicTeams $nicTeams -HostIpConfig $hostIpConfig

            New-HyperVCpuNumaSectionHtml -CpuNumaFindings $cpuNumaFindings `
                -NumaNodeCount $numaNodeCount -LogicalCoresPerNuma $logicalCoresPerNuma

            New-HyperVReplicationSectionHtml -ReplicationInfo $replicationInfo -UnreplicatedVms $unreplicatedVms

            New-HyperVCheckpointSectionHtml -CheckpointFindings $checkpointFindings
        ) | Where-Object { $_ }) -join "`n"

    $summaryReportHTML = Get-NinjaOneCard -Title 'Hyper-V Health' -Body $reportBody -Icon 'fas fa-hard-drive'
    try {
        $summaryReportHTML | Ninja-Property-Set-Piped -Name hypervHealth
    } catch {
        Write-Warning "Failed to set NinjaOne field: $_"
    }
} # end if ($writeHtmlReport) — report generation

#endregion Report Generation

#region Alerting & Exit Evaluation

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
    [pscustomobject]@{
        Flag      = $alertOnReplicationCritical
        Condition = (@($replicationInfo | Where-Object {
                    $_.Health -eq 'Critical' -or
                    $_.State -in $replicationCriticalStates
                }).Count -gt 0)
        Level     = 2
    }
    [pscustomobject]@{
        Flag      = $alertOnReplicationWarning
        Condition = (@($replicationInfo | Where-Object {
                    $_.Health -eq 'Warning' -or
                    $_.State -in $replicationWarningStates
                }).Count -gt 0)
        Level     = 1
    }
    [pscustomobject]@{ Flag = $alertOnCheckpointCritical; Condition = (@($checkpointFindings | Where-Object { $_.Level -eq 'Critical' }).Count -gt 0); Level = 2 }
    [pscustomobject]@{ Flag = $alertOnCheckpointWarning; Condition = (@($checkpointFindings | Where-Object { $_.Level -eq 'Warning' }).Count -gt 0); Level = 1 }
    [pscustomobject]@{ Flag = $alertOnCSVCritical; Condition = ($csvCriticalVolumes.Count -gt 0); Level = 2 }
    [pscustomobject]@{ Flag = $alertOnCSVWarning; Condition = ($csvWarningVolumes.Count -gt 0); Level = 1 }
)
$exitLevel = 0
foreach ($check in $exitChecks) {
    if ($check.Flag -and $check.Condition) {
        $exitLevel = [math]::Max($exitLevel, $check.Level)
    }
}

$criticalReplicationStateMatches = @($replicationInfo | Where-Object { $_.State -in $replicationCriticalStates })
$warningReplicationStateMatches = @($replicationInfo | Where-Object { $_.State -in $replicationWarningStates })

foreach ($r in $criticalReplicationStateMatches) {
    Write-Warning "Replication critical state: VM '$($r.Vm)' State '$($r.State)' Health '$($r.Health)' Mode '$($r.ReplicationMode)'"
}

foreach ($r in $warningReplicationStateMatches) {
    Write-Warning "Replication warning state: VM '$($r.Vm)' State '$($r.State)' Health '$($r.Health)' Mode '$($r.ReplicationMode)'"
}

#endregion Alerting & Exit Evaluation

#region JSON Report
# Emits all collected data plus the unified findings list as compact JSON to the MultiLine field
# 'hypervHealthData' for retrieval/parsing via the NinjaOne API.
if ($writeJsonReport) {
    $disksByVmJson = @{}
    foreach ($d in $allVirtualDisks) {
        $disksByVmJson[$d.Vm] += @($d)
    }
    $nicsByVmJson = @{}
    foreach ($n in $vmNics) {
        $nicsByVmJson[$n.Vm] += @($n)
    }
    $integByVmJson = @{}
    foreach ($s in $vmIntegrationServices) {
        $integByVmJson[$s.Vm] += @($s)
    }

    $vmObjects = @($allVMs | ForEach-Object {
            $vm = $_
            $uptimeSeconds = if ($vm.State -eq 'Running' -and $vm.Uptime) { [int]$vm.Uptime.TotalSeconds } else { 0 }
            [pscustomobject]@{
                name                       = [string]$vm.Name
                vmId                       = [string]$vm.VMId.Guid
                state                      = [string]$vm.State
                assignedCPUs               = [int]$vm.ProcessorCount
                assignedRAMBytes           = [long]$vm.MemoryAssigned
                startupRAMBytes            = [long]$vm.MemoryStartup
                minimumRAMBytes            = if ($vm.DynamicMemoryEnabled) { [long]$vm.MemoryMinimum } else { [long]0 }
                maximumRAMBytes            = if ($vm.DynamicMemoryEnabled) { [long]$vm.MemoryMaximum } else { [long]0 }
                assignedRAMGB              = [math]::Round($vm.MemoryAssigned / 1GB, 2)
                startupRAMGB               = [math]::Round($vm.MemoryStartup / 1GB, 2)
                dynamicMemoryEnabled       = [bool]$vm.DynamicMemoryEnabled
                automaticStartAction       = [string]$vm.AutomaticStartAction
                automaticStartDelay        = [int]$vm.AutomaticStartDelay
                generation                 = [int]$vm.Generation
                configurationVersion       = [string]$vm.Version
                uptime                     = [string]$vm.Uptime
                uptimeSeconds              = $uptimeSeconds
                integrationServicesState   = [string]$vm.IntegrationServicesState
                integrationServicesVersion = [string]$vm.IntegrationServicesVersion
                # Null-filter so a VM with no disks/NICs emits [] rather than [null] (stable schema).
                disks                      = @($disksByVmJson[$vm.Name] | Where-Object { $null -ne $_ })
                networkAdapters            = @($nicsByVmJson[$vm.Name] | Where-Object { $null -ne $_ })
                integrationServices        = @($integByVmJson[$vm.Name] | Where-Object { $null -ne $_ })
            }
        })

    $reportObject = [ordered]@{
        schemaVersion        = '1.1'
        generatedAt          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        hostName             = $env:COMPUTERNAME
        exitLevel            = $exitLevel
        host                 = [ordered]@{
            totalMemoryBytes    = [long]($totalHostMemory * 1GB)
            totalMemoryGB       = [math]::Round($totalHostMemory, 2)
            totalLogicalCores   = $totalHostCores
            numaNodeCount       = $numaNodeCount
            logicalCoresPerNuma = $logicalCoresPerNuma
            isClustered         = $isClustered
        }
        summary              = $summary
        physicalDrives       = @($physicalDrives)
        clusterSharedVolumes = @($csvData)
        virtualMachines      = $vmObjects
        memory               = @($allMemory)
        cpu                  = @($allCpu)
        replication          = @($replicationInfo)
        unreplicatedVMs      = @($unreplicatedVms | ForEach-Object { $_.Name })
        checkpoints          = @($checkpointFindings)
        checkpointInventory  = @($checkpointInventory)
        cpuNumaFindings      = @($cpuNumaFindings)
        network              = [ordered]@{
            hostAdapters      = @($hostNics)
            virtualSwitches   = @($vSwitches)
            nicTeams          = @($nicTeams)
            vmNetworkAdapters = @($vmNics)
            hostIpConfig      = @($hostIpConfig)
        }
        findings             = @($findings)
    }

    $jsonOutput = $reportObject | ConvertTo-Json -Depth 12 -Compress
    try {
        $jsonOutput | Ninja-Property-Set-Piped -Name hypervHealthData
    } catch {
        Write-Warning "Failed to set NinjaOne field 'hypervHealthData': $_"
    }
}

#endregion JSON Report

exit $exitLevel
