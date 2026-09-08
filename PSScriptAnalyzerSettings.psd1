# PSScriptAnalyzer settings for the PowerShell in ad/scripts.
#
#   pwsh -c "Invoke-ScriptAnalyzer -Path rendered/ad/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1"
#
# Analyse the RENDERED .ps1 files, not the .tmpl sources - a template is not
# valid PowerShell until bootstrap.py has substituted the config values.
@{
    ExcludeRules = @(
        # These scripts are operator-facing: a human runs one by hand and reads
        # what it did. Write-Host is the correct channel for that - it is
        # progress narration, not data on the pipeline, and callers are never
        # meant to capture it. Write-Output here would corrupt the output of any
        # function that returned a value, and Write-Information is invisible by
        # default. The existing New-AdcsCesGmsa.ps1 established this.
        'PSAvoidUsingWriteHost'
    )
}
