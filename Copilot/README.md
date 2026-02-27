# NinjaOne Copilot

This folder contains NinjaOne Copilot configurations and scripts for setting up GitHub Copilot with custom instructions and Skills.

## Overview

The NinjaOne Copilot folder is designed to help users configure GitHub Copilot with custom instructions and Skills that are specific to NinjaOne RMM scripting and automation. These files extend GitHub Copilot's capabilities with NinjaOne-specific guidance.

## .github Folder Structure

The `.github` folder stores configuration files for GitHub Copilot:

- **`.github/instructions/`** - Contains custom instruction files that guide Copilot behavior
  - Instructions are applied to specific file types via the `applyTo` field
  - Example: `ninjaone-scripting-guidelines.instructions.md` applies to PowerShell scripts

- **`.github/skills/copilot/`** - Contains skill files that provide detailed reference information
  - Skills contain specialized knowledge about NinjaOne APIs, environment variables, and features
  - Referenced by instructions for modular, maintainable guidance

## Getting Started with GitHub Copilot

### Step 1: Enable Copilot Instructions in Your Editor

**Visual Studio Code:**
1. Install the GitHub Copilot extension (if not already installed)
2. GitHub Copilot will automatically detect `.github/instructions/` files in your repository
3. Instructions are applied based on file type matching in the `applyTo` field

**Other Editors:**
- Ensure you have GitHub Copilot extension installed
- Check your editor's documentation for Copilot instructions support

### Step 2: Add Instructions and Skills to Your Repository

1. Copy the `.github/instructions/` directory from this repository to your own
2. Copy the `.github/skills/copilot/` directory to your repository
3. Customize instructions and skills as needed for your team's requirements
4. Commit and push to your repository

### Step 3: Configure Your Copilot Settings

1. Open Copilot settings in your editor
2. Point to your repository's `.github` folder
3. Enable custom instructions for your workspace
4. Restart your editor or reload your workspace

## Available Instructions and Skills

- **ninjaone-scripting-guidelines** - PowerShell scripting guidelines specific to NinjaOne RMM
  - References related skills for NinjaOne APIs, environment variables, custom fields, and more

## Tips for Using Copilot with NinjaOne

- Reference the instruction files when writing NinjaOne automation scripts
- Use Copilot's chat or inline suggestions to generate script snippets
- Review generated code against the NinjaOne guidelines before deployment
- Update instructions and skills as NinjaOne platform features evolve

For more information on GitHub Copilot instructions, refer to the [GitHub Copilot documentation](https://github.com/features/copilot).
