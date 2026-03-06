---
name: ninjaone-cli
description: Use when code uses ninjarmm-cli, %NINJARMMCLI%, Ninja-Property-Get, Ninja-Property-Set, Get-NinjaProperty, Set-NinjaProperty, or user asks about NinjaOne CLI commands, legacy PowerShell commands, or documentation template access.
---

# NinjaOne CLI Tool

The `ninjarmm-cli` executable is automatically deployed by the NinjaOne agent and provides command-line access to custom fields. It works alongside legacy PowerShell commands for backward compatibility.

## When to Use This Skill

- Access custom fields from Batch or Shell scripts
- Work directly with dropdown/multi-select GUIDs instead of friendly names
- Pipe large content to custom fields (e.g., command output to MultiLine fields)
- Use legacy PowerShell commands in existing scripts
- Manage documentation templates from command line
- Clear custom field values (set to NULL)
- List available options for dropdown and multi-select fields

## Prerequisites

- **CLI Location:** Automatically deployed with NinjaOne agent
  - Windows: `C:\ProgramData\NinjaRMMAgent\ninjarmm-cli.exe` (`%NINJARMMCLI%`)
  - macOS: `/Applications/NinjaRMMAgent/programdata/ninjarmm-cli`
  - Linux: `/opt/NinjaRMMAgent/programdata/ninjarmm-cli` (prefix with `./`)
- **Permissions:** Run as SYSTEM or with adjusted permissions
- **PowerShell Support:** Versions 1 and 2 not supported
- **Field Access:** Only fields with at least one value are accessible
- **Unicode:** Full Unicode support; use `--direct-out` for stdout if needed

## Related Skills

- [ninjaone-custom-fields](../ninjaone-custom-fields/SKILL.md) - Prefer PowerShell module for automatic type handling and friendly names
- [ninjaone-wysiwyg](../ninjaone-wysiwyg/SKILL.md) - HTML formatting for WYSIWYG fields (read-only via CLI)
- [ninjaone-tags](../ninjaone-tags/SKILL.md) - CLI tag operations (tag-get, tag-set, tag-clear)
- [ninjaone-environment-variables](../ninjaone-environment-variables/SKILL.md) - Use $NINJA_DATA_PATH for CLI location on Linux/macOS

## Basic CLI Syntax

```batch
# Windows - Get field value
%NINJARMMCLI% get FieldName

# Windows - Set field value
%NINJARMMCLI% set FieldName "value"

# Windows - List field options (dropdown/multiselect)
%NINJARMMCLI% options FieldName

# Windows - Clear field value
%NINJARMMCLI% clear FieldName

# Linux/macOS - Get field value
./ninjarmm-cli get FieldName

# Linux/macOS - Set field value
./ninjarmm-cli set FieldName "value"
```

## NinjaOne PowerShell Module

When you install the NinjaOne agent, NinjaOne deploys and loads a custom PowerShell module for interacting with custom fields. This module provides enhanced cmdlets that automatically handle type conversion and friendly name resolution.

### Get-NinjaProperty

The `Get-NinjaProperty` command is an evolution of the original `Ninja-Property-Get` command. It retrieves and converts a Ninja custom field value based on the specified field name and type.

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

**Key Features:**
- Converts raw values to appropriate PowerShell objects based on type
- Returns user-friendly values for dropdowns/multi-selects (not GUIDs)
- Handles documentation fields when `DocumentName` is provided
- Full Unicode support including emojis

**Examples:**
```powershell
# WITHOUT type specified - Dropdown fields will return a GUID
Get-NinjaProperty -Name "Environment"
# Output: 74a6ffda-708e-435a-86e3-40b67c4f981a

# WITH type specified - Dropdown fields will return a friendly name, this is preferred.
Get-NinjaProperty -Name "Environment" -Type "Dropdown"
# Output: Production

# Get date field with automatic conversion
$maintenanceDate = Get-NinjaProperty -Name "NextMaintenance" -Type "Date"

# Get checkbox field as boolean
$isEnabled = Get-NinjaProperty -Name "FeatureEnabled" -Type "Checkbox"

# Get documentation field
$serverIP = Get-NinjaProperty -Name "IPAddress" -Type "IP Address" -DocumentName "Server Config"
```

### Set-NinjaProperty

The `Set-NinjaProperty` command is an evolution of the original `Ninja-Property-Set` command. It sets custom field values with automatic type conversion.

**Syntax:**
```powershell
Set-NinjaProperty [-Name] <String> [-Value] <Object> [[-Type] <String>] [[-DocumentName] <String>] [<CommonParameters>]
```

**Supported Types:**
- Checkbox, Date, Date or Date Time, DateTime, Decimal
- Dropdown, Email, Integer, IP Address
- MultiLine, MultiSelect
- Phone, Secure, Text, Time, URL, WYSIWYG

**Key Features:**
- Converts provided values to the appropriate format for the field type
- Accepts friendly names for dropdowns/multi-selects (not GUIDs)
- Converts DateTime objects to Unix epoch timestamps automatically
- Full Unicode support including emojis

**Examples:**
```powershell
# WITHOUT type specified - requires GUID
Set-NinjaProperty -Name "Environment" -Value "74a6ffda-708e-435a-86e3-40b67c4f981a"

# WITH type specified - accepts friendly name
Set-NinjaProperty -Name "Environment" -Value "Production" -Type "Dropdown"

# Set date field with DateTime object
Set-NinjaProperty -Name "NextMaintenance" -Value (Get-Date).AddDays(30) -Type "Date"

# Set checkbox field with boolean
Set-NinjaProperty -Name "FeatureEnabled" -Value $true -Type "Checkbox"

# Set secure field
Set-NinjaProperty -Name "APIKey" -Value "secret-key-value" -Type "Secure"

# Set multi-select field with friendly names
Set-NinjaProperty -Name "InstalledFeatures" -Value @("Feature1", "Feature2") -Type "MultiSelect"

# Set documentation field
Set-NinjaProperty -Name "IPAddress" -Value "192.168.1.100" -Type "IP Address" -DocumentName "PROD-WEB-01"
```

**Getting Help:**
Access detailed help and examples by running:

```powershell
Get-Help Get-NinjaProperty -Full
Get-Help Set-NinjaProperty -Full
```

## Legacy PowerShell Commands

The original NinjaOne PowerShell commands still function as originally designed:

```powershell
# Global and Role fields
Ninja-Property-Get $AttributeName
Ninja-Property-Set $AttributeName $Value
Ninja-Property-Options $AttributeName
Ninja-Property-Clear $AttributeName

# Documentation fields
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

## Field Type Examples

### Checkbox Fields

**CLI:**
```batch
REM Get (returns true/false or 1/0)
%NINJARMMCLI% get IsEnabled

REM Set
%NINJARMMCLI% set IsEnabled true
%NINJARMMCLI% set IsEnabled 1
```

**PowerShell:**
```powershell
# Get value for checkbox field
Ninja-Property-Get globalcheckbox
# Output: 0

# Set boolean value
Ninja-Property-Set globalcheckbox 0
Ninja-Property-Set globalcheckbox 1
Ninja-Property-Set globalcheckbox true
Ninja-Property-Set globalcheckbox false
```

### Date Fields

**CLI:**
```batch
REM Get (returns epoch seconds)
%NINJARMMCLI% get MaintenanceDate

REM Set with ISO format
%NINJARMMCLI% set MaintenanceDate 2024-12-31

REM Set with epoch seconds
%NINJARMMCLI% set MaintenanceDate 1735689600
```

**PowerShell:**
```powershell
# Get value for date field
Ninja-Property-Get globaldate
# Output: 456

# Set value to date field
Ninja-Property-Set globaldate 1626875470000

# Set with ISO format
Ninja-Property-Set testdate 2021-10-15
# Output: 1634256000
```

### DateTime Fields

**CLI:**
```batch
REM Get (returns epoch seconds)
%NINJARMMCLI% get ScheduledTime

REM Set with ISO format
%NINJARMMCLI% set ScheduledTime 2024-01-15T14:30:00

REM Set with epoch seconds
%NINJARMMCLI% set ScheduledTime 1705330200
```

**PowerShell:**
```powershell
# Get value for date-time field
Ninja-Property-Get globaldatetime
# Output: 1626875470000

# Set value to date-time field
Ninja-Property-Set globaldatetime 1626875470000

# Set with ISO format
Ninja-Property-Set testdatetime 2021-10-15T00:00:00
# Output: 1634256000
```

### Decimal Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get DiskThreshold

REM Set (range: -9999999.999999 to 9999999.999999)
%NINJARMMCLI% set DiskThreshold 95.5
```

**PowerShell:**
```powershell
# Get value for decimal field
Ninja-Property-Get globaldecimal
# Output: 123.456

# Set value to decimal field
Ninja-Property-Set typedecimal 1
Ninja-Property-Set typedecimal 1.23
Ninja-Property-Set typedecimal 1.2345678901234567890
# Output: 1.234567 (truncated to max precision)

Ninja-Property-Set typedecimal 1234567890.1234567890
# Output: 1234567890.123457
```

### Dropdown Fields

**CLI:**
```batch
REM Get (returns GUID)
%NINJARMMCLI% get Environment

REM List options
%NINJARMMCLI% options Environment

REM Set with GUID
%NINJARMMCLI% set Environment f1ba449c-fd34-49df-b878-af3877180d17
```

**PowerShell:**
```powershell
# List options for dropdown field
Ninja-Property-Options globaldropdown
# Output:
# 333f541e-747e-4a1e-a2e2-a82c1c2f2008=Option2
# 74a6ffda-708e-435a-86e3-40b67c4f981a=Option1
# f1ba449c-fd34-49df-b878-af3877180d17=Option3

# Find option GUID by option name
Ninja-Property-Get globaldropdown | grep "Option1" | awk -F= '{print $1}'
# Output: 74a6ffda-708e-435a-86e3-40b67c4f981a

# Get value for dropdown field
Ninja-Property-Get globaldropdown
# Output: 74a6ffda-708e-435a-86e3-40b67c4f981a

# Set value to dropdown field
Ninja-Property-Set globaldropdown f1ba449c-fd34-49df-b878-af3877180d17
```

### Email Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get AdminEmail

REM Set
%NINJARMMCLI% set AdminEmail admin@example.com
```

**PowerShell:**
```powershell
# Get stored value
Ninja-Property-Get typeemail
# Output: test@test.test

# Set correct values
Ninja-Property-Set typeemail test@test.test
Ninja-Property-Set typeemail test@test123.test.othertest

# Set wrong values (will error)
Ninja-Property-Set typeemail test@test.test123
# Output: Error: Wrong value format / type ...
```

### Integer Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get ServicePort

REM Set (range: -2147483648 to 2147483647)
%NINJARMMCLI% set ServicePort 8080
```

**PowerShell:**
```powershell
# Get value for integer field
Ninja-Property-Get globalinteger
# Output: 456

# Set value to integer field
Ninja-Property-Set globalinteger 123
```

### IP Address Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get ServerIP

REM Set (IPv4 or IPv6)
%NINJARMMCLI% set ServerIP 192.168.1.100
```

**PowerShell:**
```powershell
# Get stored value
Ninja-Property-Get typeipaddress
# Output: 192.168.1.100

# Set correct values
Ninja-Property-Set typeipaddress 255.255.255.255
Ninja-Property-Set typeipaddress 0.0.0.0

# Set wrong values (will error)
Ninja-Property-Set typeipaddress 192.168.1.
# Output: Error: Wrong value format / type ...

Ninja-Property-Set typeipaddress 255.255.255.256
# Output: Error: Wrong value format / type ...

Ninja-Property-Set typeipaddress 0.-1.0.0
# Output: Error: Wrong value format / type ...
```

### MultiLine Text Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get Notes

REM Set with piped data
dir | %NINJARMMCLI% set --stdin Notes

REM Set with line breaks (use 'n for breaks)
%NINJARMMCLI% set Notes "Line 1'nLine 2'nLine 3"
```

**PowerShell:**
```powershell
# Get text field
Ninja-Property-Get globaltext
# Output: sampletext1

# Set text field (limited to 10,000 characters)
Ninja-Property-Set globaltext sampletext2

# Set with line breaks using backtick-n
Ninja-Property-Set multiline "line with spaces`nline2`nline3`nfinalval"
# Displays as:
# line with spaces
# line2
# line3
# finalval
```

### MultiSelect Fields

**CLI:**
```batch
REM Get (returns comma-separated GUIDs)
%NINJARMMCLI% get EnabledFeatures

REM List options
%NINJARMMCLI% options EnabledFeatures

REM Set with GUIDs (comma-separated)
%NINJARMMCLI% set EnabledFeatures "guid1,guid2,guid3"
```

**PowerShell:**
```powershell
# List options for multi-select field
Ninja-Property-Options globalmultiselect
# Output:
# 333f541e-747e-4a1e-a2e2-a82c1c2f2008=Option2
# 74a6ffda-708e-435a-86e3-40b67c4f981a=Option1
# f1ba449c-fd34-49df-b878-af3877180d17=Option3

# Find option GUID by option name
Ninja-Property-Options globalmultiselect | grep "Option 1" | awk -F= '{print $1}'
# Output: 74a6ffda-708e-435a-86e3-40b67c4f981a

# Set multiple values (comma-separated)
Ninja-Property-Set globalmultiselect 333f541e-747e-4a1e-a2e2-a82c1c2f2008,74a6ffda-708e-435a-86e3-40b67c4f981a

# Get values for multi-select field
Ninja-Property-Get globalmultiselect
# Output: 333f541e-747e-4a1e-a2e2-a82c1c2f2008,74a6ffda-708e-435a-86e3-40b67c4f981a
```

### Phone Number Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get SupportPhone

REM Set (E.164 format, up to 17 characters)
%NINJARMMCLI% set SupportPhone +12345678901
```

**PowerShell:**
```powershell
# Get stored value
Ninja-Property-Get typephone
# Output: +1234567890

# Set correct values (E.164 format, up to 17 characters)
Ninja-Property-Set typephone +77013273916
Ninja-Property-Set typephone 123456789012344567
Ninja-Property-Set typephone +123456789012344567

# Set wrong values (will error)
Ninja-Property-Set typephone 14953273916qwerty
# Output: Error: Wrong value format / type ...

Ninja-Property-Set typephone 1234567890123445678  # too long
# Output: Error: Wrong value format / type ...

Ninja-Property-Set typephone ++123456789012344567
# Output: Error: Wrong value format / type ...
```

### Secure Fields

**CLI:**
```batch
REM Get (only in automations)
%NINJARMMCLI% get APIKey

REM Set (disable echo to prevent output)
@echo off
%NINJARMMCLI% set APIKey secret-value
@echo on
```

**PowerShell:**
```powershell
# Get secure field (only in automations)
Ninja-Property-Get globalsecure
# Output: sampletext1

# Set secure field
Ninja-Property-Set globalsecure sampletext2
```

**Security Best Practices:**

For Windows (Batch):
```batch
@echo off
%NINJARMMCLI% set APIKey %SecureValue%
@echo on
```

For Unix (Shell):
```bash
# Do NOT use set -x before secure operations
# set -x  # AVOID THIS
./ninjarmm-cli set APIKey "$SECRET_VALUE"
```

### Text Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get ServerName

REM Set (up to 10,000 characters)
%NINJARMMCLI% set ServerName PROD-WEB-01
```

**PowerShell:**
```powershell
# Get text field
Ninja-Property-Get globaltext
# Output: sampletext1

# Set text field
Ninja-Property-Set globaltext sampletext2
```

### Time Fields

**CLI:**
```batch
REM Get (returns seconds)
%NINJARMMCLI% get BackupTime

REM Set with ISO format
%NINJARMMCLI% set BackupTime 02:00:00

REM Set with seconds (7200 = 2 hours)
%NINJARMMCLI% set BackupTime 7200
```

**PowerShell:**
```powershell
# Get value for time field
Ninja-Property-Get globaldatetime
# Output: 120

# Set value to time field (seconds or ISO format)
Ninja-Property-Set globaldatetime 3600

# Set with ISO format
Ninja-Property-Set testdatetime 00:00:00
# Output: 0
```

### URL Fields

**CLI:**
```batch
REM Get
%NINJARMMCLI% get DashboardURL

REM Set (must start with https://, max 200 characters)
%NINJARMMCLI% set DashboardURL https://dashboard.example.com
```

**PowerShell:**
```powershell
# Get URL field
Ninja-Property-Get url
# Output: https://www.google.com

# Set URL field (must start with https://, max 200 characters)
Ninja-Property-Set url https://www.ninjarmm.com
```

## Documentation Template Commands

### List Templates

**CLI:**
```batch
REM List all templates
%NINJARMMCLI% templates

REM List templates with IDs
%NINJARMMCLI% templates --ids
```

**PowerShell:**
```powershell
# Get templates list
Ninja-Property-Docs-Templates
# Output:
# 1=template 1
# 2=template 2
```

### List Documents

**CLI:**
```batch
REM List documents by template ID
%NINJARMMCLI% documents 1

REM List documents by template name
%NINJARMMCLI% documents "Server Config"
```

**PowerShell:**
```powershell
# Get documents list by template ID
Ninja-Property-Docs-Names 2
# Output: 16=template 2

# Get documents list by template name
Ninja-Property-Docs-Names "template 2"
# Output: 16=template 2
```

### Get Documentation Field

**CLI:**
```batch
REM Get from multi-document template
%NINJARMMCLI% get "Server Config" "PROD-WEB-01" IPAddress

REM Get from single-document template
%NINJARMMCLI% get "Network Config" Gateway
```

**PowerShell:**
```powershell
# Get field value from multi-document template
Ninja-Property-Docs-Get "template 2" "template 2" fieldname
# Output: This is the field value

# Get field from single-document template
Ninja-Property-Docs-Get-Single "templateName" "fieldName"
```

### Set Documentation Field

**CLI:**
```batch
REM Set in multi-document template
%NINJARMMCLI% org-set "Server Config" "PROD-WEB-01" IPAddress "192.168.1.100"

REM Set in single-document template
%NINJARMMCLI% org-set "Network Config" Gateway "192.168.1.1"
```

**PowerShell:**
```powershell
# Set attribute to multi-document template
Ninja-Property-Docs-Set 2 "ExampleDoc" ExampleTextField "SampleText1"

# Set attribute to single-document template
Ninja-Property-Docs-Set-Single "template 2" ExampleTextField "sampletext1"
```

### Clear Documentation Field

**CLI:**
```batch
REM Clear field (sets to NULL)
%NINJARMMCLI% org-clear "Server Config" "PROD-WEB-01" IPAddress

REM Clear in single-document template
%NINJARMMCLI% org-clear "Network Config" Gateway
```

**PowerShell:**
```powershell
# Clear value in multi-document template (sets to NULL)
Ninja-Property-Docs-Clear "template 2" "ExampleDoc" ExampleTextField

# Clear value in single-document template (sets to NULL)
Ninja-Property-Docs-Clear-Single "template 2" ExampleTextField
```

### Get Options for Documentation Field

**CLI:**
```batch
REM Get options in multi-document template
%NINJARMMCLI% org-options "Server Config" "PROD-WEB-01" Environment

REM Get options in single-document template
%NINJARMMCLI% org-options "Network Config" ConnectionType
```

**PowerShell:**
```powershell
# Get list of valid values for multi-document template
Ninja-Property-Docs-Options "template 2" "ExampleDoc" ExampleTextField

# Get list of valid values for single-document template
Ninja-Property-Docs-Options-Single "template 2" ExampleTextField
```

## Complete Script Examples

### Batch Script Example

```batch
@echo off
REM filepath: update-fields.bat
REM Updates custom fields using ninjarmm-cli

REM Get current environment
for /f "delims=" %%i in ('%NINJARMMCLI% get Environment') do set ENVIRONMENT=%%i
echo Current environment: %ENVIRONMENT%

REM Set maintenance mode
%NINJARMMCLI% set MaintenanceEnabled true
if %ERRORLEVEL% EQU 0 (
    echo Maintenance mode enabled
) else (
    echo Failed to enable maintenance mode
    exit /b 1
)

REM Update last maintenance date to today
%NINJARMMCLI% set LastMaintenanceDate %DATE:~-4%-%DATE:~4,2%-%DATE:~7,2%
echo Updated last maintenance date

REM Update documentation field
%NINJARMMCLI% org-set "Server Config" "%COMPUTERNAME%" Status "Maintenance"
echo Updated documentation status

echo Custom fields updated successfully
exit /b 0
```

### PowerShell Script Example

```powershell
<#
.SYNOPSIS
    Updates custom fields using legacy PowerShell commands.
#>

[CmdletBinding()]
param()

# Get current environment
$environment = Ninja-Property-Get Environment
Write-Output "Current environment: $environment"

# Set maintenance mode
Ninja-Property-Set MaintenanceEnabled true
Write-Output "Maintenance mode enabled"

# Update last maintenance date
$today = Get-Date -Format "yyyy-MM-dd"
Ninja-Property-Set LastMaintenanceDate $today
Write-Output "Updated last maintenance date: $today"

# Update documentation field
$computerName = $env:COMPUTERNAME
Ninja-Property-Docs-Set-Single "Server Config" Status "Maintenance"
Write-Output "Updated documentation status"

Write-Output "Custom fields updated successfully"
exit 0
```

## CLI Help Output

```
ninjarmm-cli - CLI tool to access and manage NinjaRMM Agent Custom Fields.

Usage:
  help - show this text

Global and Role fields:
  get <attribute name> - get value of the attribute
  set <attribute name> <value> - set value to attribute
     --stdin - optional modifier to use piped data
  options <attribute name> - get list of valid values
  clear <attribute name> - clear value (sets to NULL)

Documentation fields:
  templates - get list of templates
     --ids, --names - optional modifiers
  documents "<template id/name>" - get list of documents
     --ids, --names - optional modifiers
  get "<template id/name>" "<document name>" <attribute name>
  get "<single template name>" <attribute name>
  org-set "<template id/name>" "<document name>" <attribute> "<value>"
  org-set "<single template name>" <attribute> "<value>"
  org-clear "<template id/name>" "<document name>" <attribute>
  org-clear "<single template name>" <attribute>
  org-options "<template id/name>" "<document name>" <attribute>
  org-options "<single template name>" <attribute>

Exit codes:
  0 - Success
  1 - Error

To read exit code:
  Windows: echo %ERRORLEVEL%
  Unix: echo $?
```

## CLI Best Practices

1. **Use enhanced module commands** - Prefer `Get-NinjaProperty`/`Set-NinjaProperty` over legacy commands for automatic type handling
2. **Specify field types** - Always use `-Type` parameter to get/set friendly values instead of GUIDs
3. **Use environment variable** - Reference via `%NINJARMMCLI%` on Windows or `$NINJA_DATA_PATH/ninjarmm-cli` on Linux/macOS
4. **Secure field protection** - Disable echo before setting secure values (@echo off/@echo on)
5. **Error handling** - Check `%ERRORLEVEL%` (Windows) or `$?` (Unix) after CLI commands
6. **Piped data** - Use `--stdin` for large content: `dir | %NINJARMMCLI% set --stdin Notes`
7. **Unicode support** - Use `--direct-out` for stdout if needed (may lose Unicode support)
8. **Field access** - Only fields with at least one value are accessible via CLI
9. **Automation only** - Secure fields only accessible during automation execution
10. **Permissions** - Run scripts as SYSTEM or adjust permissions for protected folders
11. **Linux execution** - Always prefix with `./` (e.g., `./ninjarmm-cli get fieldname`)
12. **Quote requirements** - Use quotes for template/document names with spaces
