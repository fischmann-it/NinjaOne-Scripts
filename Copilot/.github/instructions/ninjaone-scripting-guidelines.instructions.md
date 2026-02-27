---
applyTo: '**/*.ps1,**/*.psm1'
description: 'NinjaOne RMM platform-specific PowerShell scripting guidelines for automation scripts, ensuring proper handling of environment variables, script variables, and platform integration.'
---

# NinjaOne PowerShell Scripting Guidelines

This guide provides NinjaOne RMM platform-specific instructions for GitHub Copilot to generate scripts that work seamlessly with the NinjaOne agent environment. These guidelines extend the general PowerShell cmdlet development guidelines with NinjaOne-specific patterns.

## Related Skills

This instruction set works with the following specialized skill files:

- **ninjaone-api** - REST API v2 for automation, integration, and data retrieval via HTTP requests
- **ninjaone-environment-variables** - NinjaOne agent environment variables and organization context
- **ninjaone-script-variables** - Script variables, preset parameters, and type conversion
- **ninjaone-custom-fields** - Custom fields access via PowerShell module (Get-NinjaProperty, Set-NinjaProperty)
- **ninjaone-cli** - ninjarmm-cli tool usage and legacy PowerShell commands
- **ninjaone-wysiwyg** - WYSIWYG fields, HTML formatting, Bootstrap 5, Charts.css, and visual reporting
- **ninjaone-tags** - Device tagging operations via PowerShell cmdlets and CLI for classification and filtering

For detailed information on each topic, reference the corresponding skill in `.github/skills/copilot/`.

## Core NinjaOne Concepts

### Platform Overview

NinjaOne RMM provides three primary mechanisms for script configuration:

1. **Environment Variables** (`$env:NINJA_*`) - Agent-provided context (organization, location, paths)
2. **Script Variables** (`$env:VariableName`) - User-defined parameters converted to environment variables
3. **Custom Fields** - Persistent device and organization data accessed via PowerShell module or CLI

### Standard Script Structure

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
14. **Custom field validation** - Implement proper validation for all custom field types (email format, IP addresses, phone numbers)
15. **Unicode support** - Both PowerShell module and CLI support full Unicode including emojis
16. **Reference related skills** - When using tags, custom fields, or API operations, reference the corresponding skill files for detailed patterns and examples
