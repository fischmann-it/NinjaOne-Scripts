<#
.SYNOPSIS
    Reports OneDrive / SharePoint sync status and Known Folder Move redirection for every
    signed-in OneDrive account (work and personal) and writes the results to NinjaOne custom fields.

.DESCRIPTION
    Runs as SYSTEM and uses the RunAsUser module to collect data in the context of the
    logged-in user. Enumerates every configured OneDrive account (Business1, Business2, ...,
    and Personal), determines per-account sync health from the SyncDiagnostics logs,
    detects Desktop/Documents/Pictures/Downloads redirection, and inventories synced
    SharePoint libraries (size and item count).

.NOTES
    Required NinjaOne custom fields:
    - onedriveSyncClient (WYSIWYG)         : Combined config + synced libraries card.
    - onedriveSyncHealth (Text/Multi-line) : Per-account sync health summary for alerting.
      Set both to Automation = Read/Write, Technician = Read.

    Run as: SYSTEM (with a user logged in). Shared machines / terminal servers are not targeted.
#>
$executionpolicy = Get-ExecutionPolicy
if ($executionpolicy -eq 'Restricted') {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force
}
function Get-NinjaOneCard($Title, $Body, [string]$Icon, [string]$TitleLink, [String]$Classes) {
    <#
    $Info = 'This is the body of a card it is wrapped in a paragraph'

    Get-NinjaOneCard -Title "Tenant Details" -Data $Info
    #>

    [System.Collections.Generic.List[String]]$OutputHTML = @()

    $OutputHTML.add('<div class="card flex-grow-1' + $(if ($classes) {
                ' ' + $classes 
            }) + '" >')

    if ($Title) {
        $OutputHTML.add('<div class="card-title-box"><div class="card-title" >' + $(if ($Icon) {
                    '<i class="' + $Icon + '"></i>&nbsp;&nbsp;' 
                }) + $Title + '</div>')

        if ($TitleLink) {
            $OutputHTML.add('<div class="card-link-box"><a href="' + $TitleLink + '" target="_blank" class="card-link" ><i class="fas fa-arrow-up-right-from-square" style="color: #337ab7;"></i></a></div>')
        }

        $OutputHTML.add('</div>')
    }

    $OutputHTML.add('<div class="card-body" >')
    $OutputHTML.add('<p class="card-text" >' + $Body + '</p>')
       
    $OutputHTML.add('</div></div>')

    return $OutputHTML -join ''
    
}

try {

    if (Get-Command invoke-ascurrentuser -ErrorAction SilentlyContinue) {
        Write-Host 'RunAsUser Module Present'
    } else {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
        Install-Module -Name RunAsUser -Confirm:$false -Force -ErrorAction Stop
    }
    $ScriptBlock = {
        function Convert-ResultCodeToName {
            # Evaluates OneDrive SyncProgressState codes and converts to human-readable text
            param([Parameter(Mandatory = $true)]
                [int] $Status
            )
            switch ($Status) {
                0 { $retVal = 'Up-to-Date' }
                4 { $retVal = 'Syncing' }
                10 { $retVal = 'File merge conflict' }
                42 { $retVal = 'Up-to-Date' }
                256 { $retVal = 'File locked' }
                258 { $retVal = 'File merge conflict' }
                1854 { $retVal = 'Having syncing problems' }
                8194 { $retVal = 'Not syncing' }
                8449 { $retVal = 'File locked' }
                8456 { $retVal = "You don't have permission to sync this library" }
                12290 { $retVal = 'Access Permission' }
                12544 { $retVal = 'Up-to-Date' }
                16777216 { $retVal = 'Up-to-Date' }
                65536 { $retVal = 'Paused' }
                32786 { $retVal = 'File merge conflict' }
                4106 { $retVal = 'File merge conflict' }
                20480 { $retVal = 'File merge conflict' }
                24576 { $retVal = 'File merge conflict' }
                25088 { $retVal = 'File merge conflict' }
                default { $retVal = "Unknown: $Status" }
            }
            return $retVal
        }

        function Get-UserFolderRedirection {
            # Known Folder Move redirection is user-level, so it is evaluated once per user
            $UserFolders = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders\' -ErrorAction SilentlyContinue
            $downloadsGuid = '{374DE290-123F-4565-9164-39C4925E467B}'
            $downloadsPath = $UserFolders.$downloadsGuid

            return [pscustomobject]@{
                DesktopRedirected   = [bool]($UserFolders.Desktop -match 'OneDrive')
                DocumentsRedirected = [bool]($UserFolders.Personal -match 'OneDrive')
                PicturesRedirected  = [bool]($UserFolders.'My Pictures' -match 'OneDrive')
                DownloadsRedirected = [bool]($downloadsPath -match 'OneDrive')
                DesktopPath         = $UserFolders.Desktop
                DocumentsPath       = $UserFolders.Personal
                PicturesPath        = $UserFolders.'My Pictures'
                DownloadsPath       = $downloadsPath
                MusicPath           = $UserFolders.'My Music'
                VideosPath          = $UserFolders.'My Video'
                FavoritesPath       = $UserFolders.Favorites
            }
        }

        function Get-OneDriveAccountHealth {
            param(
                [Parameter(Mandatory = $true)][string]$AccountName,
                [string]$Email,
                [string]$DisplayName,
                [bool]$ProcessRunning
            )
            $warningFileSyncedDelayHours = 72
            # Just the UTC offset portion, e.g. '(UTC-06:00)'
            $timezone = [System.TimeZoneInfo]::Local.DisplayName -replace '^(\(UTC[^)]*\)).*', '$1'

            $folderMask = "$env:localAppData\Microsoft\OneDrive\logs\$AccountName\*.log"
            $files = Get-ChildItem -Path $folderMask -Filter SyncDiagnostics.log -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt [datetime]::Now.AddMinutes(-1440) }

            $syncHealth = 'Unknown'
            $convertLogDate = $null

            if (-not $files) {
                $syncHealth = 'No recent sync log found'
            } else {
                $logContent = Get-Content $files
                $progressState = $logContent | Where-Object { $_.Contains('SyncProgressState') }
                $checkLogDate = $logContent | Where-Object { $_.Contains('UtcNow:') }

                # Parse the SyncProgressState code (take the most recent line if several)
                $statusCode = ($progressState | ForEach-Object { (-split $_)[1] } | Select-Object -Last 1) -as [int]
                $resultText = Convert-ResultCodeToName $statusCode

                $rawLogDate = $checkLogDate | ForEach-Object { (-split $_)[1] } | Select-Object -Last 1
                $convertLogDate = $rawLogDate -as [DateTime]

                $difference = $null
                if ($convertLogDate) {
                    $difference = (New-TimeSpan -Start $convertLogDate.ToUniversalTime() -End (Get-Date).ToUniversalTime()).TotalHours
                }

                try {
                    if (-not $ProcessRunning) {
                        # OneDrive.exe is not running, so the log status may be stale
                        $syncHealth = 'OneDrive Not Running'
                    } elseif ($null -eq $statusCode) {
                        # No parsable status code -> genuinely not syncing / not signed in
                        $syncHealth = 'OneDrive Not Syncing or Signed In'
                    } elseif ($difference -gt $warningFileSyncedDelayHours) {
                        # Signed in with a known status, but no files synced recently
                        $syncHealth = "$resultText (no files synced in $([math]::Round($difference)) hours)"
                    } else {
                        # Surface the interpreted status as-is, including error states
                        $syncHealth = $resultText
                    }
                } catch {
                    $syncHealth = "Error: $($_.Exception.Message)"
                }
            }

            return [pscustomobject]@{
                Account     = $AccountName
                DisplayName = $DisplayName
                Email       = $Email
                SyncHealth  = $syncHealth
                LastSynced  = if ($convertLogDate) { "$convertLogDate $timezone" } else { 'Never' }
            }
        }

        # OneDrive.exe runs once for all accounts; used to catch a stale 'Up-to-Date' status
        $oneDriveRunning = [bool](Get-Process -Name OneDrive -ErrorAction SilentlyContinue)

        # Enumerate every configured OneDrive account (Business1, Business2, ..., and Personal)
        $accountKeys = Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^(Business\d+|Personal)$' }

        $accounts = foreach ($accountKey in $accountKeys) {
            $accountProps = Get-ItemProperty -Path $accountKey.PSPath -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Account     = $accountKey.PSChildName
                Email       = $accountProps.UserEmail
                DisplayName = if ($accountProps.DisplayName) { $accountProps.DisplayName } else { $accountProps.UserName }
            }
        }
        # Drop stale/empty account keys that have no signed-in user (no email or name)
        $accounts = @($accounts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Email) -or -not [string]::IsNullOrWhiteSpace($_.DisplayName) })

        $accountHealth = foreach ($account in $accounts) {
            Get-OneDriveAccountHealth -AccountName $account.Account -Email $account.Email -DisplayName $account.DisplayName -ProcessRunning $oneDriveRunning
        }

        $status = [pscustomobject]@{
            Computer          = $env:COMPUTERNAME
            User              = whoami
            OneDriveRunning   = $oneDriveRunning
            Accounts          = @($accountHealth)
            FolderRedirection = Get-UserFolderRedirection
        }
        $status | ConvertTo-Json -Depth 5 | Out-File 'C:\temp\OneDriveStatus.json'

        # Synced SharePoint/OneDrive libraries across all accounts
        $OneDriveProviders = Get-ChildItem -Path 'HKCU:\Software\SyncEngines\Providers\OneDrive' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath }
        $LatestProviders = $OneDriveProviders | Group-Object -Property MountPoint | ForEach-Object {
            $_.Group | Sort-Object -Property LastModifiedTime -Descending | Select-Object -First 1
        }
        $AllMountPoints = $LatestProviders.MountPoint

        $settingsFolders = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\settings" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Business\d+$' }

        $SyncedLibraries = foreach ($settingsFolder in $settingsFolders) {
            $accountName = $settingsFolder.Name
            $accountEmail = ($accounts | Where-Object { $_.Account -eq $accountName }).Email
            $IniFiles = Get-ChildItem $settingsFolder.FullName -Filter 'ClientPolicy*' -ErrorAction SilentlyContinue

            foreach ($inifile in $IniFiles) {
                $IniContent = Get-Content $inifile.FullName -Encoding Unicode
                $ItemCount = ($IniContent | Where-Object { $_ -like 'ItemCount*' }) -split '= ' | Select-Object -Last 1
                $URL = ($IniContent | Where-Object { $_ -like 'DavUrlNamespace*' }) -split '= ' | Select-Object -Last 1
                $Mountpoint = ($LatestProviders | Where-Object { $_.UrlNamespace -eq $URL }).MountPoint

                $diskUsage = $null
                if ($Mountpoint -and (Test-Path -LiteralPath $Mountpoint -ErrorAction SilentlyContinue)) {
                    # Normalize the mount points for comparison
                    $root = ((Resolve-Path -LiteralPath $Mountpoint).Path.TrimEnd('\')) + '\'
                    $excludeRoots = foreach ($mp in $AllMountPoints) {
                        $resolved = Resolve-Path -LiteralPath $mp -ErrorAction SilentlyContinue
                        if ($resolved) {
                            $normalized = $resolved.Path.TrimEnd('\') + '\'
                            if ($normalized -ne $root) { $normalized }
                        }
                    }

                    # Get all non-sparse, non-reparse files under the mount point
                    $items = Get-ChildItem -LiteralPath $root -Attributes !SparseFile, !ReparsePoint -Recurse -File -ErrorAction SilentlyContinue
                    $FilteredItems = $items.Where({
                            # Exclude files that live under another (nested shortcut) mount point
                            $path = $_.FullName
                            foreach ($exclude in $excludeRoots) {
                                if ($path.StartsWith($exclude, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                            }
                            $true
                        })
                    $diskUsage = $([math]::Truncate((($FilteredItems | Measure-Object -Property Length -Sum).Sum / 1GB * 100)) / 100)
                }
                [PSCustomObject]@{
                    'Account'         = $accountEmail
                    'Site Name'       = ($IniContent | Where-Object { $_ -like 'SiteTitle*' }) -split '= ' | Select-Object -Last 1
                    'Site URL'        = $URL
                    'Local Disk Used' = if ($diskUsage) {
                        "$diskUsage GB"
                    } elseif ($diskUsage -eq 0) {
                        '< 10 MB'
                    } else {
                        'Err'
                    }
                    'Item Count'      = $ItemCount
                }
            }
        }
        @($SyncedLibraries) | ConvertTo-Json -Depth 5 | Out-File 'C:\temp\OneDriveLibraries.json'
    }

    New-Item -ItemType Directory -Path 'C:\temp' -ErrorAction SilentlyContinue
    $statusFile = 'C:\temp\OneDriveStatus.json'
    $librariesFile = 'C:\temp\OneDriveLibraries.json'

    # Clear stale output from a previous run so we never report old data
    Remove-Item -Path $statusFile, $librariesFile -Force -ErrorAction SilentlyContinue
    $null = Invoke-AsCurrentUser -ScriptBlock $ScriptBlock -ErrorAction Stop

    if (-not (Test-Path $statusFile)) {
        Write-Host 'OneDrive status file not found. No user may be logged in, or data collection was blocked.'
    } else {
        $status = Get-Content $statusFile -Raw | ConvertFrom-Json
        $accounts = @($status.Accounts)
        $folderRedirection = $status.FolderRedirection
        $SyncedLibraries = if (Test-Path $librariesFile) {
            @(Get-Content $librariesFile -Raw | ConvertFrom-Json)
        } else {
            @()
        }

        $totalItemCount = ($SyncedLibraries.'Item Count' | ForEach-Object { $_ -as [int] } | Measure-Object -Sum).Sum
        if ($totalItemCount -gt 280000) {
            Write-Host 'Unhealthy - Currently syncing more than 280k files. Please investigate.'
        } elseif (-not $SyncedLibraries) {
            Write-Host 'No SharePoint Libraries found.'
        } else {
            Write-Host 'Healthy - Syncing less than 280k files, or none.'
        }

        # Output for the NinjaOne activity log
        $accounts | Format-Table -AutoSize | Out-String | Write-Host
        $SyncedLibraries | Format-Table -AutoSize | Out-String | Write-Host

        # Per-account concatenated summary for alerting on a separate plain-text field
        if ($accounts) {
            $syncHealthSummary = ($accounts | ForEach-Object { "$($_.Email): $($_.SyncHealth)" }) -join ' | '
        } else {
            $syncHealthSummary = 'No OneDrive accounts detected'
        }
        $syncHealthSummary | Ninja-Property-Set-Piped -Name onedriveSyncHealth

        # Build the combined config card: per-account health bullets + folder redirection details
        if ($accounts) {
            [System.Collections.Generic.List[String]]$accountItemsHTML = @()
            foreach ($account in $accounts) {
                # Briefcase for work (Business) accounts, house for Personal accounts
                $accountIcon = if ($account.Account -eq 'Personal') { '&#127968;' } else { '&#128188;' }
                $accountLabel = if ($account.DisplayName) { $account.DisplayName } else { $account.Account }
                $emailPart = if ($account.Email) { ' | ' + $account.Email } else { '' }
                $accountItemsHTML.Add(
                    '<p ><b>' + $accountIcon + ' ' + $accountLabel + '</b>' + $emailPart + '</p>' +
                    '<ul><li>Status: ' + $account.SyncHealth + '</li><li>Last synced: ' + $account.LastSynced + '</li></ul>'
                )
            }
            $accountsTableHTML = ($accountItemsHTML -join '')
        } else {
            $accountsTableHTML = '<p>No OneDrive accounts detected.</p>'
        }

        $folderRedirectionMap = [ordered]@{
            'Desktop'   = @{ Redirected = $folderRedirection.DesktopRedirected; Path = $folderRedirection.DesktopPath }
            'Documents' = @{ Redirected = $folderRedirection.DocumentsRedirected; Path = $folderRedirection.DocumentsPath }
            'Pictures'  = @{ Redirected = $folderRedirection.PicturesRedirected; Path = $folderRedirection.PicturesPath }
            'Downloads' = @{ Redirected = $folderRedirection.DownloadsRedirected; Path = $folderRedirection.DownloadsPath }
        }
        [System.Collections.Generic.List[String]]$folderRedirectionHTML = @()
        foreach ($folder in $folderRedirectionMap.Keys) {
            $entry = $folderRedirectionMap[$folder]
            $folderRedirectionHTML.Add('<p ><b >' + $folder + ' Redirected</b><br />' + $entry.Redirected + ' - ' + $entry.Path + '</p>')
        }

        $configBody = $accountsTableHTML + '<hr />' + ($folderRedirectionHTML -join '')
        $ODHTML = (Get-NinjaOneCard -Title 'OneDrive Config Details' -Body $configBody -Icon 'fas fa-cloud" style="color:#0364b8;') -replace 'True', '<i class="fas fa-check-circle" style="color:#26A644;"></i>&nbsp;&nbsp;True'

        if ($SyncedLibraries) {
            $LibraryTableHTML = $SyncedLibraries | ConvertTo-Html -As Table -Fragment
            $LibraryHTML = Get-NinjaOneCard -Title 'Synced Libraries' -Body $LibraryTableHTML -Icon 'fas fa-cloud" style="color:#0364b8;'
        }
        $CombinedHTML = '<div class="row g-1 rows-cols-2">' +
        '<div class="col-xl-4 col-lg-4 col-md-4 col-sm-4 d-flex">' + $ODHTML +
        '</div><div class="col-xl-8 col-lg-8 col-md-8 col-sm-8 d-flex">' + $LibraryHTML +
        '</div></div>'
        $CombinedHTML | Ninja-Property-Set-Piped -Name onedriveSyncClient
    }

} catch {
    Write-Host "Could not execute `n`n$($_.Exception.Message)"
}

if ($executionpolicy -eq 'Restricted') {
    Set-ExecutionPolicy -ExecutionPolicy $executionpolicy -Force
}
