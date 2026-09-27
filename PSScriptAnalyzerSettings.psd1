# Lint settings for Invoke-ScriptAnalyzer (used by CI). These are standalone scripts, not a
# module, so module-style rules are off, along with rules that flag deliberate choices.
@{
    ExcludeRules = @(
        # Module conventions that don't fit a script's internal helpers.
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingPositionalParameters'
        # `pre` commands and $EDITOR are user-supplied command lines; running them is the point.
        'PSAvoidUsingInvokeExpression'
        # Empty catches are best-effort extras (toasts, console encoding) that must never fail a backup.
        'PSAvoidUsingEmptyCatchBlock'
        # Flags Write-Log from a PowerShell 6.1 compatibility list; neither 5.1 nor 7.x ships one.
        'PSAvoidOverwritingBuiltInCmdlets'
    )
}
