---
name: ninjaone-api
description: Use when code uses Invoke-RestMethod with NinjaOne API URLs, references ninjarmm.com/api/v2, implements OAuth2 for NinjaOne, or user asks about NinjaOne REST API, device filters, pagination, or bulk API operations.
---

# NinjaOne REST API v2

The NinjaOne Public API v2 provides programmatic access to manage devices, organizations, tickets, custom fields, tags, and monitoring data via HTTP requests.

**Base URL:** `https://{instance}.ninjarmm.com/api/v2`

**API Documentation:** `https://{instance}.ninjarmm.com/apidocs-v2`

## When to Use This Skill

- Automating device management and monitoring
- Integrating NinjaOne with external systems (PSA, ITSM, etc.)
- Building custom dashboards and reports
- Bulk operations on organizations, locations, or devices
- Creating and managing tickets programmatically
- Reading/writing custom field data via API
- Synchronizing data between NinjaOne and other platforms

## Prerequisites

1. **API Credentials:**
   - Client ID and Client Secret (OAuth2)
   - Obtained from NinjaOne Administration > Apps > API
   - Scopes: `monitoring`, `management`, `control`

2. **Required Tools:**
   - HTTP client library (e.g., `Invoke-RestMethod`, `curl`, `requests`)
   - JSON parsing capabilities
   - Secure credential storage mechanism

## Authentication

### OAuth2 Access Token

```powershell
# Get OAuth2 token
$tokenUrl = "https://{instance}.ninjarmm.com/ws/oauth/token"
$body = @{
    grant_type    = "client_credentials"
    client_id     = $env:NINJA_CLIENT_ID
    client_secret = $env:NINJA_CLIENT_SECRET
    scope         = "monitoring management control"
}

$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
$accessToken = $tokenResponse.access_token

# Use token in API requests
$headers = @{
    Authorization = "Bearer $accessToken"
    Accept        = "application/json"
}
```

### Token Lifecycle

- Access tokens expire after a configured period (typically 1 hour)
- Store tokens securely (never hardcode in scripts)
- Implement token refresh logic for long-running operations
- Use environment variables or secure vaults for credentials

## Common API Patterns

### Pagination

Most list endpoints support cursor-based pagination:

```powershell
# Get all devices with pagination
$baseUrl = "https://{instance}.ninjarmm.com/api/v2"
$allDevices = @()
$cursor = $null

do {
    $url = "$baseUrl/devices?pageSize=100"
    if ($cursor) {
        $url += "&after=$cursor"
    }

    $response = Invoke-RestMethod -Uri $url -Headers $headers
    $allDevices += $response

    # Extract cursor from next page link
    if ($response.PSObject.Properties['next']) {
        $cursor = [System.Web.HttpUtility]::ParseQueryString(
            ([uri]$response.next).Query
        )['after']
    } else {
        $cursor = $null
    }
} while ($cursor)
```

### Filtering

Use query parameters to filter results:

```powershell
# Filter devices by organization
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId" -Headers $headers

# Filter by timestamp
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$timestamp" -Headers $headers

# Multiple filters
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=$orgId,class=WINDOWS_WORKSTATION" -Headers $headers
```

### Device Filters (df Parameter)

NinjaOne API supports powerful filtering using the `df` (device filter) parameter. Filters use a comma-separated key=value syntax.

### Filter Syntax

```
?df=key1=value1,key2=value2,key3=value3
```

### Available Filter Keys

| Filter Key | Type | Description | Example Values |
|------------|------|-------------|----------------|
| `org` | Integer | Organization ID | `df=org=123` |
| `class` | String | Device class | `WINDOWS_WORKSTATION`, `WINDOWS_SERVER`, `MAC`, `LINUX_SERVER`, `CLOUD_MONITOR_TARGET` |
| `status` | String | Device status | `ONLINE`, `OFFLINE`, `PENDING`, `APPROVED` |
| `role` | Integer | Node role ID | `df=role=5` |
| `location` | Integer | Location ID | `df=location=10` |
| `after` | Integer | Unix timestamp (devices modified after) | `df=after=1640000000` |
| `before` | Integer | Unix timestamp (devices modified before) | `df=before=1640100000` |
| `search` | String | Search in device name | `df=search=srv` |

### Device Classes

| Class Value | Description |
|-------------|-------------|
| `WINDOWS_WORKSTATION` | Windows desktop/laptop |
| `WINDOWS_SERVER` | Windows Server |
| `MAC` | macOS device |
| `LINUX_SERVER` | Linux server |
| `LINUX_WORKSTATION` | Linux desktop |
| `CLOUD_MONITOR_TARGET` | Cloud monitoring target |
| `VMHOST` | Virtual machine host |
| `NETWORK_DEVICE` | Network equipment |
| `NAS` | Network attached storage |

### Filter Examples

```powershell
# Filter by organization
$devices = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=123" -Headers $headers

# Filter by device class
$servers = Invoke-RestMethod -Uri "$baseUrl/devices?df=class=WINDOWS_SERVER" -Headers $headers

# Filter by status
$offline = Invoke-RestMethod -Uri "$baseUrl/devices?df=status=OFFLINE" -Headers $headers

# Multiple filters (AND logic)
$orgServers = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=123,class=WINDOWS_SERVER,status=ONLINE" -Headers $headers

# Filter by time range (devices modified in last 24 hours)
$yesterday = [Math]::Floor((Get-Date).AddDays(-1).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
$recent = Invoke-RestMethod -Uri "$baseUrl/devices?df=after=$yesterday" -Headers $headers

# Search by name
$searchResults = Invoke-RestMethod -Uri "$baseUrl/devices?df=search=prod" -Headers $headers

# Complex filter: Online Windows workstations in specific org and location
$filtered = Invoke-RestMethod -Uri "$baseUrl/devices?df=org=123,location=5,class=WINDOWS_WORKSTATION,status=ONLINE" -Headers $headers
```

### URL Encoding Considerations

When filter values contain special characters, ensure proper URL encoding:

```powershell
# Using System.Web.HttpUtility
Add-Type -AssemblyName System.Web
$searchTerm = "Server-01"
$encoded = [System.Web.HttpUtility]::UrlEncode($searchTerm)
$url = "$baseUrl/devices?df=search=$encoded"

# Or use -Uri automatic encoding with Invoke-RestMethod
$devices = Invoke-RestMethod -Uri "$baseUrl/devices" -Headers $headers -Body @{ df = "search=Server-01" }
```

### Error Handling

```powershell
try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json

    switch ($statusCode) {
        400 { Write-Error "Bad Request: $($errorBody.message)" }
        401 { Write-Error "Unauthorized: Token may be expired" }
        403 { Write-Error "Forbidden: Insufficient permissions" }
        404 { Write-Error "Not Found: Resource does not exist" }
        429 { Write-Error "Rate Limited: Retry after $($_.Exception.Response.Headers['Retry-After']) seconds" }
        500 { Write-Error "Server Error: $($errorBody.message)" }
        default { Write-Error "HTTP $statusCode: $($errorBody.message)" }
    }
    throw
}
```

## Core Endpoints

### Organizations

```powershell
# List all organizations
$orgs = Invoke-RestMethod -Uri "$baseUrl/organizations" -Headers $headers

# Get organization details
$org = Invoke-RestMethod -Uri "$baseUrl/organization/$orgId" -Headers $headers

# Create organization
$newOrg = @{
    name = "New Organization"
    description = "Created via API"
    nodeApprovalMode = "AUTOMATIC"
}
$created = Invoke-RestMethod -Uri "$baseUrl/organizations" -Headers $headers -Method Post -Body ($newOrg | ConvertTo-Json) -ContentType "application/json"

# Update organization
$update = @{
    name = "Updated Name"
    description = "Updated description"
}
$updated = Invoke-RestMethod -Uri "$baseUrl/organization/$orgId" -Headers $headers -Method Patch -Body ($update | ConvertTo-Json) -ContentType "application/json"
```

### Devices

```powershell
# List all devices
$devices = Invoke-RestMethod -Uri "$baseUrl/devices" -Headers $headers

# Get device details
$device = Invoke-RestMethod -Uri "$baseUrl/device/$deviceId" -Headers $headers

# Update device
$update = @{
    displayName = "Updated Device Name"
    nodeRoleId = 123
}
$updated = Invoke-RestMethod -Uri "$baseUrl/device/$deviceId" -Headers $headers -Method Patch -Body ($update | ConvertTo-Json) -ContentType "application/json"

# Approve pending device
$approve = @{
    devices = @($deviceId)
}
Invoke-RestMethod -Uri "$baseUrl/devices/approval/APPROVE" -Headers $headers -Method Post -Body ($approve | ConvertTo-Json) -ContentType "application/json"
```

### Custom Fields

```powershell
# Get device custom fields
$fields = Invoke-RestMethod -Uri "$baseUrl/device/$deviceId/custom-fields" -Headers $headers

# Update custom field value
$update = @(
    @{
        name  = "FieldName"
        value = "New Value"
    }
)
Invoke-RestMethod -Uri "$baseUrl/device/$deviceId/custom-fields" -Headers $headers -Method Patch -Body ($update | ConvertTo-Json) -ContentType "application/json"

# Get organization custom fields
$orgFields = Invoke-RestMethod -Uri "$baseUrl/organization/$orgId/custom-fields" -Headers $headers
```

### Queries (Reports)

```powershell
# Device health report
$health = Invoke-RestMethod -Uri "$baseUrl/queries/device-health" -Headers $headers

# Custom fields report
$fieldsReport = Invoke-RestMethod -Uri "$baseUrl/queries/custom-fields?fields=FieldName1,FieldName2" -Headers $headers

# Software inventory
$software = Invoke-RestMethod -Uri "$baseUrl/queries/software?df=org=$orgId" -Headers $headers

# OS patches report
$patches = Invoke-RestMethod -Uri "$baseUrl/queries/os-patches?status=PENDING" -Headers $headers
```

### Scripting

```powershell
# Get available scripts for device
$options = Invoke-RestMethod -Uri "$baseUrl/device/$deviceId/scripting/options" -Headers $headers

# Run script on device
$runScript = @{
    type = "ACTION"
    id = 123
    parameters = "param1=value1"
    runAs = "SYSTEM"
}
Invoke-RestMethod -Uri "$baseUrl/device/$deviceId/script/run" -Headers $headers -Method Post -Body ($runScript | ConvertTo-Json) -ContentType "application/json"
```

### Ticketing

```powershell
# Create ticket
$newTicket = @{
    clientId = $orgId
    ticketFormId = 1
    subject = "API Created Ticket"
    description = @{
        public = $true
        htmlBody = "<p>Ticket description</p>"
    }
    status = "OPEN"
    priority = "MEDIUM"
    requesterUid = $userUid
}
$ticket = Invoke-RestMethod -Uri "$baseUrl/ticketing/ticket" -Headers $headers -Method Post -Body ($newTicket | ConvertTo-Json) -ContentType "application/json"

# Get ticket
$ticket = Invoke-RestMethod -Uri "$baseUrl/ticketing/ticket/$ticketId" -Headers $headers

# Update ticket
$update = @{
    version = $ticket.version
    clientId = $ticket.clientId
    ticketFormId = $ticket.ticketFormId
    subject = "Updated Subject"
    status = "IN_PROGRESS"
    requesterUid = $ticket.requesterUid
}
Invoke-RestMethod -Uri "$baseUrl/ticketing/ticket/$ticketId" -Headers $headers -Method Put -Body ($update | ConvertTo-Json) -ContentType "application/json"
```

## Best Practices

### Rate Limiting

- Implement exponential backoff for 429 responses
- Respect `Retry-After` header values
- Batch operations where possible
- Cache frequently accessed data

```powershell
function Invoke-NinjaApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = "Get",
        [object]$Body,
        [int]$MaxRetries = 3
    )

    $attempt = 0
    do {
        try {
            $params = @{
                Uri = $Uri
                Headers = $Headers
                Method = $Method
            }
            if ($Body) {
                $params.Body = ($Body | ConvertTo-Json -Depth 10)
                $params.ContentType = "application/json"
            }

            return Invoke-RestMethod @params
        } catch {
            $attempt++
            $statusCode = $_.Exception.Response.StatusCode.value__

            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $retryAfter = $_.Exception.Response.Headers['Retry-After']
                if ($retryAfter) {
                    $waitSeconds = [int]$retryAfter
                } else {
                    $waitSeconds = [math]::Pow(2, $attempt)
                }
                Write-Warning "Rate limited. Waiting $waitSeconds seconds..."
                Start-Sleep -Seconds $waitSeconds
            } else {
                throw
            }
        }
    } while ($attempt -lt $MaxRetries)
}
```

### Secure Credential Management

```powershell
# Use environment variables
$clientId = $env:NINJA_CLIENT_ID
$clientSecret = $env:NINJA_CLIENT_SECRET

# Or use Azure Key Vault / AWS Secrets Manager
# Or use PowerShell SecretManagement module
$secret = Get-Secret -Name "NinjaClientSecret" -Vault "MyVault"
```

### Data Validation

```powershell
# Validate response structure
function Assert-NinjaApiResponse {
    param($Response, [string]$ExpectedProperty)

    if (-not $Response) {
        throw "Empty response from API"
    }

    if ($ExpectedProperty -and -not $Response.PSObject.Properties[$ExpectedProperty]) {
        throw "Expected property '$ExpectedProperty' not found in response"
    }
}

$device = Invoke-RestMethod -Uri "$baseUrl/device/$deviceId" -Headers $headers
Assert-NinjaApiResponse -Response $device -ExpectedProperty "id"
```

## Common Use Cases

### Bulk Device Updates

```powershell
# Update custom field for all devices in organization
$devices = Invoke-RestMethod -Uri "$baseUrl/organization/$orgId/devices" -Headers $headers

foreach ($device in $devices) {
    $update = @(
        @{
            name = "LastAuditDate"
            value = (Get-Date).ToString("yyyy-MM-dd")
        }
    )

    try {
        Invoke-RestMethod -Uri "$baseUrl/device/$($device.id)/custom-fields" `
            -Headers $headers `
            -Method Patch `
            -Body ($update | ConvertTo-Json) `
            -ContentType "application/json"

        Write-Verbose "Updated device: $($device.displayName)"
    } catch {
        Write-Warning "Failed to update device $($device.id): $_"
    }
}
```

### Synchronize with External System

```powershell
# Export device inventory to CSV
$devices = Invoke-RestMethod -Uri "$baseUrl/devices-detailed" -Headers $headers

$inventory = $devices | Select-Object `
    @{N='DeviceID';E={$_.id}},
    @{N='Name';E={$_.displayName}},
    @{N='Organization';E={$_.references.organization.name}},
    @{N='Location';E={$_.references.location.name}},
    @{N='OS';E={$_.system.operatingSystem.name}},
    @{N='LastContact';E={[DateTimeOffset]::FromUnixTimeSeconds($_.lastContact).LocalDateTime}}

$inventory | Export-Csv -Path "ninja_inventory.csv" -NoTypeInformation
```

### Automated Ticket Creation from Alerts

```powershell
# Monitor for critical alerts and create tickets
$alerts = Invoke-RestMethod -Uri "$baseUrl/alerts?severity=CRITICAL" -Headers $headers

foreach ($alert in $alerts) {
    # Check if ticket already exists for this alert
    $existingTicket = $alert.psaTicketId

    if (-not $existingTicket) {
        $ticket = @{
            clientId = $alert.device.organizationId
            ticketFormId = 1
            subject = "Critical Alert: $($alert.subject)"
            description = @{
                public = $true
                htmlBody = "<p>$($alert.message)</p><p>Device: $($alert.device.displayName)</p>"
            }
            status = "OPEN"
            priority = "HIGH"
            severity = "CRITICAL"
            nodeId = $alert.deviceId
        }

        Invoke-RestMethod -Uri "$baseUrl/ticketing/ticket" `
            -Headers $headers `
            -Method Post `
            -Body ($ticket | ConvertTo-Json) `
            -ContentType "application/json"
    }
}
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401 Unauthorized | Check token expiration, regenerate access token |
| 403 Forbidden | Verify API client has required scopes (monitoring, management, control) |
| 404 Not Found | Confirm resource ID is correct and exists |
| 429 Rate Limited | Implement retry logic with exponential backoff |
| 500 Server Error | Check API status page, retry with exponential backoff |
| Empty Response | Verify filters and pagination parameters |
| Parsing Error | Ensure `-ContentType "application/json"` is set for POST/PATCH/PUT |

## Common Mistakes

1. **Missing `ContentType` on POST/PATCH/PUT** - `Invoke-RestMethod` defaults to form-encoded bodies. Always include `-ContentType "application/json"` when sending JSON. Without it, the API returns 400 or silently ignores the body.
2. **Wrong body format for custom fields** - The custom fields PATCH endpoint expects an **array** of objects, not a bare hashtable. Use `@( @{ name = "..."; value = "..." } )` not `@{ @{ ... } }`. A hashtable cannot contain an unlabelled hashtable — `ConvertTo-Json` on the latter produces invalid JSON.
3. **Forgetting `-Depth` on `ConvertTo-Json`** - The default depth is 2. Nested objects (e.g., ticket `description` with `htmlBody`) are silently truncated to `"System.Collections.Hashtable"`. Use `-Depth 10` for complex bodies.
4. **Using string IDs where integers are required** - Filter values like `org=`, `location=`, and `role=` expect integers. Passing a string-typed variable (e.g., `"$orgId"`) may work in some contexts but fail in others — cast explicitly: `[int]$orgId`.
5. **Ignoring cursor-based pagination** - Endpoints like `/devices` return up to 100 results by default. Without pagination logic, bulk operations silently miss devices. Always implement the `after` cursor loop for any endpoint that returns lists.

## References

- [NinjaOne API Documentation](https://app.ninjarmm.com/apidocs-v2/core-resources)
- [Device Filter Reference](./references/device-filters.md)
- [Advanced Examples](./references/api-examples.md)
- Related Skills:
  - [ninjaone-custom-fields](../ninjaone-custom-fields/SKILL.md) - Use API endpoints for bulk custom field operations across devices
  - [ninjaone-tags](../ninjaone-tags/SKILL.md) - Create, delete, and merge tag definitions via API
  - [ninjaone-environment-variables](../ninjaone-environment-variables/SKILL.md) - Use NINJA_AGENT_NODE_ID for device API calls
  - [ninjaone-script-variables](../ninjaone-script-variables/SKILL.md) - Pass API credentials securely via script variables
