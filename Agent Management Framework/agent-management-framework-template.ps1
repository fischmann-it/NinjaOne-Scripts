# Set environment variables
$env:agentDisplayName = '' # Friendly name for the agent, used in logging and messages. Not required to match any actual service or product name, but should be descriptive enough for users to understand which agent this script is managing.
$env:agentServiceName = '' # The actual name of the service as it appears in Windows Services. This is used to check the status of the agent and verify installation/uninstallation.
$env:deploymentBehaviorCustomFieldName = '' # The name of the custom field in NinjaOne that defines the deployment behavior. This is used to determine the preferred action for the agent deployment.
# $agentInstallToken = Get-NinjaProperty -Name 'agentDeploymentToken' -Type Text # Optional: If you want to pull the installation token from a NinjaOne custom field, you can uncomment this line and set the name of the custom field accordingly.

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

<# # This section can be uncommented to exit when required variables are not set, or to pull variables from NinjaOne Custom Fields.
if ($null -eq $agentInstallToken) {
    Write-Error 'Deployment token not found in NinjaOne Org Custom Field. Please set the token and re-run the script.'
    exit 1
}
#>

#region Check Deployment Behavior
$deploymentBehavior = Get-NinjaProperty -Name $env:deploymentBehaviorCustomFieldName -Type Dropdown
if ($null -ne $deploymentBehavior) {
    $preferredAction = $deploymentBehavior
    Write-Host "Deployment behavior set to $preferredAction."
} else {
    Write-Host 'No deployment behavior set.'
    # We don't exit here in case user override is detected in the Manual Usage section.
}
#endregion

#region Get Agent Status
function Get-AgentStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$serviceName
    )
    try {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Host "$serviceName is not installed."
            return 'NotInstalled'
        }
        if ($service.Status -eq 'Running') {
            Write-Host "$serviceName is running."
            return 'Running'
        } elseif ($service.status -eq 'Stopped') {
            Write-Host "$serviceName is present but not running."
            return 'PresentButNotRunning'
        }
    } catch {
        Write-Host "$serviceName is not installed."
        return 'NotInstalled'
    }
    return 'Unknown'
}
#endregion

#region Agent Deployment Functions
function Install-Agent {
    try {
        # -----------  INSTALL LOGIC GOES HERE  -----------

        # Verify installation
        $agentStatus = Get-AgentStatus -serviceName $env:agentServiceName
        if ($agentStatus -eq 'Running') {
            Write-Host "$env:agentDisplayName Agent installed and running successfully."
        } else {
            throw "Installation completed but agent is not running. Current status: $agentStatus"
        }
    } catch {
        Write-Error "Failed to install the $env:agentDisplayName Agent: $_"
        exit 1
    }
}

function Uninstall-Agent {
    try {
        # -----------  UNINSTALL LOGIC GOES HERE  -----------

        # Verify uninstallation
        $agentStatus = Get-AgentStatus -serviceName $env:agentServiceName
        if ($agentStatus -eq 'NotInstalled') {
            Write-Host "$env:agentDisplayName Agent uninstalled successfully."
        } else {
            Write-Host "Uninstallation ran but the $env:agentServiceName service remains. Status: $agentStatus"
        }
    } catch {
        Write-Error "Failed to uninstall the Agent: $_"
        exit 1
    }
}

<# ONLY NEEDED IF UNINSTALL AND INSTALL STEPS ARE DIFFERENT. OTHERWISE, CAN JUST CALL Uninstall-Agent AND Install-Agent FUNCTIONS.
function Reinstall-Agent {
    try {
        # -----------  REINSTALL LOGIC GOES HERE  -----------
       

        # Verify installation
        $agentStatus = Get-AgentStatus -serviceName $env:agentServiceName
        if ($agentStatus -eq 'Running') {
            Write-Host "$env:agentDisplayName Agent installed and running successfully."
        } else {
            throw "Installation completed but agent is not running. Current status: $agentStatus"
        }
    } catch {
        Write-Error "Failed to install the $env:agentDisplayName Agent: $_"
        exit 1
    }
}#>

#endregion

#region Manual usage
if (@('Install', 'Uninstall', 'Reinstall', 'Uninstall And Prevent Reinstallation') -contains $env:manualOverride) {
    switch ($env:manualOverride) {
        'Install' {
            Install-Agent
        }
        'Uninstall' {
            Uninstall-Agent
        }
        'Reinstall' {
            Uninstall-Agent
            Install-Agent
            # Reinstall-Agent
        }
        'Uninstall And Prevent Reinstallation' {
            Uninstall-Agent
            Set-NinjaProperty -Name $env:deploymentBehaviorCustomFieldName -Value 'No Action' -Type Dropdown
            Write-Host "Set $env:deploymentBehaviorCustomFieldName to No Action."
        }
        default {
            Write-Host 'Manual override not accounted for.'
        }
    }
    exit 0
}
#endregion

#region Main Deployment Logic
$serviceStatus = Get-AgentStatus -serviceName $env:agentServiceName

switch ($preferredAction) {
    'Install' {
        if ($serviceStatus -ne 'Running') {
            Install-Agent
        } else {
            Write-Host "$env:agentDisplayName is already installed."
        }
    }
    'Uninstall' {
        if ($serviceStatus -ne 'NotInstalled') {
            Uninstall-Agent
            Get-AgentStatus -serviceName $env:agentServiceName
        } else {
            Write-Host "$env:agentDisplayName is not installed."   
        }
    }
    'No Action' {
        Write-Host "Set to No Action, no $env:agentDisplayName agent action will be taken."
    }
    default {
        Write-Host "No $env:agentDisplayName agent action will be taken."
    }
}
#endregion
