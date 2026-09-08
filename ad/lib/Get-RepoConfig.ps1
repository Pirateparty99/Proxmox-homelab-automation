<#
.SYNOPSIS
    Reads config.env and returns it as a hashtable, with the same derived values
    that lib/config.sh computes for the shell scripts.

.DESCRIPTION
    Dot-source this, then call Get-RepoConfig. Keeping one config file for both
    bash and PowerShell means the domain is defined in exactly one place.
#>

function Get-RepoConfig {
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $Path = Join-Path $repoRoot 'config.env'
    }
    if (-not (Test-Path $Path)) {
        throw "$Path not found. Copy config.env.example to config.env and edit it."
    }

    $cfg = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        $key   = $trimmed.Substring(0, $split).Trim()
        $value = $trimmed.Substring($split + 1).Trim() -replace '^["'']|["'']$', ''
        $cfg[$key] = $value
    }

    if (-not $cfg.AD_DOMAIN) { throw "AD_DOMAIN is not set in $Path" }

    # Same derivations as lib/config.sh - keep the two in step.
    if (-not $cfg.AD_REALM)     { $cfg.AD_REALM     = $cfg.AD_DOMAIN.ToUpper() }
    if (-not $cfg.AD_NETBIOS)   { $cfg.AD_NETBIOS   = $cfg.AD_DOMAIN.Split('.')[0].ToUpper() }
    if (-not $cfg.AD_DOMAIN_DN) { $cfg.AD_DOMAIN_DN = 'DC=' + ($cfg.AD_DOMAIN -replace '\.', ',DC=') }
    if (-not $cfg.ContainsKey('AD_BASE_OU')) { $cfg.AD_BASE_OU = 'OU=' + $cfg.AD_NETBIOS }
    if (-not $cfg.AD_BASE_DN) {
        $cfg.AD_BASE_DN = if ($cfg.AD_BASE_OU) {
            "$($cfg.AD_BASE_OU),$($cfg.AD_DOMAIN_DN)"
        } else {
            $cfg.AD_DOMAIN_DN
        }
    }
    if (-not $cfg.AD_GROUP_BASE_DN) { $cfg.AD_GROUP_BASE_DN = "OU=Groups,$($cfg.AD_BASE_DN)" }

    return $cfg
}
