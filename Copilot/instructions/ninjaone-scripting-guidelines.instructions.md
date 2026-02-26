---
applyTo: '**/*.ps1,**/*.psm1'
description: 'NinjaOne RMM platform-specific PowerShell scripting guidelines for automation scripts, ensuring proper handling of environment variables, script variables, and platform integration.'
---

# NinjaOne PowerShell Scripting Guidelines

This guide provides NinjaOne RMM platform-specific instructions for GitHub Copilot to generate scripts that work seamlessly with the NinjaOne agent environment. These guidelines extend the general PowerShell cmdlet development guidelines with NinjaOne-specific patterns.

## NinjaOne Environment Variables

The NinjaOne agent provides the following built-in environment variables accessible via `$env:VARIABLE_NAME`:

- **Agent Information:**
  - `$env:NINJA_EXECUTING_PATH` - Agent install location
  - `$env:NINJA_AGENT_VERSION_INSTALLED` - Current agent version
  - `$env:NINJA_PATCHER_VERSION_INSTALLED` - Current patcher version
  - `$env:NINJA_DATA_PATH` - Agent data folder (scripts, policy, downloads, logs)
  - `$env:NINJA_AGENT_PASSWORD` - Agent password for obtaining session key
  - `$env:NINJA_AGENT_MACHINE_ID` - Machine ID used on the server

- **Organization Context:**
  - `$env:NINJA_ORGANIZATION_NAME` - Organization name
  - `$env:NINJA_ORGANIZATION_ID` - Organization ID
  - `$env:NINJA_COMPANY_NAME` - Company name
  - `$env:NINJA_LOCATION_ID` - Location ID
  - `$env:NINJA_LOCATION_NAME` - Location name
  - `$env:NINJA_AGENT_NODE_ID` - Node ID used on the server

### Example

```powershell
function Get-NinjaEnvironmentInfo {
    <#
    .SYNOPSIS
        Retrieves NinjaOne agent environment information.
    
    .DESCRIPTION
        Collects and returns NinjaOne agent environment variables as a structured object.
    
    .OUTPUTS
        PSCustomObject with NinjaOne environment details
    
    .EXAMPLE
        Get-NinjaEnvironmentInfo
    #>
    [CmdletBinding()]
    param()

    process {
        [PSCustomObject]@{
            AgentPath       = $env:NINJA_EXECUTING_PATH
            AgentVersion    = $env:NINJA_AGENT_VERSION_INSTALLED
            DataPath        = $env:NINJA_DATA_PATH
            MachineId       = $env:NINJA_AGENT_MACHINE_ID
            NodeId          = $env:NINJA_AGENT_NODE_ID
            Organization    = $env:NINJA_ORGANIZATION_NAME
            OrganizationId  = $env:NINJA_ORGANIZATION_ID
            Company         = $env:NINJA_COMPANY_NAME
            Location        = $env:NINJA_LOCATION_NAME
            LocationId      = $env:NINJA_LOCATION_ID
        }
    }
}
```

## NinjaOne Script Variables

NinjaOne converts script variables defined in the platform into environment variables when the script executes.

### Key Characteristics

- **Always Strings:** All script variables are sent as strings, regardless of intended type
- **Empty Values:** Empty (non-mandatory) variables are sent as empty strings (`""`)
- **Type Conversion Required:** Scripts must cast variables to appropriate types
- **No Strong Typing:** Platform does not enforce type constraints

### Script Variable Types and Formats

NinjaOne provides several variable types in the UI, but all are transmitted to scripts as strings:

| Variable Type | Format Sent to Script | Example Value |
|--------------|----------------------|---------------|
| **String/Text** | Plain string as entered | `"Hello World"` |
| **Integer** | Whole numbers as string | `"314"` |
| **Decimal** | Floating-point numbers as string | `"3.14"` |
| **Checkbox** | String `"true"` when checked, `"false"` when unchecked | `"true"` or `"false"` |
| **Date** | ISO 8601 format: `YYYY-MM-ddT00:00:00.000+00:00` | `"2024-01-15T00:00:00.000+00:00"` |
| **Date/Time** | ISO 8601 format: `YYYY-MM-ddTHH:MM:SS.SSSZ` | `"2023-07-28T03:00:00.000+01:00"` |
| **DropDown** | Selected value as string | `"Production"` |
| **IP Address** | IP address as string | `"192.168.1.100"` |

### Variable Handling Best Practices

- **Always Validate:** Check for empty strings before processing
- **Explicit Casting:** Convert string variables to required types
- **Provide Defaults:** Use default values for optional parameters
- **Validate Input:** Implement robust input validation (IP format, date parsing, etc.)
- **Error Handling:** Handle conversion failures gracefully
- **Document Types:** Clearly document expected types in script comments
- **Timezone Awareness:** Handle timezone offsets in date/time variables

### Example: Script Variable Handling

```powershell
# Script variables from NinjaOne (received as environment variables)
# Expected variables:
#   - ServerName (string, mandatory)
#   - Port (integer, optional, default: 443)
#   - TimeoutSeconds (integer, optional, default: 30)
#   - EnableLogging (checkbox/boolean, optional, default: false)
#   - MaintenanceWindow (datetime, optional)
#   - IPAddress (IP address, optional)

# Validation and type conversion
$serverName = $env:ServerName
if ([string]::IsNullOrWhiteSpace($serverName)) {
    Write-Error "ServerName is required but was not provided"
    exit 1
}

# Convert and validate Port (Integer type)
$port = 443
if (-not [string]::IsNullOrWhiteSpace($env:Port)) {
    try {
        $port = [int]$env:Port
        if ($port -lt 1 -or $port -gt 65535) {
            Write-Warning "Port value '$port' is outside valid range (1-65535). Using default: 443"
            $port = 443
        }
    } catch {
        Write-Warning "Failed to convert Port '$env:Port' to integer. Using default: 443"
        $port = 443
    }
}

# Convert and validate TimeoutSeconds (Integer type)
$timeoutSeconds = 30
if (-not [string]::IsNullOrWhiteSpace($env:TimeoutSeconds)) {
    try {
        $timeoutSeconds = [int]$env:TimeoutSeconds
        if ($timeoutSeconds -lt 1) {
            Write-Warning "TimeoutSeconds must be positive. Using default: 30"
            $timeoutSeconds = 30
        }
    } catch {
        Write-Warning "Failed to convert TimeoutSeconds. Using default: 30"
        $timeoutSeconds = 30
    }
}

# Convert checkbox/boolean string to boolean (Checkbox type)
$enableLogging = $false
if (-not [string]::IsNullOrWhiteSpace($env:EnableLogging)) {
    $enableLogging = $env:EnableLogging -eq 'true'
}

# Convert and validate Date/Time (Date/Time type - ISO 8601 format)
$maintenanceWindow = $null
if (-not [string]::IsNullOrWhiteSpace($env:MaintenanceWindow)) {
    try {
        $maintenanceWindow = [DateTime]::Parse($env:MaintenanceWindow, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        Write-Verbose "Maintenance window parsed: $($maintenanceWindow.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    } catch {
        Write-Warning "Failed to parse MaintenanceWindow '$env:MaintenanceWindow'. Ignoring maintenance window."
        $maintenanceWindow = $null
    }
}

# Validate IP Address (IP Address type)
$ipAddress = $null
if (-not [string]::IsNullOrWhiteSpace($env:IPAddress)) {
    try {
        $ipAddress = [System.Net.IPAddress]::Parse($env:IPAddress)
        Write-Verbose "IP Address validated: $ipAddress"
    } catch {
        Write-Warning "Invalid IP Address format: '$env:IPAddress'. Ignoring IP address."
        $ipAddress = $null
    }
}

Write-Verbose "Configuration: Server=$serverName, Port=$port, Timeout=$timeoutSeconds, Logging=$enableLogging"
```

## NinjaOne Preset Parameters

NinjaOne supports passing parameters directly to scripts at runtime using preset parameter strings. This is different from Script Variables and provides flexibility for ad-hoc script execution.

### Key Characteristics

- **Runtime Input:** Parameters are passed when the script is executed, not configured beforehand
- **Positional Parameters:** Parameters are consumed in the order they are passed
- **Space-Delimited:** Multiple parameters are separated by spaces
- **Quote Support:** Values containing spaces must be wrapped in quotes
- **Preset Strings:** Common parameter combinations can be saved as presets for reuse

### Parameter Patterns by Script Type

#### PowerShell Scripts

Use `param()` block with positional or named parameters:

```powershell
<#
.SYNOPSIS
    Creates a new user account with specified credentials.

.DESCRIPTION
    Accepts username and password as parameters from NinjaOne preset parameters.
    
.NOTES
    NinjaOne Preset Parameters:
    - Parameter 1: Username (supports spaces when quoted)
    - Parameter 2: Password
    
    Example preset parameter strings:
    - "John Doe" SecurePass123
    - Alice P@ssw0rd!
    - "Bob Smith" TempPass456

.EXAMPLE
    # Called by NinjaOne with preset parameters: "John Doe" SecurePass123
    # Creates user: John Doe with password: SecurePass123
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Username,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$Password
)

try {
    Write-Verbose "Creating user account: $Username"
    
    # User creation logic
    net user "$Username" "$Password" /add
    
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Successfully created user: $Username"
        exit 0
    } else {
        Write-Error "Failed to create user: $Username"
        exit 1
    }
} catch {
    Write-Error "Error creating user: $_"
    exit 1
}
```

#### Batch Scripts

Use positional parameters with `%1`, `%2`, `%3`, etc.:

```batch
@echo off
REM filepath: create-user.bat
REM NinjaOne Preset Parameters:
REM   %1 = Username
REM   %2 = Password
REM
REM Example preset parameter strings:
REM   Bob Password1
REM   "Linda Smith" NewPassword
REM   Joe Passw0rd

net user %1 %2 /add

if %ERRORLEVEL% EQU 0 (
    echo Successfully created user: %1
    exit /b 0
) else (
    echo Failed to create user: %1
    exit /b 1
)
```

### Preset Parameters vs Script Variables

Choose the appropriate approach based on your use case:

| Feature | Preset Parameters | Script Variables |
|---------|------------------|------------------|
| **Configuration** | Set at runtime when executing script | Configured in script definition and prompted at execution |
| **Flexibility** | Ad-hoc values, useful for one-off operations | Structured, validated inputs with type hints |
| **Reusability** | Preset strings can be saved and reused | Variable definitions are part of the script |
| **Validation** | Manual validation required in script | Platform provides UI validation (dropdowns, checkboxes, etc.) |
| **Use Case** | Quick actions, testing, technician-driven tasks | Standardized operations, automated policies |
| **Typed Values** | All values are strings, position-based | All values are strings, name-based via environment variables |

### Best Practices for Preset Parameters

1. **Document Parameter Order:** Clearly document which parameter position maps to which value
2. **Validate Required Parameters:** Check that all required parameters are provided
3. **Handle Spaces:** Always quote parameters with spaces in documentation examples
4. **Use Meaningful Presets:** Create preset parameter strings for common scenarios
5. **Validate Input:** Implement robust input validation in your script
6. **Position Matters:** Parameters are consumed in order; document this clearly
7. **Provide Examples:** Include example preset parameter strings in script help

### Example: Combined Preset Parameters with Validation

```powershell
<#
.SYNOPSIS
    Configures service settings with validation.

.DESCRIPTION
    Accepts service name, startup type, and optional account via preset parameters.

.NOTES
    NinjaOne Preset Parameters (in order):
    1. ServiceName (string, required) - Name of the Windows service
    2. StartupType (string, required) - Automatic, Manual, or Disabled
    3. ServiceAccount (string, optional) - Account to run service as (default: LocalSystem)
    
    Example preset parameter strings:
    - "Windows Update" Automatic
    - "Print Spooler" Manual LocalService
    - "Superfetch" Disabled
    - wuauserv Automatic

.EXAMPLE
    # NinjaOne executes with: "Windows Update" Automatic
    # Sets Windows Update service to start automatically
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceName,

    [Parameter(Position = 1, Mandatory = $true)]
    [ValidateSet('Automatic', 'Manual', 'Disabled', IgnoreCase = $true)]
    [string]$StartupType,

    [Parameter(Position = 2)]
    [string]$ServiceAccount = 'LocalSystem'
)

#region Validation
Write-Verbose "Validating parameters..."
Write-Verbose "ServiceName: $ServiceName"
Write-Verbose "StartupType: $StartupType"
Write-Verbose "ServiceAccount: $ServiceAccount"

# Verify service exists
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Error "Service '$ServiceName' not found"
    exit 1
}

# Normalize startup type
$startupTypeMap = @{
    'Automatic' = 'Automatic'
    'Manual'    = 'Manual'
    'Disabled'  = 'Disabled'
}
$normalizedStartupType = $startupTypeMap[$StartupType]
#endregion

#region Main Logic
try {
    Write-Verbose "Configuring service: $ServiceName"
    
    # Configure startup type
    Set-Service -Name $ServiceName -StartupType $normalizedStartupType -ErrorAction Stop
    
    # Configure service account if specified and not default
    if ($ServiceAccount -ne 'LocalSystem') {
        Write-Verbose "Setting service account to: $ServiceAccount"
        # Additional logic for service account configuration
    }
    
    Write-Output "Successfully configured service '$ServiceName': StartupType=$normalizedStartupType"
    exit 0
    
} catch {
    Write-Error "Failed to configure service '$ServiceName': $_"
    exit 1
}
#endregion

### Example: Handling Empty Optional Parameters

```powershell
<#
.SYNOPSIS
    Installs software with optional configuration.

.NOTES
    NinjaOne Preset Parameters:
    1. InstallerPath (string, required)
    2. InstallArguments (string, optional)
    3. LogPath (string, optional)
    
    Example preset parameter strings:
    - "C:\Temp\app.msi"
    - "C:\Temp\app.msi" "/quiet /norestart"
    - "C:\Temp\app.msi" "/quiet" "C:\Logs\install.log"
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Position = 1)]
    [string]$InstallArguments = '',

    [Parameter(Position = 2)]
    [string]$LogPath = ''
)

# Handle empty optional parameters
if ([string]::IsNullOrWhiteSpace($InstallArguments)) {
    $InstallArguments = '/quiet /norestart'
    Write-Verbose "Using default install arguments: $InstallArguments"
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = "C:\Logs\install-$(Get-Date -Format 'yyyyMMddHHmmss').log"
    Write-Verbose "Using default log path: $LogPath"
}

# Validate installer exists
if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
    exit 1
}

try {
    Write-Verbose "Installing from: $InstallerPath"
    Write-Verbose "Arguments: $InstallArguments"
    Write-Verbose "Log file: $LogPath"
    
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $InstallArguments -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -eq 0) {
        Write-Output "Installation completed successfully"
        exit 0
    } else {
        Write-Error "Installation failed with exit code: $($process.ExitCode)"
        exit 1
    }
} catch {
    Write-Error "Installation error: $_"
    exit 1
}
```

### When to Use Preset Parameters

**Use Preset Parameters when:**
- Technicians need to provide different values for each execution
- Testing scripts with various inputs
- Running one-off operations with specific values
- Creating reusable parameter combinations for common scenarios
- Quick actions that don't need structured UI validation

**Use Script Variables when:**
- Deploying scripts via policies or automations
- Need structured UI with dropdowns, checkboxes, date pickers
- Want validation at the UI level before execution
- Running standardized operations across multiple devices
- Need to enforce specific input formats (IP addresses, dates, etc.)

**Use Both when:**
- Script Variables define the core configuration
- Preset Parameters override specific values for troubleshooting or special cases

## NinjaOne Script Structure

### Standard Script Template

```powershell
<#
.SYNOPSIS
    Brief description of what the script does.

.DESCRIPTION
    Detailed description of the script functionality and NinjaOne integration.

.NOTES
    NinjaOne Script Variables (define these in the NinjaOne platform):
    - VariableName1 (Type): Description and default value if any
    - VariableName2 (Type): Description and default value if any
    
    NinjaOne Environment Variables Used:
    - NINJA_ORGANIZATION_NAME
    - NINJA_DATA_PATH (or other relevant variables)

.EXAMPLE
    This script is designed to run via NinjaOne RMM.
    Configure script variables in the NinjaOne platform before deployment.
#>

[CmdletBinding()]
param()

#region Script Variables Validation
Write-Verbose 'Validating and converting NinjaOne script variables...'

# Validate mandatory variables
$requiredVariable = $env:RequiredVariable
if ([string]::IsNullOrWhiteSpace($requiredVariable)) {
    Write-Error "Required variable 'RequiredVariable' is not set"
    exit 1
}

# Convert and validate optional variables with defaults
# ...additional variable handling...

Write-Verbose 'Script variables validated successfully'
#endregion

#region Main Script Logic
try {
    Write-Verbose "Starting script execution in organization: $env:NINJA_ORGANIZATION_NAME"
    
    # Main script functionality here
    
    Write-Output "Script completed successfully"
    exit 0
} catch {
    Write-Error "Script failed: $_"
    exit 1
}
#endregion
```

## Error Handling and Exit Codes

- **Exit Codes:** Use standard exit codes for NinjaOne monitoring
  - `exit 0` - Success
  - `exit 1` - General failure
  - `exit 2+` - Specific error conditions (document meaning)

- **Output Streams:**
  - Use `Write-Output` for results that should appear in NinjaOne script output
  - Use `Write-Verbose` for detailed logging (enable with `-Verbose` in script settings)
  - Use `Write-Warning` for non-critical issues
  - Use `Write-Error` for errors that should be visible in NinjaOne alerts

- **Logging:**
  - Script output is captured by NinjaOne and viewable in the activity log
  - Use structured output with `Write-Output` for important information
  - Consider external logging solutions for persistent logs if needed

### Example: NinjaOne Error Handling

```powershell
function Invoke-NinjaOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationName
    )

    begin {
        Write-Verbose "Starting operation: $OperationName"
    }

    process {
        try {
            Write-Verbose "Executing operation: $OperationName"
            
            # Operation logic here
            
            Write-Output "Operation '$OperationName' completed successfully"
            
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Error "Operation '$OperationName' failed: $errorMessage"
            throw
        }
    }
}

# Main script execution with exit codes
try {
    Invoke-NinjaOperation -OperationName "SystemCheck"
    exit 0
} catch {
    Write-Error "Script failed: $_"
    exit 1
}
```

## Type Conversion Helpers

Create reusable functions for common type conversions from NinjaOne script variables:

```powershell
function ConvertTo-TypedValue {
    <#
    .SYNOPSIS
        Converts NinjaOne script variable (string) to specified type with validation.
    
    .DESCRIPTION
        Handles conversion of NinjaOne script variables from strings to strongly-typed values.
        Supports Integer, Decimal, Boolean (Checkbox), DateTime (Date/Date-Time), and IP Address types.
    
    .EXAMPLE
        $port = ConvertTo-TypedValue -Value $env:Port -Type 'Int32' -DefaultValue 443 -Min 1 -Max 65535
    
    .EXAMPLE
        $enabled = ConvertTo-TypedValue -Value $env:EnableFeature -Type 'Boolean' -DefaultValue $false
    
    .EXAMPLE
        $deadline = ConvertTo-TypedValue -Value $env:DueDate -Type 'DateTime'
    
    .EXAMPLE
        $serverIP = ConvertTo-TypedValue -Value $env:ServerIPAddress -Type 'IPAddress'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [ValidateSet('Int32', 'Int64', 'Boolean', 'DateTime', 'Double', 'Decimal', 'IPAddress')]
        [string]$Type,

        [Parameter()]
        $DefaultValue,

        [Parameter()]
        [object]$Min,

        [Parameter()]
        [object]$Max
    )

    process {
        # Handle empty values
        if ([string]::IsNullOrWhiteSpace($Value)) {
            if ($PSBoundParameters.ContainsKey('DefaultValue')) {
                return $DefaultValue
            }
            Write-Warning "Empty value provided with no default for type $Type"
            return $null
        }

        try {
            $convertedValue = switch ($Type) {
                'Int32' { 
                    [int]$Value 
                }
                'Int64' { 
                    [long]$Value 
                }
                'Boolean' { 
                    # Handle NinjaOne Checkbox type (sent as 'true' or 'false' strings)
                    $Value -eq 'true'
                }
                'DateTime' { 
                    # Handle NinjaOne Date and Date/Time types (ISO 8601 format)
                    [DateTime]::Parse($Value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                }
                'Double' { 
                    [double]$Value 
                }
                'Decimal' {
                    # Handle NinjaOne Decimal type
                    [decimal]$Value
                }
                'IPAddress' {
                    # Handle NinjaOne IP Address type
                    [System.Net.IPAddress]::Parse($Value)
                }
            }

            # Range validation for numeric types
            if ($Type -in @('Int32', 'Int64', 'Double', 'Decimal')) {
                if ($PSBoundParameters.ContainsKey('Min') -and $convertedValue -lt $Min) {
                    Write-Warning "Value $convertedValue is below minimum $Min. Using default."
                    return $DefaultValue
                }
                if ($PSBoundParameters.ContainsKey('Max') -and $convertedValue -gt $Max) {
                    Write-Warning "Value $convertedValue is above maximum $Max. Using default."
                    return $DefaultValue
                }
            }

            return $convertedValue

        } catch {
            Write-Warning "Failed to convert '$Value' to $Type`: $($_.Exception.Message). Using default."
            if ($PSBoundParameters.ContainsKey('DefaultValue')) {
                return $DefaultValue
            }
            return $null
        }
    }
}
```

### Advanced Type Conversion Examples

```powershell
# Example: Using ConvertTo-TypedValue for various NinjaOne variable types

# Integer variable
$maxRetries = ConvertTo-TypedValue -Value $env:MaxRetries -Type 'Int32' -DefaultValue 3 -Min 1 -Max 10

# Decimal variable
$diskThreshold = ConvertTo-TypedValue -Value $env:DiskThresholdGB -Type 'Decimal' -DefaultValue 100.5 -Min 0

# Checkbox variable (boolean)
$sendNotification = ConvertTo-TypedValue -Value $env:SendNotification -Type 'Boolean' -DefaultValue $false

# Date variable
$startDate = ConvertTo-TypedValue -Value $env:StartDate -Type 'DateTime'
if ($null -ne $startDate) {
    Write-Verbose "Start date: $($startDate.ToString('yyyy-MM-dd'))"
}

# Date/Time variable with timezone
$scheduledTime = ConvertTo-TypedValue -Value $env:ScheduledDateTime -Type 'DateTime'
if ($null -ne $scheduledTime) {
    Write-Verbose "Scheduled for: $($scheduledTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    
    # Convert to local time if needed
    $localTime = $scheduledTime.ToLocalTime()
    Write-Verbose "Local time: $($localTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}

# IP Address variable
$serverIP = ConvertTo-TypedValue -Value $env:ServerIP -Type 'IPAddress'
if ($null -ne $serverIP) {
    Write-Verbose "Connecting to IP: $($serverIP.ToString())"
    
    # IP address validation example
    if ($serverIP.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        Write-Verbose "IPv4 address detected"
    } elseif ($serverIP.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        Write-Verbose "IPv6 address detected"
    }
}

# DropDown variable (comes as a string, no conversion needed)
$environment = $env:Environment
if ([string]::IsNullOrWhiteSpace($environment)) {
    $environment = 'Production'
}
Write-Verbose "Target environment: $environment"
```

## NinjaOne Custom Fields and Documentation

NinjaOne provides the `ninjarmm-cli` executable and PowerShell module for accessing and managing custom fields and documentation data from scripts and automations.

### NinjaOne CLI Tool (ninjarmm-cli)

The `ninjarmm-cli` executable is automatically deployed by the NinjaOne agent to the following locations:

- **Windows:** `C:\ProgramData\NinjaRMMAgent\ninjarmm-cli.exe`
- **macOS:** `/Applications/NinjaRMMAgent/programdata/ninjarmm-cli`
- **Linux:** `/opt/NinjaRMMAgent/programdata/ninjarmm-cli`

#### Environment Variables for CLI Access

- **Windows:** `%NINJARMMCLI%` points to `C:\ProgramData\NinjaRMMAgent\ninjarmm-cli.exe`
- **Linux/macOS:** `$NINJA_DATA_PATH/ninjarmm-cli`

#### Important Notes

- **Secure Fields:** Write-only for documentation fields; use only in automations
- **PowerShell Version:** Versions 1 and 2 are not supported
- **System Execution:** Run scripts as SYSTEM or adjust permissions accordingly
- **Linux Execution:** Prefix commands with `./` (e.g., `./ninjarmm-cli get fieldname`)
- **Unicode Support:** Use `--direct-out` parameter for stdout on Windows if needed (may lose Unicode support)
- **Field Access:** Only fields with at least one filled value are accessible via CLI

#### Secure Field Access in Automations

Secure custom fields can only be accessed during automation execution:

- Script conditions and compound conditions
- Policy scheduled tasks and global scheduled tasks
- Run before/after actions (backup, patching, application install)
- Automation actions on conditions

**Secure fields cannot be accessed via:**
- Web terminal or local terminal
- Manual script execution outside automations

### NinjaOne PowerShell Module

When the NinjaOne agent installs, it deploys and loads a custom PowerShell module that provides enhanced cmdlets for interacting with custom fields.

#### Get-NinjaProperty

Retrieves and converts custom field values based on field name and type.

**Syntax:**
```powershell
Get-NinjaProperty [-Name] <String[]> [[-Type] <String>] [[-DocumentName] <String>] [<CommonParameters>]
```

**Supported Types:**
- Attachment, Checkbox, Date, DateTime, Decimal
- Device Dropdown, Device MultiSelect
- Dropdown, Email, Integer, IP Address
- MultiLine, MultiSelect
- Organization Dropdown, Organization Location Dropdown
- Organization Location MultiSelect, Organization MultiSelect
- Phone, Secure, Text, Time, WYSIWYG, URL

**Examples:**
```powershell
# Get dropdown field - returns GUID without type specification
$dropdownValue = Get-NinjaProperty -Name "Environment"

# Get dropdown field with type - returns user-friendly value
$dropdownValue = Get-NinjaProperty -Name "Environment" -Type "Dropdown"

# Get date field with automatic conversion
$maintenanceDate = Get-NinjaProperty -Name "NextMaintenance" -Type "Date"

# Get checkbox field as boolean
$isEnabled = Get-NinjaProperty -Name "FeatureEnabled" -Type "Checkbox"

# Get documentation field
$serverIP = Get-NinjaProperty -Name "IPAddress" -Type "IP Address" -DocumentName "Server Config"

# Get help
Get-Help Get-NinjaProperty -Full
```

#### Set-NinjaProperty

Sets custom field values with automatic type conversion.

**Syntax:**
```powershell
Set-NinjaProperty [-Name] <String> [-Value] <Object> [[-Type] <String>] [[-DocumentName] <String>] [<CommonParameters>]
```

**Supported Types:**
- Checkbox, Date, Date or Date Time, DateTime, Decimal
- Dropdown, Email, Integer, IP Address
- MultiLine, MultiSelect, Phone, Secure, Text, Time, URL, WYSIWYG

**Examples:**
```powershell
# Set dropdown field using friendly name (requires type specification)
Set-NinjaProperty -Name "Environment" -Value "Production" -Type "Dropdown"

# Set dropdown field using GUID (no type needed)
Set-NinjaProperty -Name "Environment" -Value "f1ba449c-fd34-49df-b878-af3877180d17"

# Set date field with DateTime object
Set-NinjaProperty -Name "NextMaintenance" -Value (Get-Date).AddDays(30) -Type "Date"

# Set checkbox field
Set-NinjaProperty -Name "FeatureEnabled" -Value $true -Type "Checkbox"

# Set secure field
Set-NinjaProperty -Name "APIKey" -Value "secret-key-value" -Type "Secure"

# Set multi-select field with friendly names
Set-NinjaProperty -Name "InstalledFeatures" -Value @("Feature1", "Feature2") -Type "MultiSelect"

# Get help
Get-Help Set-NinjaProperty -Full
```

#### Legacy PowerShell Commands

The original Ninja PowerShell commands still function but offer less functionality:

```powershell
# Legacy commands (still supported)
Ninja-Property-Get $AttributeName
Ninja-Property-Set $AttributeName $Value
Ninja-Property-Options $AttributeName
Ninja-Property-Clear $AttributeName

# Documentation commands
Ninja-Property-Docs-Templates
Ninja-Property-Docs-Names $TemplateId
Ninja-Property-Docs-Names "$TemplateName"
Ninja-Property-Docs-Get $TemplateId "$DocumentName" $AttributeName
Ninja-Property-Docs-Set $TemplateID "$DocumentName" $AttributeName "value"
Ninja-Property-Docs-Get-Single "templateName" "fieldName"
Ninja-Property-Docs-Set-Single "templateName" "fieldName" "new value"
Ninja-Property-Docs-Clear "templateId" "$DocumentName" $AttributeName
Ninja-Property-Docs-Options "templateId" "$DocumentName" $AttributeName
Ninja-Property-Docs-Clear-Single "templateName" "fieldName"
Ninja-Property-Docs-Options-Single "templateName" "fieldName"
```

### Custom Field Types and CLI Syntax

#### Checkbox Fields

**Format:** Boolean values (`true`/`false`, `1`/`0`)

```powershell
# PowerShell - Get
$enabled = Get-NinjaProperty -Name "IsEnabled" -Type "Checkbox"

# PowerShell - Set
Set-NinjaProperty -Name "IsEnabled" -Value $true -Type "Checkbox"

# CLI - Get
%NINJARMMCLI% get IsEnabled

# CLI - Set
%NINJARMMCLI% set IsEnabled true
%NINJARMMCLI% set IsEnabled 1
```

#### Date Fields

**Format:** Unix epoch seconds or ISO format (`yyyy-MM-dd`)

```powershell
# PowerShell - Get and convert
$maintenanceDate = Get-NinjaProperty -Name "MaintenanceDate" -Type "Date"

# PowerShell - Set with DateTime object
Set-NinjaProperty -Name "MaintenanceDate" -Value (Get-Date "2024-12-31") -Type "Date"

# CLI - Get (returns epoch seconds)
%NINJARMMCLI% get MaintenanceDate

# CLI - Set with ISO format
%NINJARMMCLI% set MaintenanceDate 2024-12-31

# CLI - Set with epoch seconds
%NINJARMMCLI% set MaintenanceDate 1735689600
```

#### DateTime Fields

**Format:** Unix epoch seconds or ISO format (`yyyy-MM-ddTHH:mm:ss`)

```powershell
# PowerShell - Get with automatic conversion
$scheduledTime = Get-NinjaProperty -Name "ScheduledTime" -Type "DateTime"

# PowerShell - Set with DateTime object
Set-NinjaProperty -Name "ScheduledTime" -Value (Get-Date) -Type "DateTime"

# CLI - Get (returns epoch seconds)
%NINJARMMCLI% get ScheduledTime

# CLI - Set with ISO format
%NINJARMMCLI% set ScheduledTime 2024-01-15T14:30:00

# CLI - Set with epoch seconds
%NINJARMMCLI% set ScheduledTime 1705330200
```

#### Decimal Fields

**Format:** Floating-point numbers (-9999999.999999 to 9999999.999999)

```powershell
# PowerShell - Get
$threshold = Get-NinjaProperty -Name "DiskThreshold" -Type "Decimal"

# PowerShell - Set
Set-NinjaProperty -Name "DiskThreshold" -Value 95.5 -Type "Decimal"

# CLI - Get
%NINJARMMCLI% get DiskThreshold

# CLI - Set
%NINJARMMCLI% set DiskThreshold 95.5
```

#### Dropdown Fields

**Format:** GUID or option name (with type specification)

```powershell
# PowerShell - Get with type (returns friendly name)
$env = Get-NinjaProperty -Name "Environment" -Type "Dropdown"

# PowerShell - Set with friendly name
Set-NinjaProperty -Name "Environment" -Value "Production" -Type "Dropdown"

# PowerShell - List options
Ninja-Property-Options "Environment"

# CLI - Get (returns GUID)
%NINJARMMCLI% get Environment

# CLI - List options
%NINJARMMCLI% options Environment

# CLI - Set with GUID
%NINJARMMCLI% set Environment f1ba449c-fd34-49df-b878-af3877180d17
```

#### Email Fields

**Format:** RFC 5322 email format

```powershell
# PowerShell - Get
$email = Get-NinjaProperty -Name "AdminEmail" -Type "Email"

# PowerShell - Set
Set-NinjaProperty -Name "AdminEmail" -Value "admin@example.com" -Type "Email"

# CLI - Get
%NINJARMMCLI% get AdminEmail

# CLI - Set
%NINJARMMCLI% set AdminEmail admin@example.com
```

#### Integer Fields

**Format:** Whole numbers (-2147483648 to 2147483647)

```powershell
# PowerShell - Get
$port = Get-NinjaProperty -Name "ServicePort" -Type "Integer"

# PowerShell - Set
Set-NinjaProperty -Name "ServicePort" -Value 8080 -Type "Integer"

# CLI - Get
%NINJARMMCLI% get ServicePort

# CLI - Set
%NINJARMMCLI% set ServicePort 8080
```

#### IP Address Fields

**Format:** IPv4 or IPv6 format

```powershell
# PowerShell - Get
$serverIP = Get-NinjaProperty -Name "ServerIP" -Type "IP Address"

# PowerShell - Set
Set-NinjaProperty -Name "ServerIP" -Value "192.168.1.100" -Type "IP Address"

# CLI - Get
%NINJARMMCLI% get ServerIP

# CLI - Set
%NINJARMMCLI% set ServerIP 192.168.1.100
```

#### MultiLine Text Fields

**Format:** Text string (10,000 character limit)

```powershell
# PowerShell - Get
$notes = Get-NinjaProperty -Name "Notes" -Type "MultiLine"

# PowerShell - Set with line breaks
$multiLineText = @"
Line 1
Line 2
Line 3
"@
Set-NinjaProperty -Name "Notes" -Value $multiLineText -Type "MultiLine"

# CLI - Get
%NINJARMMCLI% get Notes

# CLI - Set with piped data
dir | %NINJARMMCLI% set --stdin Notes

# CLI - Set with single line (use 'n for breaks)
%NINJARMMCLI% set Notes "Line 1'nLine 2'nLine 3"
```

#### MultiSelect Fields

**Format:** Comma-separated GUIDs or option names (with type)

```powershell
# PowerShell - Get with type (returns friendly names)
$features = Get-NinjaProperty -Name "EnabledFeatures" -Type "MultiSelect"

# PowerShell - Set with friendly names
Set-NinjaProperty -Name "EnabledFeatures" -Value @("Feature1", "Feature2") -Type "MultiSelect"

# PowerShell - List options
Ninja-Property-Options "EnabledFeatures"

# CLI - Get (returns GUIDs)
%NINJARMMCLI% get EnabledFeatures

# CLI - List options
%NINJARMMCLI% options EnabledFeatures

# CLI - Set with GUIDs (comma-separated)
%NINJARMMCLI% set EnabledFeatures "guid1,guid2,guid3"
```

#### Phone Number Fields

**Format:** E.164 format (up to 17 characters)

```powershell
# PowerShell - Get
$phone = Get-NinjaProperty -Name "SupportPhone" -Type "Phone"

# PowerShell - Set
Set-NinjaProperty -Name "SupportPhone" -Value "+12345678901" -Type "Phone"

# CLI - Get
%NINJARMMCLI% get SupportPhone

# CLI - Set
%NINJARMMCLI% set SupportPhone +12345678901
```

#### Secure Fields

**Format:** Encrypted string (write-only for documentation, 200 character limit)

```powershell
# PowerShell - Get (only in automations)
$apiKey = Get-NinjaProperty -Name "APIKey" -Type "Secure"

# PowerShell - Set
Set-NinjaProperty -Name "APIKey" -Value "secret-value" -Type "Secure"

# CLI - Get (only in automations)
%NINJARMMCLI% get APIKey

# CLI - Set (disable echo to prevent output)
@echo off
%NINJARMMCLI% set APIKey secret-value
@echo on
```

**Security Best Practices for Secure Fields:**
```powershell
# Windows Batch - Prevent echoing secure values
@echo off
%NINJARMMCLI% set APIKey %SecureValue%
@echo on

# PowerShell - Use Set-NinjaProperty (handles securely)
Set-NinjaProperty -Name "APIKey" -Value $secureValue -Type "Secure"

# Linux/macOS - Don't use set -x before secure operations
#!/bin/bash
# set -x  # AVOID THIS before setting secure fields
$NINJA_DATA_PATH/ninjarmm-cli set APIKey "$SECRET_VALUE"
```

#### Text Fields

**Format:** String (10,000 character limit)

```powershell
# PowerShell - Get
$hostname = Get-NinjaProperty -Name "ServerName" -Type "Text"

# PowerShell - Set
Set-NinjaProperty -Name "ServerName" -Value "PROD-WEB-01" -Type "Text"

# CLI - Get
%NINJARMMCLI% get ServerName

# CLI - Set
%NINJARMMCLI% set ServerName PROD-WEB-01
```

#### Time Fields

**Format:** Seconds or ISO format (`HH:mm:ss`)

```powershell
# PowerShell - Get
$backupTime = Get-NinjaProperty -Name "BackupTime" -Type "Time"

# PowerShell - Set
Set-NinjaProperty -Name "BackupTime" -Value "02:00:00" -Type "Time"

# CLI - Get (returns seconds)
%NINJARMMCLI% get BackupTime

# CLI - Set with ISO format
%NINJARMMCLI% set BackupTime 02:00:00

# CLI - Set with seconds (7200 = 2 hours)
%NINJARMMCLI% set BackupTime 7200
```

#### URL Fields

**Format:** URL string (200 character limit, must start with `https://`)

```powershell
# PowerShell - Get
$dashboardURL = Get-NinjaProperty -Name "DashboardURL" -Type "URL"

# PowerShell - Set
Set-NinjaProperty -Name "DashboardURL" -Value "https://dashboard.example.com" -Type "URL"

# CLI - Get
%NINJARMMCLI% get DashboardURL

# CLI - Set
%NINJARMMCLI% set DashboardURL https://dashboard.example.com
```

### Documentation Fields

Documentation fields allow storing structured data in templates and documents.

#### Working with Documentation Templates and Documents

```powershell
# PowerShell - List all templates
$templates = Ninja-Property-Docs-Templates
# Returns: 1=Server Config, 2=Network Config

# PowerShell - List documents in template by ID
$documents = Ninja-Property-Docs-Names 1
# Returns: 16=PROD-WEB-01, 17=PROD-DB-01

# PowerShell - List documents in template by name
$documents = Ninja-Property-Docs-Names "Server Config"

# PowerShell - Get field from multi-document template
$serverIP = Get-NinjaProperty -Name "IPAddress" -Type "IP Address" -DocumentName "PROD-WEB-01"

# PowerShell - Get field from single-document template
$value = Ninja-Property-Docs-Get-Single "Network Config" "Gateway"

# PowerShell - Set field in multi-document template
Set-NinjaProperty -Name "IPAddress" -Value "192.168.1.100" -Type "IP Address" -DocumentName "PROD-WEB-01"

# PowerShell - Set field in single-document template
Ninja-Property-Docs-Set-Single "Network Config" "Gateway" "192.168.1.1"

# CLI - List templates
%NINJARMMCLI% templates

# CLI - List templates with IDs
%NINJARMMCLI% templates --ids

# CLI - List documents by template ID
%NINJARMMCLI% documents 1

# CLI - List documents by template name
%NINJARMMCLI% documents "Server Config"

# CLI - Get field from document
%NINJARMMCLI% get "Server Config" "PROD-WEB-01" IPAddress

# CLI - Get field from single-document template
%NINJARMMCLI% get "Network Config" Gateway

# CLI - Set field in document (org-set)
%NINJARMMCLI% org-set "Server Config" "PROD-WEB-01" IPAddress "192.168.1.100"

# CLI - Set field in single-document template
%NINJARMMCLI% org-set "Network Config" Gateway "192.168.1.1"

# CLI - Clear field value (sets to NULL)
%NINJARMMCLI% org-clear "Server Config" "PROD-WEB-01" IPAddress

# CLI - Clear field in single-document template
%NINJARMMCLI% org-clear "Network Config" Gateway

# CLI - Get options for dropdown/multiselect in document
%NINJARMMCLI% org-options "Server Config" "PROD-WEB-01" Environment

# CLI - Get options for single-document template
%NINJARMMCLI% org-options "Network Config" ConnectionType
```

### Complete Custom Field Example

```powershell
<#
.SYNOPSIS
    Manages server configuration using NinjaOne custom fields and documentation.

.DESCRIPTION
    Demonstrates working with various custom field types and documentation fields.

.NOTES
    NinjaOne Custom Fields Used:
    - ServerEnvironment (Dropdown): Production, Staging, Development
    - MaintenanceEnabled (Checkbox): Enable/disable maintenance mode
    - MaxConnections (Integer): Maximum connection limit
    - CPUThreshold (Decimal): CPU usage threshold percentage
    - AdminEmail (Email): Administrator email address
    - LastMaintenanceDate (Date): Last maintenance date
    - NextScheduledMaintenance (DateTime): Next scheduled maintenance
    - BackupTime (Time): Daily backup time
    - MonitoringEnabled (Checkbox): Enable monitoring
    
    Documentation Template: Server Config
    - ServerName (Text)
    - IPAddress (IP Address)
    - Environment (Dropdown)
    - Notes (MultiLine)
#>

[CmdletBinding()]
param()

#region Get Custom Fields
Write-Verbose "Retrieving custom field values..."

# Get environment using enhanced cmdlet (returns friendly name)
$environment = Get-NinjaProperty -Name "ServerEnvironment" -Type "Dropdown"
Write-Verbose "Environment: $environment"

# Get maintenance status
$maintenanceEnabled = Get-NinjaProperty -Name "MaintenanceEnabled" -Type "Checkbox"
Write-Verbose "Maintenance Enabled: $maintenanceEnabled"

# Get connection limit
$maxConnections = Get-NinjaProperty -Name "MaxConnections" -Type "Integer"
Write-Verbose "Max Connections: $maxConnections"

# Get CPU threshold
$cpuThreshold = Get-NinjaProperty -Name "CPUThreshold" -Type "Decimal"
Write-Verbose "CPU Threshold: $cpuThreshold%"

# Get admin email
$adminEmail = Get-NinjaProperty -Name "AdminEmail" -Type "Email"
Write-Verbose "Admin Email: $adminEmail"

# Get last maintenance date
$lastMaintenance = Get-NinjaProperty -Name "LastMaintenanceDate" -Type "Date"
if ($lastMaintenance) {
    Write-Verbose "Last Maintenance: $($lastMaintenance.ToString('yyyy-MM-dd'))"
}

# Get next scheduled maintenance
$nextMaintenance = Get-NinjaProperty -Name "NextScheduledMaintenance" -Type "DateTime"
if ($nextMaintenance) {
    Write-Verbose "Next Maintenance: $($nextMaintenance.ToString('yyyy-MM-dd HH:mm:ss'))"
}
#endregion

#region Set Custom Fields
Write-Verbose "Updating custom field values..."

# Update maintenance status
Set-NinjaProperty -Name "MaintenanceEnabled" -Value $true -Type "Checkbox"

# Update last maintenance date to today
Set-NinjaProperty -Name "LastMaintenanceDate" -Value (Get-Date) -Type "Date"

# Schedule next maintenance (30 days from now at 2 AM)
$nextMaintenanceDate = (Get-Date).AddDays(30).Date.AddHours(2)
Set-NinjaProperty -Name "NextScheduledMaintenance" -Value $nextMaintenanceDate -Type "DateTime"

# Update CPU threshold
Set-NinjaProperty -Name "CPUThreshold" -Value 85.5 -Type "Decimal"

Write-Verbose "Custom fields updated successfully"
#endregion

#region Work with Documentation
Write-Verbose "Working with documentation fields..."

# Get server name from documentation
$serverName = $env:COMPUTERNAME

# Check if server document exists
$documents = Ninja-Property-Docs-Names "Server Config"
$documentExists = $documents -match $serverName

if ($documentExists) {
    # Get existing IP address
    $currentIP = Get-NinjaProperty -Name "IPAddress" -Type "IP Address" -DocumentName $serverName
    Write-Verbose "Current IP in documentation: $currentIP"
    
    # Update IP address if changed
    $actualIP = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" | 
                 Where-Object { $_.IPAddress -notlike "169.254.*" } | 
                 Select-Object -First 1).IPAddress
    
    if ($actualIP -and $actualIP -ne $currentIP) {
        Set-NinjaProperty -Name "IPAddress" -Value $actualIP -Type "IP Address" -DocumentName $serverName
        Write-Verbose "Updated IP address in documentation: $actualIP"
    }
    
    # Update notes with maintenance information
    $notes = @"
Last Maintenance: $(Get-Date -Format 'yyyy-MM-dd')
Next Maintenance: $($nextMaintenanceDate.ToString('yyyy-MM-dd HH:mm:ss'))
Environment: $environment
Status: Active
"@
    Set-NinjaProperty -Name "Notes" -Value $notes -Type "MultiLine" -DocumentName $serverName
}
#endregion

#region Output Results
Write-Output "Configuration updated successfully"
Write-Output "Server: $($env:COMPUTERNAME)"
Write-Output "Environment: $environment"
Write-Output "Maintenance Mode: $(if ($maintenanceEnabled) { 'Enabled' } else { 'Disabled' })"
Write-Output "Next Maintenance: $($nextMaintenanceDate.ToString('yyyy-MM-dd HH:mm:ss'))"
#endregion

exit 0
```

## NinjaOne WYSIWYG Custom Fields

NinjaOne Documentation application provides WYSIWYG (What You See Is What You Get) fields in Knowledge Base and custom fields for document templates. These fields support HTML, inline styling, Bootstrap 5 grid system, Font Awesome 6 icons, Charts.css, and NinjaOne-specific CSS classes.

### WYSIWYG Field Characteristics

- **Character Limit:** Maximum 200,000 characters
- **Auto-Collapse:** Fields with more than 10,000 characters collapse automatically; users click expand to view full content
- **Field Limit:** Maximum 20 WYSIWYG custom fields per form or document template
- **Styling Source:** HTML and inline styling must be applied via API or CLI (not available in NinjaOne console UI)
- **Allowlist-Based:** Only specific HTML elements and inline styles are permitted

### Allowed HTML Elements

The following HTML elements can be used in WYSIWYG fields:

| Element | Supports NinjaOne Classes | Purpose |
|---------|---------------------------|---------|
| `<a>` | Yes | Hyperlinks |
| `<blockquote>` | Yes | Block quotations |
| `<caption>` | Yes | Table captions |
| `<code>` | No | Inline code |
| `<col>` | Yes | Table column properties |
| `<div>` | Yes | Generic container |
| `<h1>` - `<h6>` | Yes | Headings (levels 1-6) |
| `<i>` | Yes | Italic text / icons |
| `<li>` | Yes | List items |
| `<ol>` | Yes | Ordered lists |
| `<p>` | Yes | Paragraphs |
| `<pre>` | No | Preformatted text |
| `<span>` | Yes | Inline container |
| `<table>` | Yes | Tables |
| `<tbody>` | Yes | Table body |
| `<td>` | Yes | Table data cells |
| `<tfoot>` | Yes | Table footer |
| `<th>` | Yes | Table header cells |
| `<thead>` | Yes | Table header |
| `<tr>` | Yes | Table rows |
| `<ul>` | Yes | Unordered lists |

### Allowed Inline Styles

Only the following inline CSS styles are permitted:

| Style Property | Allowed Values | Example |
|---------------|----------------|---------|
| `color` | RGB or hex color codes | `#f015ca`, `rgb(240,30,50,0.7)` |
| `background-color` | RGB or hex color codes | `#f015ca`, `rgb(240,30,50,0.7)` |
| `display` | block, inline, inline-block, flex, inline-flex | `display: flex` |
| `justify-content` | center, start, end, flex-start, flex-end, left, right, normal, space-between, space-around, space-evenly | `justify-content: space-between` |
| `align-items` | center, start, end, flex-start, flex-end, left, right, normal, stretch | `align-items: center` |
| `word-break` | normal, break-all, keep-all, break-word | `word-break: break-word` |
| `box-sizing` | border-box, content-box | `box-sizing: border-box` |
| `white-space` | normal, nowrap, pre, pre-wrap, pre-line, break-spaces | `white-space: nowrap` |
| `overflow-wrap` | normal, break-word, anywhere | `overflow-wrap: break-word` |
| `text-align` | start, end, left, center, right, justify, justify-all, match-parent | `text-align: center` |
| `width` | Valid CSS units | `100%`, `400px`, `auto`, `2em` |
| `height` | Valid CSS units | `100%`, `400px`, `auto`, `2em` |
| `font-size` | Valid CSS units | `16px`, `1.2em`, `100%` |
| `font-family` | serif, sans-serif, monospace, cursive, fantasy, system-ui, emoji | `font-family: sans-serif` |
| `margin` | Valid CSS units | `10px`, `1em`, `auto` |
| `margin-top/right/bottom/left` | Valid CSS units | `10px`, `1em`, `auto` |
| `padding` | Valid CSS units | `10px`, `1em` |
| `padding-top/right/bottom/left` | Valid CSS units | `10px`, `1em` |
| `border-width` | Valid CSS units | `1px`, `2px` |
| `border-style` | none, solid, dashed, inset, outset | `border-style: solid` |
| `border-color` | RGB or hex color codes | `#f015ca`, `rgb(240,30,50,0.7)` |
| `border-top/right/bottom/left` | Valid CSS units | `1px solid #000` |
| `border-radius` | Valid CSS units | `5px`, `50%` |
| `border-collapse` | collapse, separate | `border-collapse: collapse` |

### Bootstrap 5 Grid System

NinjaOne WYSIWYG fields fully support the Bootstrap 5 grid system for responsive layouts.

#### Grid Basics

- **12-Column System:** Bootstrap uses a 12-column flexible grid
- **Responsive Breakpoints:** Six default breakpoints (xs, sm, md, lg, xl, xxl)
- **Flexbox-Based:** Built with modern flexbox for flexible layouts
- **Containers:** `.container`, `.container-fluid`, or responsive containers (`.container-md`)

#### Breakpoints and Class Prefixes

| Breakpoint | Size | Container Max-Width | Class Prefix |
|------------|------|---------------------|--------------|
| Extra small (xs) | <576px | None (auto) | `.col-` |
| Small (sm) | ≥576px | 540px | `.col-sm-` |
| Medium (md) | ≥768px | 720px | `.col-md-` |
| Large (lg) | ≥992px | 960px | `.col-lg-` |
| Extra large (xl) | ≥1200px | 1140px | `.col-xl-` |
| Extra extra large (xxl) | ≥1400px | 1320px | `.col-xxl-` |

#### Bootstrap Grid Examples

```powershell
# Generate three equal-width columns
$html = @"
<div class="container">
  <div class="row">
    <div class="col">Column 1</div>
    <div class="col">Column 2</div>
    <div class="col">Column 3</div>
  </div>
</div>
"@

# Set one column width, others auto-size
$html = @"
<div class="container">
  <div class="row">
    <div class="col">1 of 3</div>
    <div class="col-6">2 of 3 (wider)</div>
    <div class="col">3 of 3</div>
  </div>
</div>
"@

# Responsive layout: stacked on mobile, horizontal on tablet+
$html = @"
<div class="container">
  <div class="row">
    <div class="col-sm-8">Main content</div>
    <div class="col-sm-4">Sidebar</div>
  </div>
</div>
"@

# Mix and match breakpoints
$html = @"
<div class="container">
  <div class="row">
    <div class="col-md-8">.col-md-8</div>
    <div class="col-6 col-md-4">.col-6 .col-md-4</div>
  </div>
  <div class="row">
    <div class="col-6 col-md-4">.col-6 .col-md-4</div>
    <div class="col-6 col-md-4">.col-6 .col-md-4</div>
    <div class="col-6 col-md-4">.col-6 .col-md-4</div>
  </div>
</div>
"@

# Row columns: set number of columns per row
$html = @"
<div class="container">
  <div class="row row-cols-1 row-cols-sm-2 row-cols-md-4">
    <div class="col">Column</div>
    <div class="col">Column</div>
    <div class="col">Column</div>
    <div class="col">Column</div>
  </div>
</div>
"@

# Nesting grids
$html = @"
<div class="container">
  <div class="row">
    <div class="col-sm-3">Sidebar</div>
    <div class="col-sm-9">
      <div class="row">
        <div class="col-8 col-sm-6">Nested 1</div>
        <div class="col-4 col-sm-6">Nested 2</div>
      </div>
    </div>
  </div>
</div>
"@
```

#### Gutter Classes

Control spacing between columns:

```powershell
# Horizontal gutters
$html = '<div class="row gx-5">...</div>'  # Extra large horizontal gutters

# Vertical gutters
$html = '<div class="row gy-3">...</div>'  # Medium vertical gutters

# All gutters
$html = '<div class="row g-2">...</div>'   # Small gutters all around

# No gutters
$html = '<div class="row g-0">...</div>'   # Remove all gutters
```

### Charts.css Support

NinjaOne supports Charts.css for data visualization in WYSIWYG fields.

#### Chart Types

- **Column Charts:** Vertical bar charts
- **Bar Charts:** Horizontal bar charts
- **Line Charts:** Line graphs (including multiple series)
- **Area Charts:** Filled area charts
- **Pie Charts:** Circular percentage charts

#### Chart Examples

```powershell
# Column chart with visible data
$columnChart = @"
<div class="col-xl-4 col-lg-6 col-md-12 col-sm-12 d-flex">
  <table class="charts-css column show-heading">
    <tbody>
      <tr><td style="--size: 0.4"><span class="data">40%</span></td></tr>
      <tr><td style="--size: 0.6"><span class="data">60%</span></td></tr>
      <tr><td style="--size: 0.75"><span class="data">75%</span></td></tr>
      <tr><td style="--size: 0.9"><span class="data">90%</span></td></tr>
      <tr><td style="--size: 1"><span class="data">100%</span></td></tr>
    </tbody>
  </table>
</div>
"@

# Bar chart
$barChart = @"
<table class="charts-css bar show-heading">
  <tbody>
    <tr><td style="--size: 0.4"><span class="data">40%</span></td></tr>
    <tr><td style="--size: 0.6"><span class="data">60%</span></td></tr>
    <tr><td style="--size: 0.75"><span class="data">75%</span></td></tr>
  </tbody>
</table>
"@

# Line chart with multiple series
$lineChart = @"
<table class="charts-css line multiple show-data-on-hover show-labels show-primary-axis show-10-secondary-axes show-heading">
  <tbody>
    <tr>
      <th scope="row">21-03</th>
      <td style="--start: 0.1; --end: 0.3;"><span class="data">30</span></td>
      <td style="--start: 0.6; --end: 0.4;"><span class="data">40</span></td>
      <td style="--start: 0.8; --end: 0.7;"><span class="data">70</span></td>
    </tr>
    <tr>
      <th scope="row">20-03</th>
      <td style="--start: 0.3; --end: 0.1;"><span class="data">10</span></td>
      <td style="--start: 0.4; --end: 0.6;"><span class="data">60</span></td>
      <td style="--start: 0.7; --end: 0.9;"><span class="data">90</span></td>
    </tr>
  </tbody>
</table>
"@

# Pie chart
$pieChart = @"
<div style="height:300px; width: 300px;">
  <table class="charts-css pie show-heading">
    <tbody>
      <tr><th scope="row">Category 1</th><td style="--start: 0; --end: 0.2;"><span class="data">20%</span></td></tr>
      <tr><th scope="row">Category 2</th><td style="--start: 0.2; --end: 0.3;"><span class="data">10%</span></td></tr>
      <tr><th scope="row">Category 3</th><td style="--start: 0.3; --end: 0.55;"><span class="data">25%</span></td></tr>
      <tr><th scope="row">Category 4</th><td style="--start: 0.55; --end: 1;"><span class="data">45%</span></td></tr>
    </tbody>
  </table>
</div>
"@

# Chart legend
$legend = @"
<ul class="charts-css legend legend-inline legend-rectangle">
  <li>CPU</li>
  <li>Memory</li>
  <li>Disk</li>
  <li>Network</li>
</ul>
"@
```

### NinjaOne CSS Classes

NinjaOne provides custom CSS classes for consistent styling:

#### Cards

```powershell
# Standard card
$standardCard = @"
<div class="card flex-grow-1">
  <div class="card-title-box">
    <div class="card-title"><i class="fas fa-server"></i>&nbsp;&nbsp;Server Status</div>
  </div>
  <div class="card-body">
    <p><b>Status:</b> Online</p>
    <p><b>Uptime:</b> 45 days</p>
    <p><b>CPU:</b> 25%</p>
    <p><b>Memory:</b> 60%</p>
  </div>
</div>
"@

# Card with action link
$cardWithAction = @"
<div class="card flex-grow-1">
  <div class="card-title-box">
    <div class="card-title"><i class="fas fa-shield-halved"></i>&nbsp;&nbsp;Security Status</div>
    <div class="card-link-box">
      <a href="https://example.com/security" target="_blank" class="card-link" rel="nofollow noopener noreferrer">
        <i class="fas fa-arrow-up-right-from-square" style="color: #337ab7;"></i>
      </a>
    </div>
  </div>
  <div class="card-body">
    <p>Antivirus: Active</p>
    <p>Firewall: Enabled</p>
    <p>Last Scan: 2024-01-15</p>
  </div>
</div>
"@
```

#### Tables

```powershell
# Table with status row classes
$table = @"
<table>
  <thead>
    <tr>
      <th>Service</th>
      <th>Status</th>
      <th>Port</th>
    </tr>
  </thead>
  <tbody>
    <tr class="success">
      <td>Web Server</td>
      <td>Running</td>
      <td>443</td>
    </tr>
    <tr class="danger">
      <td>Database</td>
      <td>Stopped</td>
      <td>3306</td>
    </tr>
    <tr class="warning">
      <td>Mail Server</td>
      <td>Degraded</td>
      <td>587</td>
    </tr>
    <tr class="other">
      <td>Cache</td>
      <td>Unknown</td>
      <td>6379</td>
    </tr>
  </tbody>
</table>
"@
```

#### Buttons

```powershell
$buttons = @"
<a href="https://example.com" target="_blank" class="btn">Primary Button</a>
<a href="https://example.com" target="_blank" class="btn secondary">Secondary Button</a>
<a href="https://example.com" target="_blank" class="btn danger">Danger Button</a>
"@
```

#### Info Cards

```powershell
# Informational
$infoCard = @"
<div class="info-card">
  <i class="info-icon fa-solid fa-circle-info"></i>
  <div class="info-text">
    <div class="info-title">Informational</div>
    <div class="info-description">System is operating normally.</div>
  </div>
</div>
"@

# Error
$errorCard = @"
<div class="info-card error">
  <i class="info-icon fa-solid fa-circle-exclamation"></i>
  <div class="info-text">
    <div class="info-title">Error Detected</div>
    <div class="info-description">Critical service has stopped.</div>
  </div>
</div>
"@

# Warning
$warningCard = @"
<div class="info-card warning">
  <i class="info-icon fa-solid fa-triangle-exclamation"></i>
  <div class="info-text">
    <div class="info-title">Warning</div>
    <div class="info-description">Disk space is running low.</div>
  </div>
</div>
"@

# Success
$successCard = @"
<div class="info-card success">
  <i class="info-icon fa-solid fa-circle-check"></i>
  <div class="info-text">
    <div class="info-title">Success</div>
    <div class="info-description">Backup completed successfully.</div>
  </div>
</div>
"@
```

#### Tags

```powershell
$tags = @"
<div class="tag">Enabled</div>
<div class="tag disabled">Disabled</div>
<div class="tag expired">Expired</div>
"@
```

#### Statistic Cards

```powershell
$statCards = @"
<div class="stat-card">
  <div class="stat-value">
    <a href="https://example.com" target="_blank" rel="nofollow noopener noreferrer">
      <span style="color: #008001;">25</span>
    </a>
  </div>
  <div class="stat-desc">
    <a href="https://example.com" target="_blank" rel="nofollow noopener noreferrer">
      <span style="font-size: 18px;">Active Users</span>
    </a>
  </div>
</div>
"@
```

#### Line Chart

```powershell
$lineChartSimple = @"
<div class="p-3 linechart">
  <div style="width: 33.3333333333%; background-color: #55ACBF;"></div>
  <div style="width: 33.3333333333%; background-color: #3633B7;"></div>
  <div style="width: 33.3333333333%; background-color: #8063BF;"></div>
</div>
<ul class="unstyled p-3" style="display: flex; justify-content: space-between;">
  <li><span class="chart-key" style="background-color: #55ACBF;"></span><span>Licensed (20)</span></li>
  <li><span class="chart-key" style="background-color: #3633B7;"></span><span>Unlicensed (20)</span></li>
  <li><span class="chart-key" style="background-color: #8063BF;"></span><span>Guests (20)</span></li>
</ul>
"@
```

### Font Awesome 6 Icons

NinjaOne supports the free Font Awesome 6 icon library:

```powershell
# Common icon examples
$icons = @"
<i class="fas fa-server"></i> Server
<i class="fas fa-database"></i> Database
<i class="fas fa-shield-halved"></i> Security
<i class="fas fa-user"></i> User
<i class="fas fa-gear"></i> Settings
<i class="fas fa-circle-check"></i> Success
<i class="fas fa-circle-xmark"></i> Error
<i class="fas fa-triangle-exclamation"></i> Warning
<i class="fas fa-circle-info"></i> Information
<i class="fas fa-arrow-up-right-from-square"></i> External Link
"@
```

### Practical Script Examples

#### Example 1: System Information Report

```powershell
<#
.SYNOPSIS
    Generates formatted system information report in WYSIWYG field.

.DESCRIPTION
    Collects system data and creates a Bootstrap-styled HTML report with cards,
    tables, and charts for display in NinjaOne WYSIWYG custom field.
#>

[CmdletBinding()]
param()

#region Collect System Data
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$memory = Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum
$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"

$cpuUsage = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
$memoryUsedPercent = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 2)
#endregion

#region Build HTML Report
$html = @"
<div class="container">
  <div class="row g-3">
    
    <!-- System Overview Card -->
    <div class="col-xl-6 col-lg-12">
      <div class="card flex-grow-1">
        <div class="card-title-box">
          <div class="card-title"><i class="fas fa-desktop"></i>&nbsp;&nbsp;System Overview</div>
        </div>
        <div class="card-body">
          <p><b>Computer Name:</b> $($env:COMPUTERNAME)</p>
          <p><b>Operating System:</b> $($os.Caption)</p>
          <p><b>OS Version:</b> $($os.Version)</p>
          <p><b>Architecture:</b> $($os.OSArchitecture)</p>
          <p><b>Last Boot:</b> $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))</p>
          <p><b>Uptime:</b> $([math]::Round((New-TimeSpan -Start $os.LastBootUpTime).TotalDays, 2)) days</p>
        </div>
      </div>
    </div>
    
    <!-- Hardware Card -->
    <div class="col-xl-6 col-lg-12">
      <div class="card flex-grow-1">
        <div class="card-title-box">
          <div class="card-title"><i class="fas fa-microchip"></i>&nbsp;&nbsp;Hardware</div>
        </div>
        <div class="card-body">
          <p><b>Processor:</b> $($cpu.Name)</p>
          <p><b>Cores:</b> $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) logical processors</p>
          <p><b>Total Memory:</b> $([math]::Round($memory.Sum / 1GB, 2)) GB</p>
        </div>
      </div>
    </div>
    
    <!-- Resource Usage -->
    <div class="col-12">
      <div class="card">
        <div class="card-title-box">
          <div class="card-title"><i class="fas fa-chart-line"></i>&nbsp;&nbsp;Resource Usage</div>
        </div>
        <div class="card-body">
          <div class="row g-3">
            <div class="col-md-6">
              <table class="charts-css bar show-heading">
                <tbody>
                  <tr>
                    <th scope="row">CPU</th>
                    <td style="--size: $([math]::Round($cpuUsage / 100, 2));"><span class="data">$([math]::Round($cpuUsage, 1))%</span></td>
                  </tr>
                  <tr>
                    <th scope="row">Memory</th>
                    <td style="--size: $([math]::Round($memoryUsedPercent / 100, 2));"><span class="data">$($memoryUsedPercent)%</span></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div class="col-md-6">
"@

# Add status info cards based on thresholds
if ($cpuUsage -gt 80) {
    $html += @"
              <div class="info-card warning">
                <i class="info-icon fa-solid fa-triangle-exclamation"></i>
                <div class="info-text">
                  <div class="info-title">High CPU Usage</div>
                  <div class="info-description">CPU usage is at $([math]::Round($cpuUsage, 1))%</div>
                </div>
              </div>
"@
}

if ($memoryUsedPercent -gt 85) {
    $html += @"
              <div class="info-card warning">
                <i class="info-icon fa-solid fa-triangle-exclamation"></i>
                <div class="info-text">
                  <div class="info-title">High Memory Usage</div>
                  <div class="info-description">Memory usage is at $($memoryUsedPercent)%</div>
                </div>
              </div>
"@
} else {
    $html += @"
              <div class="info-card success">
                <i class="info-icon fa-solid fa-circle-check"></i>
                <div class="info-text">
                  <div class="info-title">System Healthy</div>
                  <div class="info-description">All metrics within normal range</div>
                </div>
              </div>
"@
}

$html += @"
            </div>
          </div>
        </div>
      </div>
    </div>
    
    <!-- Disk Usage Table -->
    <div class="col-12">
      <div class="card">
        <div class="card-title-box">
          <div class="card-title"><i class="fas fa-hard-drive"></i>&nbsp;&nbsp;Disk Usage</div>
        </div>
        <div class="card-body">
          <table>
            <thead>
              <tr>
                <th>Drive</th>
                <th>Volume Name</th>
                <th>Total Size</th>
                <th>Free Space</th>
                <th>Used %</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
"@

foreach ($disk in $disks) {
    $usedPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 2)
    $rowClass = if ($usedPercent -gt 90) { "danger" } 
                elseif ($usedPercent -gt 80) { "warning" } 
                else { "success" }
    
    $html += @"
              <tr class="$rowClass">
                <td>$($disk.DeviceID)</td>
                <td>$($disk.VolumeName)</td>
                <td>$([math]::Round($disk.Size / 1GB, 2)) GB</td>
                <td>$([math]::Round($disk.FreeSpace / 1GB, 2)) GB</td>
                <td>$($usedPercent)%</td>
                <td>$(if ($usedPercent -gt 90) { "Critical" } elseif ($usedPercent -gt 80) { "Warning" } else { "OK" })</td>
              </tr>
"@
}

$html += @"
            </tbody>
          </table>
        </div>
      </div>
    </div>
    
  </div>
</div>
"@
#endregion

#region Set WYSIWYG Field
try {
    Set-NinjaProperty -Name "SystemReport" -Value $html -Type "WYSIWYG"
    Write-Output "System report generated and saved to WYSIWYG field successfully"
    exit 0
} catch {
    Write-Error "Failed to set WYSIWYG field: $_"
    exit 1
}
#endregion
```

#### Example 2: Service Status Dashboard

```powershell
<#
.SYNOPSIS
    Creates service status dashboard in WYSIWYG field.
#>

[CmdletBinding()]
param()

# Define critical services to monitor
$criticalServices = @(
    'wuauserv',      # Windows Update
    'BITS',          # Background Intelligent Transfer Service
    'WinDefend',     # Windows Defender
    'EventLog',      # Event Log
    'W32Time'        # Windows Time
)

#region Collect Service Data
$services = foreach ($serviceName in $criticalServices) {
    Get-Service -Name $serviceName -ErrorAction SilentlyContinue
}

$runningCount = ($services | Where-Object Status -eq 'Running').Count
$stoppedCount = ($services | Where-Object Status -eq 'Stopped').Count
$totalCount = $services.Count
#endregion

#region Build HTML Dashboard
$html = @"
<div class="container">
  <div class="row g-3">
    
    <!-- Statistics Cards -->
    <div class="col-md-4">
      <div class="stat-card">
        <div class="stat-value" style="color: #008001;">$runningCount</div>
        <div class="stat-desc">Running Services</div>
      </div>
    </div>
    <div class="col-md-4">
      <div class="stat-card">
        <div class="stat-value" style="color: #dc3545;">$stoppedCount</div>
        <div class="stat-desc">Stopped Services</div>
      </div>
    </div>
    <div class="col-md-4">
      <div class="stat-card">
        <div class="stat-value">$totalCount</div>
        <div class="stat-desc">Total Monitored</div>
      </div>
    </div>
    
    <!-- Service Status Chart -->
    <div class="col-12">
      <div class="card">
        <div class="card-title-box">
          <div class="card-title"><i class="fas fa-chart-pie"></i>&nbsp;&nbsp;Service Status Overview</div>
        </div>
        <div class="card-body">
          <div class="p-3 linechart">
            <div style="width: $([math]::Round(($runningCount / $totalCount) * 100, 2))%; background-color: #28a745;"></div>
            <div style="width: $([math]::Round(($stoppedCount / $totalCount) * 100, 2))%; background-color: #dc3545;"></div>
          </div>
          <ul class="unstyled p-3" style="display: flex; justify-content: space-between;">
            <li><span class="chart-key" style="background-color: #28a745;"></span><span>Running ($runningCount)</span></li>
            <li><span class="chart-key" style="background-color: #dc3545;"></span><span>Stopped ($stoppedCount)</span></li>
          </ul>
        </div>
      </div>
    </div>
    
    <!-- Detailed Service Table -->
    <div class="col-12">
      <div class="card">
        <div class="card-title-box">
          <div class="card-title"><i class="fas fa-list"></i>&nbsp;&nbsp;Service Details</div>
        </div>
        <div class="card-body">
          <table>
            <thead>
              <tr>
                <th>Service Name</th>
                <th>Display Name</th>
                <th>Status</th>
                <th>Startup Type</th>
              </tr>
            </thead>
            <tbody>
"@

foreach ($service in $services) {
    $rowClass = if ($service.Status -eq 'Running') { 'success' } else { 'danger' }
    $statusIcon = if ($service.Status -eq 'Running') { 
        '<i class="fas fa-circle-check" style="color: #28a745;"></i>' 
    } else { 
        '<i class="fas fa-circle-xmark" style="color: #dc3545;"></i>' 
    }
    
    $html += @"
              <tr class="$rowClass">
                <td>$($service.Name)</td>
                <td>$($service.DisplayName)</td>
                <td>$statusIcon $($service.Status)</td>
                <td>$($service.StartType)</td>
              </tr>
"@
}

$html += @"
            </tbody>
          </table>
        </div>
      </div>
    </div>
    
  </div>
</div>
"@
#endregion

#region Set WYSIWYG Field
Set-NinjaProperty -Name "ServiceDashboard" -Value $html -Type "WYSIWYG"
Write-Output "Service dashboard updated successfully"
exit 0
#endregion
```

### Best Practices for WYSIWYG Content

1. **Use Bootstrap Grid:** Leverage Bootstrap's responsive grid system for layouts that work across devices
2. **Meaningful Icons:** Use Font Awesome icons to provide visual context (server, database, security, etc.)
3. **Consistent Styling:** Apply NinjaOne CSS classes for consistent look and feel
4. **Status Indicators:** Use color-coded table rows and info cards to highlight status
5. **Responsive Design:** Use Bootstrap breakpoint classes to ensure content adapts to different screen sizes
6. **Character Limits:** Be mindful of the 200,000 character limit and 10,000 auto-collapse threshold
7. **Sanitize User Input:** Always escape special HTML characters when including user-supplied data
8. **Performance:** Keep WYSIWYG content concise; use charts for summaries rather than large tables
9. **Piped Data:** Use `Ninja-Property-Set-Piped` for large HTML content to avoid command-line length limits
10. **Test Complexity:** Test HTML rendering in NinjaOne before deploying to production

### Setting WYSIWYG via PowerShell

```powershell
# Direct assignment (for shorter content)
Set-NinjaProperty -Name "Report" -Value $htmlContent -Type "WYSIWYG"

# Piped content (recommended for longer content)
$htmlContent | Ninja-Property-Set-Piped "Report"

# Via CLI with piped data
$htmlContent | & "$env:NINJARMMCLI" set --stdin "Report"
```

## Best Practices Summary

1. **Always validate script variables** - Check for empty strings and convert types explicitly
2. **Use NinjaOne environment variables** - Leverage organization context from `$env:NINJA_*` variables
3. **Implement proper exit codes** - Return 0 for success, non-zero for failures
4. **Use Write-Output for results** - Script output is captured in NinjaOne activity log
5. **Document script variables** - Clearly document expected types and defaults in script header
6. **Handle type conversions** - Create helper functions for consistent type conversion
7. **Provide meaningful output** - Use Write-Output for results visible in NinjaOne dashboard
8. **Test with empty values** - Ensure scripts handle empty (non-mandatory) variables gracefully
9. **Follow PowerShell guidelines** - Adhere to standard PowerShell cmdlet development practices
10. **Consider multi-tenancy** - Use organization/location variables for context-aware operations
11. **Use enhanced PowerShell cmdlets** - Prefer `Get-NinjaProperty` and `Set-NinjaProperty` over legacy commands for better type handling
12. **Secure field protection** - Only access secure fields during automation execution; never echo secure values
13. **Documentation organization** - Use documentation templates for structured, multi-device configuration data
14. **Custom field validation** - Implement proper validation for custom field types (email format, IP addresses, phone numbers)
15. **Unicode support** - Both PowerShell module and CLI support full Unicode including emojis
16. **Use ninjarmm-cli correctly** - Reference via `%NINJARMMCLI%` on Windows or `$NINJA_DATA_PATH/ninjarmm-cli` on Linux/macOS
17. **Handle automation-only fields** - Secure fields are only accessible during automation execution, not via manual script runs
18. **Type specification matters** - Always specify type when using `Get-NinjaProperty` and `Set-NinjaProperty` for dropdown/multiselect fields to get friendly names instead of GUIDs
19. **Template vs document fields** - Use appropriate commands for single-document templates vs multi-document templates
20. **Pipeline support for custom fields** - Only fields with at least one filled value are accessible via CLI/PowerShell module
21. **WYSIWYG content structure** - Use Bootstrap 5 grid system and NinjaOne CSS classes for consistent, responsive reporting
22. **Chart visualization** - Leverage Charts.css for data visualization in reports and dashboards
23. **HTML allowlist compliance** - Only use approved HTML elements and inline styles in WYSIWYG fields
24. **Icon library usage** - Use Font Awesome 6 (free) icons to enhance visual communication in reports
25. **Responsive reporting** - Design WYSIWYG content with mobile and tablet viewing in mind using Bootstrap breakpoints
