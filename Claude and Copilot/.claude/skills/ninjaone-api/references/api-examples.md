# NinjaOne API Examples

## Advanced Pagination Pattern

```powershell
function Get-AllNinjaDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [int]$PageSize = 100
    )

    $allResults = [System.Collections.ArrayList]::new()
    $cursor = $null

    do {
        $url = "$BaseUrl/devices?pageSize=$PageSize"
        if ($cursor) {
            $url += "&after=$cursor"
        }

        try {
            $response = Invoke-RestMethod -Uri $url -Headers $Headers

            if ($response -is [array]) {
                $allResults.AddRange($response)
            } else {
                [void]$allResults.Add($response)
            }

            # Extract next cursor
            $cursor = $null
            if ($response.PSObject.Properties['next']) {
                $nextUrl = $response.next
                if ($nextUrl -match 'after=([^&]+)') {
                    $cursor = $matches[1]
                }
            }
        } catch {
            Write-Error "Failed to retrieve devices: $_"
            throw
        }
    } while ($cursor)

    return $allResults.ToArray()
}
```

## Bulk Operations with Progress

```powershell
function Update-NinjaDeviceCustomFields {
    param(
        [Parameter(Mandatory)]
        [array]$DeviceIds,

        [Parameter(Mandatory)]
        [hashtable]$FieldUpdates,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $total = $DeviceIds.Count
    $current = 0
    $results = @{
        Success = @()
        Failed = @()
    }

    foreach ($deviceId in $DeviceIds) {
        $current++
        Write-Progress -Activity "Updating Devices" `
            -Status "Processing $current of $total" `
            -PercentComplete (($current / $total) * 100)

        try {
            $body = $FieldUpdates.GetEnumerator() | ForEach-Object {
                @{ name = $_.Key; value = $_.Value }
            }

            Invoke-RestMethod `
                -Uri "$BaseUrl/device/$deviceId/custom-fields" `
                -Headers $Headers `
                -Method Patch `
                -Body ($body | ConvertTo-Json) `
                -ContentType "application/json"

            $results.Success += $deviceId
        } catch {
            $results.Failed += @{
                DeviceId = $deviceId
                Error = $_.Exception.Message
            }
        }

        Start-Sleep -Milliseconds 100  # Rate limiting
    }

    Write-Progress -Activity "Updating Devices" -Completed
    return $results
}
```

## Token Management

```powershell
class NinjaApiClient {
    [string]$BaseUrl
    [string]$ClientId
    [string]$ClientSecret
    [string]$AccessToken
    [datetime]$TokenExpiry

    NinjaApiClient([string]$instance, [string]$clientId, [string]$clientSecret) {
        $this.BaseUrl = "https://$instance.ninjarmm.com/api/v2"
        $this.ClientId = $clientId
        $this.ClientSecret = $clientSecret
    }

    [void]RefreshToken() {
        $tokenUrl = $this.BaseUrl -replace '/api/v2', '/ws/oauth/token'
        $body = @{
            grant_type = "client_credentials"
            client_id = $this.ClientId
            client_secret = $this.ClientSecret
            scope = "monitoring management control"
        }

        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body
        $this.AccessToken = $response.access_token
        $this.TokenExpiry = (Get-Date).AddSeconds($response.expires_in - 60)
    }

    [hashtable]GetHeaders() {
        if (-not $this.AccessToken -or (Get-Date) -ge $this.TokenExpiry) {
            $this.RefreshToken()
        }

        return @{
            Authorization = "Bearer $($this.AccessToken)"
            Accept = "application/json"
        }
    }

    [object]InvokeApi([string]$endpoint, [string]$method = "Get", [object]$body = $null) {
        $uri = "$($this.BaseUrl)$endpoint"
        $headers = $this.GetHeaders()

        $params = @{
            Uri = $uri
            Headers = $headers
            Method = $method
        }

        if ($body) {
            $params.Body = ($body | ConvertTo-Json -Depth 10)
            $params.ContentType = "application/json"
        }

        return Invoke-RestMethod @params
    }
}
```

## Device Filtering Examples

### Get Offline Devices by Organization

```powershell
function Get-OfflineDevicesByOrg {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [int]$OrgId
    )

    $offline = Invoke-RestMethod -Uri "$BaseUrl/devices?df=org=$OrgId,status=OFFLINE" -Headers $Headers

    return $offline | Select-Object `
        @{N='DeviceId';E={$_.id}},
        @{N='Name';E={$_.displayName}},
        @{N='LastSeen';E={[DateTimeOffset]::FromUnixTimeSeconds($_.lastContact).LocalDateTime}},
        @{N='Class';E={$_.nodeClass}}
}
```

### Filter Devices by Multiple Criteria

```powershell
function Find-CriticalServers {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$OrgId,
        [int]$LocationId
    )

    # Get online Windows servers in specific org and location
    $filter = "org=$OrgId,location=$LocationId,class=WINDOWS_SERVER,status=ONLINE"
    $servers = Invoke-RestMethod -Uri "$BaseUrl/devices?df=$filter" -Headers $Headers

    # Further filter client-side for servers with role "Production"
    return $servers | Where-Object {
        $_.nodeRole.name -like "*Production*"
    }
}
```

### Get Recently Added Devices

```powershell
function Get-RecentDevices {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$Days = 7
    )

    $cutoffDate = (Get-Date).AddDays(-$Days)
    $timestamp = [Math]::Floor($cutoffDate.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)

    $recent = Invoke-RestMethod -Uri "$BaseUrl/devices?df=after=$timestamp" -Headers $Headers

    return $recent | Select-Object `
        displayName,
        nodeClass,
        @{N='CreatedDate';E={[DateTimeOffset]::FromUnixTimeSeconds($_.createTime).LocalDateTime}},
        @{N='Organization';E={$_.references.organization.name}}
}
```

### Search Devices with Pagination

```powershell
function Search-Devices {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$SearchTerm,

        [int]$PageSize = 100
    )

    $encoded = [System.Web.HttpUtility]::UrlEncode($SearchTerm)
    $allResults = [System.Collections.ArrayList]::new()
    $cursor = $null

    do {
        $url = "$BaseUrl/devices?df=search=$encoded&pageSize=$PageSize"
        if ($cursor) {
            $url += "&after=$cursor"
        }

        $response = Invoke-RestMethod -Uri $url -Headers $Headers

        if ($response) {
            [void]$allResults.AddRange(@($response))
        }

        $cursor = $null
        if ($response.PSObject.Properties['next']) {
            $nextUrl = $response.next
            if ($nextUrl -match 'after=([^&]+)') {
                $cursor = $matches[1]
            }
        }
    } while ($cursor)

    return $allResults.ToArray()
}
```

### Filter Report - Device Distribution

```powershell
function Get-DeviceDistributionReport {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$OrgId
    )

    $classes = @(
        'WINDOWS_WORKSTATION',
        'WINDOWS_SERVER',
        'MAC',
        'LINUX_SERVER',
        'LINUX_WORKSTATION',
        'CLOUD_MONITOR_TARGET'
    )

    $report = foreach ($class in $classes) {
        $devices = Invoke-RestMethod -Uri "$BaseUrl/devices?df=org=$OrgId,class=$class" -Headers $Headers

        [PSCustomObject]@{
            DeviceClass = $class
            Total = @($devices).Count
            Online = @($devices | Where-Object { $_.online }).Count
            Offline = @($devices | Where-Object { -not $_.online }).Count
        }
    }

    return $report
}
```

### Monitor New Device Approvals

```powershell
function Get-PendingApprovals {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$OrgId
    )

    $filter = "status=PENDING"
    if ($OrgId) {
        $filter += ",org=$OrgId"
    }

    $pending = Invoke-RestMethod -Uri "$BaseUrl/devices?df=$filter" -Headers $Headers

    return $pending | Select-Object `
        @{N='DeviceId';E={$_.id}},
        @{N='Name';E={$_.displayName}},
        @{N='Class';E={$_.nodeClass}},
        @{N='Organization';E={$_.references.organization.name}},
        @{N='Location';E={$_.references.location.name}},
        @{N='FirstSeen';E={[DateTimeOffset]::FromUnixTimeSeconds($_.createTime).LocalDateTime}}
}

# Auto-approve devices matching criteria
function Approve-DevicesByFilter {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [int]$OrgId,
        [string]$NamePattern
    )

    $pending = Get-PendingApprovals -BaseUrl $BaseUrl -Headers $Headers -OrgId $OrgId
    $toApprove = $pending | Where-Object { $_.Name -like $NamePattern }

    if ($toApprove) {
        $deviceIds = $toApprove | ForEach-Object { $_.DeviceId }
        $body = @{ devices = $deviceIds } | ConvertTo-Json

        Invoke-RestMethod `
            -Uri "$BaseUrl/devices/approval/APPROVE" `
            -Headers $Headers `
            -Method Post `
            -Body $body `
            -ContentType "application/json"

        Write-Host "Approved $($deviceIds.Count) devices"
    }
}
```
