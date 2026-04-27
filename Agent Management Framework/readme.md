## **Overview**

General approach is designed for consistent techniques, scripts, and monitors for managing MSP-sold agents, including (e.g. SentinelOne, DNSFilter, ArcticWolf, ConnectSecure, Huntress, etc...) This is not intended for client-specific applications.

Custom Fields to set desired behavior of the agent and input variable data required for agent installation, such as install tokens.

Policies are used to apply compound conditions that check the desired deployment behavior and initiate installation/uninstallation, as well as monitor agent service statuses.

A single Automation/Script is used to Install, Uninstall, Reinstall (when broken), and Uninstall and Prevent Reinstallation (set custom field override) - Script in this directory.

## **Critical Pieces**

## **Automation Library - Script**

- Create a new Script using the template in this directory.
- Name: <App Name> Agent Management
- Provide a description and categories according to *<your standards and guidelines>*
- Include the Software category at a minimum.
- Add a Script Variable
    - Type: Dropdown
    - Name: Manual Override
    - Option Values:
        - Install
        - Reinstall
        - Uninstall
        - Uninstall and Prevent Reinstallation
    - DO NOT MAKE MANDATORY - running without being set will automatically align with detected Deployment Behavior.
- Adjust the $env:agentDisplayName and $env:agentServiceName values to reflect the app
    - Display Name is purely for logging purposes
    - Service Name is the Windows Service Name, not Display Name.
        
- Adjust the $env:deploymentBehaviorCustomFieldName value to reflect the correct field.
- Retrieve any other required fields, such as installation tokens and variables at the top of the script using Get-NinjaProperty calls.
- Add the agent installation and uninstallation script logic within their respective functions.

## **Custom Fields**

- Deployment Behavior
    - Field Name/Label: App-Name Deployment Behavior
    - Type: Dropdown
    - NOT REQUIRED - allow to not be set
    - Inheritance: Org, Location, and Device in most cases.
    - Permissions:
        - Automations: READ/WRITE (Automations must be able to read this value to confirm what's set, must Write to self-exclude when manual run includes exclusion [explained further in script section])
        - API: READ (READ/WRITE in some cases)
        - Technician access: EDITABLE
    - Details: Please include any scripts/APIs that refer to this field (see *<your standards and guidelines>*) in the Description. Tooltip should explain that this field changes application deployment behavior.
    - Advanced settings: Create 3 options, "Install", "No Action" (Mark as Default), "Uninstall"
- Installation Tokens/Keys
    - For sensitive/privileged tokens or extremely long ones, use a Secure field. Secure fields not only mask the data and log access, but the masking reduces visual clutter on Custom Field screens. If the string is simple and not sensitive, use the Text field type.
    - Ensure they use a similar naming convention (e.g. <AppName> Token, <AppName> Key)
    - Scope them appropriately on the Inheritance screen, it is unlikely a company-wide install key will need to be overridden at the location or device level.
- Other Fields as Needed
    - Use a similar naming convention (e.g. \<AppName> Install Type, <AppName> Org ID, <Appname> Region)
    - Scope them appropriately on the inheritance screen.

## **Policies**

- Edit the  Policies for each device Type (Windows Server, Windows Workstation, Mac Workstation, etc...)
    
    Base
    
    - Client policies inherit from these base policies. ***<this may not be true in your enviroment, adjust as needed>***
- Create a Compound Condition for Installation.
    - Trigger when all conditions are met.
        - Custom Field: <App> Deployment Behavior - Equals - Install
        - Windows Service: <App service> - Any - Doesn't exist
            - Adjust as needed based on the agent, could also be Software Doesn't exist.
    - Automations: Select the agent management Script with no parameters/variables set.
    - Settings:
        - Naming convention: Agent Deployment: <App/Agent name>
        - Auto Reset when no longer met - Always Checked
        - Auto Reset After X hours - Completely clears the condition - use to automatically retry for installation failures.
        - Run every X hours - how often to re-evaluate the trigger conditions (if condition is still triggered, this will not rerun automations until cleared/reset)
        - Minimum uptime - 10 minutes or so.
    - Notifications - usually left unconfigured.
- Create a Compound Condition for Removal
    - Repeat same settings as Installation with the following adjustments
    - Name should be Agent Removal: <App/Agent Name>
    - Condition checks will be inverted (Deployment Behavior is Uninstall and Service/Software Does Exist)
- Agent monitoring Compound Conditions
    - Create additional compound conditions and automations as needed.
        - i.e. Deployment Behavior is set to Install and Service Exists but is Stopped > Run Automation "Start or Stop - Windows Service"

## **Groups (optional)**

- Create Device Groups for "Agent: Should be Installed" and "Agent Should be Removed"
- Base these on the custom field values.
- These are for automations/APIs/reporting.
