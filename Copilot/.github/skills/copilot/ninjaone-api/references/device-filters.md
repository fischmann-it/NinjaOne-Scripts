# NinjaOne API Device Filters Reference

Complete reference for device filtering (`df` parameter) in NinjaOne API v2.

## Filter Syntax

Device filters use comma-separated key=value pairs in the `df` query parameter:

```
GET /devices?df=key1=value1,key2=value2
```

## Filter Keys

### org (Organization ID)

Filter devices by organization.

**Type:** Integer  
**Example:** `df=org=123`

```powershell
# Get all devices in organization 123
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=123" -Headers $headers
```

### class (Device Class)

Filter by device type/class.

**Type:** String (enum)  
**Valid Values:**
- `WINDOWS_WORKSTATION` - Windows desktop/laptop
- `WINDOWS_SERVER` - Windows Server
- `MAC` - macOS device
- `LINUX_SERVER` - Linux server
- `LINUX_WORKSTATION` - Linux desktop
- `CLOUD_MONITOR_TARGET` - Cloud monitoring target
- `VMHOST` - Virtual machine host
- `NETWORK_DEVICE` - Network equipment
- `NAS` - Network attached storage

**Example:** `df=class=WINDOWS_SERVER`

```powershell
# Get all Windows servers
$servers = Invoke-RestMethod -Uri "$baseUrl/devices?df=class=WINDOWS_SERVER" -Headers $headers

# Get all Mac devices
$macs = Invoke-RestMethod -Uri "$baseUrl/devices?df=class=MAC" -Headers $headers
```

### status (Device Status)

Filter by device online/offline status.

**Type:** String (enum)  
**Valid Values:**
- `ONLINE` - Device is currently online
- `OFFLINE` - Device is offline
- `PENDING` - Device pending approval
- `APPROVED` - Device approved but not yet online

**Example:** `df=status=OFFLINE`

```powershell
# Get all offline devices
$offline = Invoke-RestMethod -Uri "$baseUrl/devices?df=status=OFFLINE" -Headers $headers
```

### role (Node Role ID)

Filter by assigned node role.

**Type:** Integer  
**Example:** `df=role=5`

```powershell
# Get all devices with role ID 5
$roleDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=role=5" -Headers $headers
```

### location (Location ID)

Filter by location.

**Type:** Integer  
**Example:** `df=location=10`

```powershell
# Get all devices in location 10
$locationDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=location=10" -Headers $headers
```

### after (Modified After Timestamp)

Filter devices modified after a specific Unix timestamp.

**Type:** Integer (Unix timestamp)  
**Example:** `df=after=1640000000`

```powershell
# Get devices modified in last 24 hours
$yesterday = [Math]::Floor((Get-Date).AddDays(-1).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$recent = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$yesterday" -Headers $headers

# Get devices modified after specific date
$timestamp = [Math]::Floor((Get-Date "2024-01-01").ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$timestamp" -Headers $headers
```

### before (Modified Before Timestamp)

Filter devices modified before a specific Unix timestamp.

**Type:** Integer (Unix timestamp)  
**Example:** `df=before=1640100000`

```powershell
# Get devices modified before specific date
$timestamp = [Math]::Floor((Get-Date "2024-01-31").ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=before=$timestamp" -Headers $headers

# Get devices in specific date range
$start = [Math]::Floor((Get-Date "2024-01-01").ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$end = [Math]::Floor((Get-Date "2024-01-31").ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$range = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$start,before=$end" -Headers $headers
```

### search (Search Term)

Search in device display name.

**Type:** String  
**Example:** `df=search=srv`

```powershell
# Search for devices with "prod" in name
$searchResults = Invoke-RestMethod -Uri "$baseUrl/devices?df=search=prod" -Headers $headers

# URL encode special characters
$searchTerm = "Server-01"
$encoded = [System.Web.HttpUtility]::UrlEncode($searchTerm)
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=search=$encoded" -Headers $headers
```

## Combining Filters

Multiple filters are combined with AND logic (all conditions must match).

```powershell
# Windows servers in organization 123 that are online
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=123,class=WINDOWS_SERVER,status=ONLINE" -Headers $headers

# Offline devices in specific location
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=location=10,status=OFFLINE" -Headers $headers

# Recent Windows workstations
$yesterday = [Math]::Floor((Get-Date).AddDays(-1).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=class=WINDOWS_WORKSTATION,after=$yesterday" -Headers $headers

# Complex filter
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=123,location=5,class=WINDOWS_SERVER,status=ONLINE,role=3" -Headers $headers
```

## Filter Helper Functions

### Dynamic Filter Builder

```powershell
function New-DeviceFilter {
    [CmdletBinding()]
    param(
        [int]$OrgId,
        [ValidateSet('WINDOWS_WORKSTATION','WINDOWS_SERVER','MAC','LINUX_SERVER','LINUX_WORKSTATION','CLOUD_MONITOR_TARGET','VMHOST','NETWORK_DEVICE','NAS')]
        [string]$Class,
        [ValidateSet('ONLINE','OFFLINE','PENDING','APPROVED')]
        [string]$Status,
        [int]$RoleId,
        [int]$LocationId,
        [datetime]$After,
        [datetime]$Before,
        [string]$Search
    )
    
    $parts = @()
    
    if ($PSBoundParameters.ContainsKey('OrgId')) {
        $parts += "org=$OrgId"
    }
    if ($PSBoundParameters.ContainsKey('Class')) {
        $parts += "class=$Class"
    }
    if ($PSBoundParameters.ContainsKey('Status')) {
        $parts += "status=$Status"
    }
    if ($PSBoundParameters.ContainsKey('RoleId')) {
        $parts += "role=$RoleId"
    }
    if ($PSBoundParameters.ContainsKey('LocationId')) {
        $parts += "location=$LocationId"
    }
    if ($PSBoundParameters.ContainsKey('After')) {
        $timestamp = [Math]::Floor($After.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
        $parts += "after=$timestamp"
    }
    if ($PSBoundParameters.ContainsKey('Before')) {
        $timestamp = [Math]::Floor($Before.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
        $parts += "before=$timestamp"
    }
    if ($PSBoundParameters.ContainsKey('Search')) {
        $encoded = [System.Web.HttpUtility]::UrlEncode($Search)
        $parts += "search=$encoded"
    }
    
    return $parts -join ','
}

# Usage
$filter = New-DeviceFilter -OrgId 123 -Class WINDOWS_SERVER -Status ONLINE
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=$filter" -Headers $headers
```

### Filter from Hashtable

```powershell
function ConvertTo-DeviceFilter {
    param([hashtable]$Filters)
    
    $parts = $Filters.GetEnumerator() | ForEach-Object {
        $key = $_.Key
        $value = $_.Value
        
        # Handle datetime conversion
        if ($value -is [datetime]) {
            $value = [Math]::Floor($value.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
        }
        
        # Handle URL encoding for strings
        if ($value -is [string] -and $key -eq 'search') {
            $value = [System.Web.HttpUtility]::UrlEncode($value)
        }
        
        "$key=$value"
    }
    
    return $parts -join ','
}

# Usage
$filterSpec = @{
    org = 123
    class = 'WINDOWS_SERVER'
    status = 'ONLINE'
    after = (Get-Date).AddDays(-7)
}
$filter = ConvertTo-DeviceFilter -Filters $filterSpec
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=$filter" -Headers $headers
```

## Common Filter Patterns

### Organization-Scoped Operations

```powershell
# Get all devices in organization
$allOrgDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId" -Headers $headers

# Get only servers in organization
$orgServers = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId,class=WINDOWS_SERVER" -Headers $headers

# Get offline devices in organization
$orgOffline = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId,status=OFFLINE" -Headers $headers
```

### Location-Based Filtering

```powershell
# Get all devices in location
$locationDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=location=$locationId" -Headers $headers

# Get online workstations in location
$locationWorkstations = Invoke-RestMethod -Uri "$baseUrl/devices?df=location=$locationId,class=WINDOWS_WORKSTATION,status=ONLINE" -Headers $headers
```

### Time-Based Queries

```powershell
# Devices added today
$todayStart = Get-Date -Hour 0 -Minute 0 -Second 0
$timestamp = [Math]::Floor($todayStart.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$todayDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$timestamp" -Headers $headers

# Devices modified this week
$weekStart = (Get-Date).AddDays(-(Get-Date).DayOfWeek.value__)
$timestamp = [Math]::Floor($weekStart.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$weekDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$timestamp" -Headers $headers

# Devices in date range
$start = [Math]::Floor((Get-Date "2024-01-01").ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$end = [Math]::Floor((Get-Date "2024-01-31").ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$rangeDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$start,before=$end" -Headers $headers
```

### Device Type Filtering

```powershell
# All servers (Windows + Linux)
$allServers = @(
    (Invoke-RestMethod -Uri "$baseUrl/devices?df=class=WINDOWS_SERVER" -Headers $headers)
    (Invoke-RestMethod -Uri "$baseUrl/devices?df=class=LINUX_SERVER" -Headers $headers)
)

# All workstations
$allWorkstations = @(
    (Invoke-RestMethod -Uri "$baseUrl/devices?df=class=WINDOWS_WORKSTATION" -Headers $headers)
    (Invoke-RestMethod -Uri "$baseUrl/devices?df=class=LINUX_WORKSTATION" -Headers $headers)
    (Invoke-RestMethod -Uri "$baseUrl/devices?df=class=MAC" -Headers $headers)
)
```

### Search Patterns

```powershell
# Search by prefix
$prodServers = Invoke-RestMethod -Uri "$baseUrl/devices?df=search=PROD" -Headers $headers

# Search with special characters
$searchTerm = "Server-01"
$encoded = [System.Web.HttpUtility]::UrlEncode($searchTerm)
$results = Invoke-RestMethod -Uri "$baseUrl/devices?df=search=$encoded" -Headers $headers

# Search within organization
$orgSearch = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId,search=web" -Headers $headers
```

## Filter Limitations

1. **No OR Logic**: Filters use AND logic only. To get devices matching multiple criteria with OR logic, make separate API calls and combine results.

2. **No Wildcards**: Search term matches substrings but doesn't support wildcards like `*` or `?`.

3. **Case Sensitivity**: Filter values are case-sensitive. Use exact enum values (e.g., `WINDOWS_SERVER` not `windows_server`).

4. **No Negation**: Cannot filter for "not equal" (e.g., cannot get all devices except WINDOWS_SERVER).

5. **Limited Text Search**: The `search` parameter only searches device display name, not other fields.

## Workarounds for Limitations

### OR Logic Emulation

```powershell
# Get Windows servers OR Linux servers
$windowsServers = Invoke-RestMethod -Uri "$baseUrl/devices?df=class=WINDOWS_SERVER" -Headers $headers
$linuxServers = Invoke-RestMethod -Uri "$baseUrl/devices?df=class=LINUX_SERVER" -Headers $headers
$allServers = @($windowsServers) + @($linuxServers)
```

### Client-Side Filtering

```powershell
# Get devices and filter client-side for complex conditions
$allDevices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId" -Headers $headers

# Filter for devices NOT in specific class
$excludedClass = 'CLOUD_MONITOR_TARGET'
$filtered = $allDevices | Where-Object { $_.nodeClass -ne $excludedClass }

# Complex client-side filter
$filtered = $allDevices | Where-Object {
    ($_.nodeClass -eq 'WINDOWS_SERVER' -and $_.system.memory -gt 8GB) -or
    ($_.nodeClass -eq 'LINUX_SERVER' -and $_.lastContact -gt $weekAgo)
}
```

## Best Practices

1. **Filter Early**: Apply filters in API call rather than retrieving all data and filtering client-side
2. **Combine Filters**: Use multiple filter keys to reduce result set size
3. **Pagination**: Always implement pagination when using filters that may return large result sets
4. **Validate Values**: Validate enum values (class, status) before making API calls
5. **URL Encoding**: Always URL-encode search terms and values with special characters
6. **Cache Results**: Cache filtered results for repeated queries with same criteria
7. **Monitor Performance**: Log filter response times to identify slow queries

## Additional Resources

- [Main API Skill](../SKILL.md)
- [API Examples](./api-examples.md)
- [NinjaOne API Documentation](https://app.ninjarmm.com/apidocs-v2)
