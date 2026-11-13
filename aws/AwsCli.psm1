function Invoke-AwsCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$NotFound,
        [switch]$Raw
    )
    $output = & aws @Arguments --output json 2>&1
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        if ($NotFound -and $stderr -match $NotFound) {
            return $null
        }
        throw "aws $($Arguments[0..1] -join ' ') failed: $stderr"
    }
    if ($Raw -or [string]::IsNullOrWhiteSpace($stdout)) {
        return $stdout
    }
    $stdout | ConvertFrom-Json -Depth 64
}

Export-ModuleMember -Function Invoke-AwsCli
