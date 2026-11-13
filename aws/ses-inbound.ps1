#Requires -Version 7.0
<#
.SYNOPSIS
Idempotently sets up SES inbound mail for the org's Route 53 domains: S3 storage, MX, SPF, DKIM, receipt rules and a forwarding Lambda.

.EXAMPLE
pwsh -File aws/ses-inbound.ps1 -ForwardTo owner@example.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Domains = @('goom.life', 'gideonogega.com', 'goomtech.com', 'blademasterx.com'),
    [hashtable]$HostedZoneIds = @{},
    [string[]]$Addresses,
    [string]$ForwardTo,
    [hashtable]$ForwardRules = @{},
    [string]$Bucket = 'goom-life-mail',
    [string[]]$ExpirePrefixes = @('goom.life/claude-test/'),
    [int]$ExpireDays = 30,
    [string]$RuleSetName = 'org-inbound',
    [string]$FunctionName = 'ses-inbound-forwarder',
    [string]$Region = 'us-east-1',
    [switch]$NoForward,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AwsCli.psm1') -Force

$script:DryRun = $false
$script:Notes = [System.Collections.Generic.List[string]]::new()
$script:SpfInclude = 'include:amazonses.com'

function Invoke-Aws {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$NotFound)
    Invoke-AwsCli -Arguments ($Arguments + @('--region', $Region)) -NotFound $NotFound
}

function Invoke-AwsChange {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Arguments,
        $Payload
    )
    $file = $null
    $label = if ($script:DryRun) { 'WHATIF' } else { 'CHANGE' }
    Write-Host "${label}: $Description"
    if ($null -ne $Payload) {
        $json = $Payload | ConvertTo-Json -Depth 32 -Compress
        Write-Host "        $json"
    }
    if ($script:DryRun) {
        return $null
    }
    if ($null -ne $Payload) {
        $file = New-TemporaryFile
        Set-Content -LiteralPath $file -Value $json -NoNewline -Encoding utf8NoBOM
        $Arguments = $Arguments | ForEach-Object { $_ -replace '^\{payload\}$', "file://$($file.FullName)" }
    }
    try {
        Invoke-Aws -Arguments $Arguments
    }
    finally {
        if ($file) { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    }
}

function Write-Unchanged([string]$Description) {
    Write-Host "OK: $Description"
}

function Add-Note([string]$Text) {
    $script:Notes.Add($Text)
}

function ConvertTo-CanonicalJson($Value) {
    function ConvertTo-SortedNode($Node) {
        if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return $Node }
        if ($Node -is [System.Collections.IDictionary]) {
            $sorted = [ordered]@{}
            foreach ($key in @($Node.Keys | Sort-Object)) { $sorted[$key] = ConvertTo-SortedNode $Node[$key] }
            return $sorted
        }
        if ($Node -is [System.Collections.IEnumerable]) {
            return , @($Node | ForEach-Object { ConvertTo-SortedNode $_ })
        }
        if ($Node.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) {
            $sorted = [ordered]@{}
            foreach ($name in @($Node.PSObject.Properties.Name | Sort-Object)) { $sorted[$name] = ConvertTo-SortedNode $Node.$name }
            return $sorted
        }
        return $Node
    }
    ConvertTo-SortedNode $Value | ConvertTo-Json -Depth 32 -Compress
}

function Test-SameJson($Left, $Right) {
    (ConvertTo-CanonicalJson $Left) -ceq (ConvertTo-CanonicalJson $Right)
}

function Get-DefaultAddress([string[]]$DomainList) {
    $list = @($DomainList | ForEach-Object { "support@$_" })
    if ($DomainList -contains 'goom.life') {
        $list += 'claude-test@goom.life'
    }
    $list
}

function Get-AddressPart([string]$Address) {
    if ($Address -notmatch '^(?<local>[a-z0-9._+-]+)@(?<domain>[a-z0-9.-]+\.[a-z]{2,})$') {
        throw "Invalid address: $Address"
    }
    [pscustomobject]@{ Local = $Matches.local; Domain = $Matches.domain; Prefix = "$($Matches.domain)/$($Matches.local)/" }
}

function Get-RuleName([string]$Address) {
    ($Address -replace '@', '-at-') -replace '[^a-z0-9-]', '-'
}

function Resolve-ForwardMap {
    param([string[]]$AddressList, [string]$Target, [hashtable]$Rules)
    $map = [ordered]@{}
    if ($Target) {
        foreach ($address in $AddressList | Where-Object { $_ -like 'support@*' }) { $map[$address] = $Target }
    }
    foreach ($key in $Rules.Keys) {
        $address = $key.ToLowerInvariant()
        if ($AddressList -notcontains $address) {
            throw "Forward rule for $address, which is not in -Addresses."
        }
        $map[$address] = [string]$Rules[$key]
    }
    foreach ($address in @($map.Keys)) {
        if ($map[$address] -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            throw "Forward target for $address is not an email address."
        }
    }
    $map
}

function Resolve-HostedZoneId([string]$Domain, [hashtable]$Given) {
    if ($Given.ContainsKey($Domain)) {
        return $Given[$Domain]
    }
    $result = Invoke-Aws -Arguments @('route53', 'list-hosted-zones-by-name', '--dns-name', $Domain)
    $zone = @($result.HostedZones | Where-Object { $_.Name -eq "$Domain." -and -not $_.Config.PrivateZone }) | Select-Object -First 1
    if (-not $zone) {
        throw "No public Route 53 hosted zone named $Domain. Pass -HostedZoneIds @{ '$Domain' = '<id>' }."
    }
    $zone.Id -replace '^/hostedzone/', ''
}

function Get-RecordSet([string]$ZoneId, [string]$Name, [string]$Type) {
    $result = Invoke-Aws -Arguments @('route53', 'list-resource-record-sets', '--hosted-zone-id', $ZoneId, '--start-record-name', $Name, '--start-record-type', $Type, '--max-items', '1')
    @($result.ResourceRecordSets | Where-Object { $_.Name -eq "$Name." -and $_.Type -eq $Type }) | Select-Object -First 1
}

function Submit-RecordChange([string]$ZoneId, [string]$Description, [object[]]$Changes) {
    Invoke-AwsChange -Description $Description -Arguments @('route53', 'change-resource-record-sets', '--hosted-zone-id', $ZoneId, '--change-batch', '{payload}') -Payload @{ Changes = $Changes } | Out-Null
}

function New-Upsert([string]$Name, [string]$Type, [int]$Ttl, [string[]]$Values) {
    @{ Action = 'UPSERT'; ResourceRecordSet = @{ Name = $Name; Type = $Type; TTL = $Ttl; ResourceRecords = @($Values | ForEach-Object { @{ Value = $_ } }) } }
}

function ConvertFrom-TxtValue([string]$Value) {
    $parts = [regex]::Matches($Value, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\(.)', '$1' }
    -join $parts
}

function ConvertTo-TxtValue([string]$Text) {
    $chunks = for ($i = 0; $i -lt $Text.Length; $i += 255) { $Text.Substring($i, [Math]::Min(255, $Text.Length - $i)) }
    (@($chunks) | ForEach-Object { '"' + ($_ -replace '(["\\])', '\$1') + '"' }) -join ' '
}

function Get-SpfChange {
    param([string[]]$ExistingValues)
    $values = @($ExistingValues | Where-Object { $_ })
    $spf = @($values | Where-Object { (ConvertFrom-TxtValue $_) -match '^v=spf1(\s|$)' })
    if ($spf.Count -gt 1) {
        throw 'The apex has more than one SPF record; merge them by hand first.'
    }
    if ($spf.Count -eq 0) {
        return @($values) + (ConvertTo-TxtValue "v=spf1 $script:SpfInclude ~all")
    }
    $text = ConvertFrom-TxtValue $spf[0]
    if ($text -split '\s+' -contains $script:SpfInclude) {
        return $null
    }
    $merged = $text -replace '^v=spf1', "v=spf1 $script:SpfInclude"
    @($values | ForEach-Object { if ($_ -eq $spf[0]) { ConvertTo-TxtValue $merged } else { $_ } })
}

function Get-MxChange {
    param($Existing, [string]$Target, [switch]$Replace)
    $desired = "10 $Target"
    if (-not $Existing) {
        return $desired
    }
    $values = @($Existing.ResourceRecords | ForEach-Object { $_.Value.TrimEnd('.') })
    if ($values.Count -eq 1 -and $values[0] -eq $desired) {
        return $null
    }
    if (-not $Replace) {
        throw "The apex MX for $($Existing.Name) is '$($values -join ', ')'. Rerun with -Force to replace it with '$desired'."
    }
    $desired
}

function Sync-Identity([string]$Domain, [string]$ZoneId) {
    $identity = Invoke-Aws -Arguments @('sesv2', 'get-email-identity', '--email-identity', $Domain) -NotFound 'NotFoundException'
    $tokens = @()
    if (-not $identity) {
        $created = Invoke-AwsChange -Description "create SES domain identity $Domain with Easy DKIM (RSA 2048)" -Arguments @('sesv2', 'create-email-identity', '--email-identity', $Domain, '--dkim-signing-attributes', 'NextSigningKeyLength=RSA_2048_BIT')
        if ($created) { $tokens = @($created.DkimAttributes.Tokens) }
        $verified = $false
    }
    else {
        $verified = [bool]$identity.VerifiedForSendingStatus
        $dkim = $identity.DkimAttributes
        $tokens = @($dkim.PSObject.Properties['Tokens'] ? $dkim.Tokens : @())
        if ($tokens.Count -eq 0 -or $dkim.Status -eq 'FAILED') {
            $result = Invoke-AwsChange -Description "regenerate Easy DKIM tokens for $Domain (status $($dkim.Status))" -Arguments @('sesv2', 'put-email-identity-dkim-signing-attributes', '--email-identity', $Domain, '--signing-attributes-origin', 'AWS_SES', '--signing-attributes', 'NextSigningKeyLength=RSA_2048_BIT')
            $tokens = @(if ($result) { $result.DkimTokens })
        }
        if (-not $dkim.SigningEnabled) {
            Invoke-AwsChange -Description "enable DKIM signing for $Domain" -Arguments @('sesv2', 'put-email-identity-dkim-attributes', '--email-identity', $Domain, '--signing-enabled') | Out-Null
        }
        if ($verified -and $tokens.Count -gt 0) {
            Write-Unchanged "SES identity $Domain verified"
        }
    }
    if ($tokens.Count -eq 0) {
        Write-Host "        DKIM CNAMEs for $Domain are written on the real run (SES issues the tokens then)."
    }
    else {
        $changes = foreach ($token in $tokens) {
            $name = "$token._domainkey.$Domain"
            $value = "$token.dkim.amazonses.com"
            $existing = Get-RecordSet $ZoneId $name 'CNAME'
            if (-not $existing -or $existing.ResourceRecords[0].Value.TrimEnd('.') -ne $value) {
                New-Upsert $name 'CNAME' 1800 @($value)
            }
        }
        if ($changes) {
            Submit-RecordChange $ZoneId "UPSERT $(@($changes).Count) DKIM CNAME(s) for $Domain" @($changes)
        }
        else {
            Write-Unchanged "DKIM CNAMEs for $Domain"
        }
    }
    if (-not $verified) {
        Add-Note "PENDING: SES identity $Domain is not verified yet. SES accepts mail and the forwarder sends from support@$Domain only after DKIM verifies (usually minutes, up to 72 hours). Check: aws sesv2 get-email-identity --email-identity $Domain --query VerifiedForSendingStatus"
    }
}

function Sync-Spf([string]$Domain, [string]$ZoneId) {
    $existing = Get-RecordSet $ZoneId $Domain 'TXT'
    $values = @(if ($existing) { $existing.ResourceRecords.Value })
    $new = Get-SpfChange -ExistingValues $values
    if ($null -eq $new) {
        Write-Unchanged "SPF on $Domain includes amazonses.com"
        return
    }
    $ttl = if ($existing) { [int]$existing.TTL } else { 300 }
    Submit-RecordChange $ZoneId "UPSERT apex TXT on $Domain (SPF with $script:SpfInclude; other TXT values kept)" @(New-Upsert $Domain 'TXT' $ttl $new)
}

function Sync-Mx([string]$Domain, [string]$ZoneId) {
    $target = "inbound-smtp.$Region.amazonaws.com"
    $existing = Get-RecordSet $ZoneId $Domain 'MX'
    $value = Get-MxChange -Existing $existing -Target $target -Replace:$Force
    if ($null -eq $value) {
        Write-Unchanged "MX on $Domain"
        return
    }
    Submit-RecordChange $ZoneId "UPSERT MX $Domain -> $value" @(New-Upsert $Domain 'MX' 300 @($value))
}

function Get-RuleSetSourceArn([string]$Account) {
    "arn:aws:ses:$($Region):$($Account):receipt-rule-set/$($RuleSetName):receipt-rule/*"
}

function Get-BucketPolicy([string]$Account) {
    [ordered]@{
        Version   = '2012-10-17'
        Statement = @(
            [ordered]@{
                Sid       = 'AllowSesPuts'
                Effect    = 'Allow'
                Principal = [ordered]@{ Service = 'ses.amazonaws.com' }
                Action    = 's3:PutObject'
                Resource  = "arn:aws:s3:::$Bucket/*"
                Condition = [ordered]@{
                    StringEquals = [ordered]@{ 'aws:SourceAccount' = $Account }
                    ArnLike      = [ordered]@{ 'aws:SourceArn' = (Get-RuleSetSourceArn $Account) }
                }
            },
            [ordered]@{
                Sid       = 'DenyInsecureTransport'
                Effect    = 'Deny'
                Principal = '*'
                Action    = 's3:*'
                Resource  = @("arn:aws:s3:::$Bucket", "arn:aws:s3:::$Bucket/*")
                Condition = [ordered]@{ Bool = [ordered]@{ 'aws:SecureTransport' = 'false' } }
            }
        )
    }
}

function Get-LifecycleRule {
    @($ExpirePrefixes | ForEach-Object {
            [ordered]@{
                ID         = 'expire-' + ($_.TrimEnd('/') -replace '[^A-Za-z0-9-]', '-')
                Filter     = [ordered]@{ Prefix = $_ }
                Status     = 'Enabled'
                Expiration = [ordered]@{ Days = $ExpireDays }
            }
        })
}

function Sync-Bucket([string]$Account) {
    $b = $Bucket
    $exists = $null -ne (Invoke-Aws -Arguments @('s3api', 'head-bucket', '--bucket', $b) -NotFound '404|Not Found|NoSuchBucket')
    if (-not $exists) {
        $create = @('s3api', 'create-bucket', '--bucket', $b)
        if ($Region -ne 'us-east-1') { $create += @('--create-bucket-configuration', "LocationConstraint=$Region") }
        Invoke-AwsChange -Description "create S3 bucket $b" -Arguments $create | Out-Null
    }

    $block = [ordered]@{ BlockPublicAcls = $true; IgnorePublicAcls = $true; BlockPublicPolicy = $true; RestrictPublicBuckets = $true }
    $current = if ($exists) { Invoke-Aws -Arguments @('s3api', 'get-public-access-block', '--bucket', $b) -NotFound 'NoSuchPublicAccessBlockConfiguration' } else { $null }
    if ($current -and (Test-SameJson $current.PublicAccessBlockConfiguration $block)) { Write-Unchanged "public access block on $b" }
    else { Invoke-AwsChange -Description "block all public access on $b" -Arguments @('s3api', 'put-public-access-block', '--bucket', $b, '--public-access-block-configuration', '{payload}') -Payload $block | Out-Null }

    $current = if ($exists) { Invoke-Aws -Arguments @('s3api', 'get-bucket-encryption', '--bucket', $b) -NotFound 'ServerSideEncryptionConfigurationNotFoundError' } else { $null }
    $algorithm = if ($current) { $current.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm } else { $null }
    if ($algorithm -eq 'AES256') { Write-Unchanged "SSE-S3 on $b" }
    else { Invoke-AwsChange -Description "set default encryption SSE-S3 (AES256) on $b" -Arguments @('s3api', 'put-bucket-encryption', '--bucket', $b, '--server-side-encryption-configuration', '{payload}') -Payload @{ Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = 'AES256' } }) } | Out-Null }

    $rules = @(Get-LifecycleRule)
    $current = if ($exists) { Invoke-Aws -Arguments @('s3api', 'get-bucket-lifecycle-configuration', '--bucket', $b) -NotFound 'NoSuchLifecycleConfiguration' } else { $null }
    if ($rules.Count -eq 0) { Write-Host "        No -ExpirePrefixes; lifecycle left as is on $b." }
    elseif ($current -and (Test-SameJson @($current.Rules | ForEach-Object { [ordered]@{ ID = $_.ID; Filter = $_.Filter; Status = $_.Status; Expiration = $_.Expiration } }) $rules)) { Write-Unchanged "lifecycle on $b" }
    else { Invoke-AwsChange -Description "set lifecycle on ${b}: expire $($ExpirePrefixes -join ', ') after $ExpireDays days" -Arguments @('s3api', 'put-bucket-lifecycle-configuration', '--bucket', $b, '--lifecycle-configuration', '{payload}') -Payload @{ Rules = @($rules) } | Out-Null }

    $policy = Get-BucketPolicy $Account
    $current = if ($exists) { Invoke-Aws -Arguments @('s3api', 'get-bucket-policy', '--bucket', $b) -NotFound 'NoSuchBucketPolicy' } else { $null }
    if ($current -and (Test-SameJson ($current.Policy | ConvertFrom-Json) $policy)) { Write-Unchanged "bucket policy on $b" }
    else { Invoke-AwsChange -Description "set bucket policy on ${b}: ses.amazonaws.com may PutObject for account $Account and rule set $RuleSetName only; deny non-TLS" -Arguments @('s3api', 'put-bucket-policy', '--bucket', $b, '--policy', '{payload}') -Payload $policy | Out-Null }
}

function Get-RolePolicy([string]$Account, [string[]]$SendingDomains) {
    [ordered]@{
        Version   = '2012-10-17'
        Statement = @(
            [ordered]@{ Effect = 'Allow'; Action = 's3:GetObject'; Resource = "arn:aws:s3:::$Bucket/*" },
            [ordered]@{ Effect = 'Allow'; Action = 'ses:SendRawEmail'; Resource = @($SendingDomains | ForEach-Object { "arn:aws:ses:$($Region):$($Account):identity/$_" }) },
            [ordered]@{ Effect = 'Allow'; Action = 'logs:CreateLogGroup'; Resource = "arn:aws:logs:$($Region):$($Account):*" },
            [ordered]@{ Effect = 'Allow'; Action = @('logs:CreateLogStream', 'logs:PutLogEvents'); Resource = "arn:aws:logs:$($Region):$($Account):log-group:/aws/lambda/$($FunctionName):*" }
        )
    }
}

function Sync-Role([string]$Account, [string[]]$SendingDomains) {
    $name = $FunctionName
    $trust = [ordered]@{
        Version   = '2012-10-17'
        Statement = @([ordered]@{
                Effect    = 'Allow'
                Principal = [ordered]@{ Service = 'lambda.amazonaws.com' }
                Action    = 'sts:AssumeRole'
                Condition = [ordered]@{ StringEquals = [ordered]@{ 'aws:SourceAccount' = $Account } }
            })
    }
    $role = Invoke-Aws -Arguments @('iam', 'get-role', '--role-name', $name) -NotFound 'NoSuchEntity'
    if (-not $role) {
        Invoke-AwsChange -Description "create IAM role $name (trusted by lambda.amazonaws.com in account $Account)" -Arguments @('iam', 'create-role', '--role-name', $name, '--assume-role-policy-document', '{payload}') -Payload $trust | Out-Null
    }
    elseif (Test-SameJson $role.Role.AssumeRolePolicyDocument $trust) { Write-Unchanged "IAM role $name trust policy" }
    else { Invoke-AwsChange -Description "update trust policy of IAM role $name" -Arguments @('iam', 'update-assume-role-policy', '--role-name', $name, '--policy-document', '{payload}') -Payload $trust | Out-Null }

    $policy = Get-RolePolicy $Account $SendingDomains
    $current = if ($role) { Invoke-Aws -Arguments @('iam', 'get-role-policy', '--role-name', $name, '--policy-name', 'forward-mail') -NotFound 'NoSuchEntity' } else { $null }
    if ($current -and (Test-SameJson $current.PolicyDocument $policy)) { Write-Unchanged "IAM role $name inline policy" }
    else { Invoke-AwsChange -Description "put inline policy forward-mail on ${name}: s3:GetObject on $Bucket, ses:SendRawEmail from $($SendingDomains -join ', '), CloudWatch logs" -Arguments @('iam', 'put-role-policy', '--role-name', $name, '--policy-name', 'forward-mail', '--policy-document', '{payload}') -Payload $policy | Out-Null }
    "arn:aws:iam::$($Account):role/$name"
}

function New-ForwarderZip([string]$Destination) {
    $source = Join-Path $PSScriptRoot 'ses-forwarder/forwarder.py'
    $bytes = [System.IO.File]::ReadAllBytes($source)
    $stream = [System.IO.File]::Create($Destination)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        $entry = $zip.CreateEntry('forwarder.py', [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $writer = $entry.Open()
        $writer.Write($bytes, 0, $bytes.Length)
        $writer.Dispose()
        $zip.Dispose()
    }
    finally {
        $stream.Dispose()
    }
    $sha = [System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($Destination))
    [Convert]::ToBase64String($sha)
}

function Wait-RoleUsable([string[]]$CreateArguments) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-Aws -Arguments $CreateArguments
        }
        catch {
            if ($attempt -ge 8 -or $_.Exception.Message -notmatch 'cannot be assumed|InvalidParameterValueException') { throw }
            Write-Host "        Waiting for the new IAM role to propagate (attempt $attempt)..."
            Start-Sleep -Seconds 5
        }
    }
}

function Sync-Function([string]$Account, [string]$RoleArn, [System.Collections.IDictionary]$ForwardMap) {
    $name = $FunctionName
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "$name-$PID.zip"
    $sha = New-ForwarderZip $zipPath
    $rulesJson = ConvertTo-CanonicalJson $ForwardMap
    $variables = [ordered]@{ MAIL_BUCKET = $Bucket; FORWARD_RULES = $rulesJson }
    $settings = @('--runtime', 'python3.12', '--handler', 'forwarder.handler', '--role', $RoleArn, '--timeout', '60', '--memory-size', '512')
    try {
        $current = Invoke-Aws -Arguments @('lambda', 'get-function', '--function-name', $name) -NotFound 'ResourceNotFoundException'
        if (-not $current) {
            $create = @('lambda', 'create-function', '--function-name', $name, '--zip-file', "fileb://$zipPath") + $settings + @('--environment', '{payload}')
            Write-Host "$(if ($script:DryRun) { 'WHATIF' } else { 'CHANGE' }): create Lambda $name (python3.12, code sha256 $sha) with FORWARD_RULES $rulesJson"
            if (-not $script:DryRun) {
                $file = New-TemporaryFile
                Set-Content -LiteralPath $file -Value (@{ Variables = $variables } | ConvertTo-Json -Compress) -NoNewline -Encoding utf8NoBOM
                try {
                    Wait-RoleUsable ($create | ForEach-Object { $_ -replace '^\{payload\}$', "file://$($file.FullName)" }) | Out-Null
                }
                finally { Remove-Item -LiteralPath $file }
                Invoke-Aws -Arguments @('lambda', 'wait', 'function-active-v2', '--function-name', $name) | Out-Null
            }
        }
        else {
            $config = $current.Configuration
            if ($config.CodeSha256 -eq $sha) { Write-Unchanged "Lambda $name code" }
            else {
                Invoke-AwsChange -Description "update Lambda $name code (sha256 $($config.CodeSha256) -> $sha)" -Arguments @('lambda', 'update-function-code', '--function-name', $name, '--zip-file', "fileb://$zipPath") | Out-Null
                if (-not $script:DryRun) { Invoke-Aws -Arguments @('lambda', 'wait', 'function-updated-v2', '--function-name', $name) | Out-Null }
            }
            $currentVariables = if ($config.PSObject.Properties['Environment']) { $config.Environment.Variables } else { $null }
            $same = $config.Runtime -eq 'python3.12' -and $config.Handler -eq 'forwarder.handler' -and $config.Role -eq $RoleArn -and $config.Timeout -eq 60 -and $config.MemorySize -eq 512 -and (Test-SameJson $currentVariables $variables)
            if ($same) { Write-Unchanged "Lambda $name configuration" }
            else { Invoke-AwsChange -Description "update Lambda $name configuration (FORWARD_RULES $rulesJson)" -Arguments (@('lambda', 'update-function-configuration', '--function-name', $name) + $settings + @('--environment', '{payload}')) -Payload @{ Variables = $variables } | Out-Null }
        }
    }
    finally {
        Remove-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue
    }

    $sourceArn = Get-RuleSetSourceArn $Account
    $policy = Invoke-Aws -Arguments @('lambda', 'get-policy', '--function-name', $name) -NotFound 'ResourceNotFoundException'
    $statement = if ($policy) { @(($policy.Policy | ConvertFrom-Json).Statement | Where-Object Sid -eq 'ses-inbound') | Select-Object -First 1 } else { $null }
    $expected = $statement -and ($statement.Condition | ConvertTo-Json -Depth 8 -Compress) -match [regex]::Escape($sourceArn) -and ($statement.Condition | ConvertTo-Json -Depth 8 -Compress) -match $Account
    if ($expected) { Write-Unchanged "Lambda $name invoke permission for SES" }
    else {
        if ($statement) {
            Invoke-AwsChange -Description "remove outdated SES invoke permission from $name" -Arguments @('lambda', 'remove-permission', '--function-name', $name, '--statement-id', 'ses-inbound') | Out-Null
        }
        Invoke-AwsChange -Description "allow ses.amazonaws.com to invoke $name for account $Account, rule set $RuleSetName" -Arguments @('lambda', 'add-permission', '--function-name', $name, '--statement-id', 'ses-inbound', '--action', 'lambda:InvokeFunction', '--principal', 'ses.amazonaws.com', '--source-account', $Account, '--source-arn', $sourceArn) | Out-Null
    }
    "arn:aws:lambda:$($Region):$($Account):function:$name"
}

function New-ReceiptRule([string]$Address, [string]$FunctionArn) {
    $parts = Get-AddressPart $Address
    $actions = @([ordered]@{ S3Action = [ordered]@{ BucketName = $Bucket; ObjectKeyPrefix = $parts.Prefix } })
    if ($FunctionArn) {
        $actions += [ordered]@{ LambdaAction = [ordered]@{ FunctionArn = $FunctionArn; InvocationType = 'Event' } }
    }
    [ordered]@{
        Name        = Get-RuleName $Address
        Enabled     = $true
        TlsPolicy   = 'Optional'
        Recipients  = @($Address)
        Actions     = $actions
        ScanEnabled = $true
    }
}

function Sync-ReceiptRule([string[]]$AddressList, [System.Collections.IDictionary]$ForwardMap, [string]$FunctionArn) {
    $set = Invoke-Aws -Arguments @('ses', 'describe-receipt-rule-set', '--rule-set-name', $RuleSetName) -NotFound 'RuleSetDoesNotExist'
    if (-not $set) {
        Invoke-AwsChange -Description "create receipt rule set $RuleSetName" -Arguments @('ses', 'create-receipt-rule-set', '--rule-set-name', $RuleSetName) | Out-Null
    }
    $existing = if ($set) { @($set.Rules) } else { @() }
    $previous = $null
    foreach ($address in $AddressList) {
        $arn = if ($ForwardMap.Contains($address)) { $FunctionArn } else { $null }
        $rule = New-ReceiptRule $address $arn
        $current = $existing | Where-Object Name -eq $rule.Name | Select-Object -First 1
        $what = "$address -> s3://$Bucket/$((Get-AddressPart $address).Prefix)$(if ($arn) { ' + forward' })"
        if (-not $current) {
            $createArgs = @('ses', 'create-receipt-rule', '--rule-set-name', $RuleSetName, '--rule', '{payload}')
            if ($previous) { $createArgs += @('--after', $previous) }
            Invoke-AwsChange -Description "create receipt rule $($rule.Name): $what" -Arguments $createArgs -Payload $rule | Out-Null
        }
        elseif (Test-SameJson $current $rule) { Write-Unchanged "receipt rule $($rule.Name)" }
        else { Invoke-AwsChange -Description "update receipt rule $($rule.Name): $what" -Arguments @('ses', 'update-receipt-rule', '--rule-set-name', $RuleSetName, '--rule', '{payload}') -Payload $rule | Out-Null }
        $previous = $rule.Name
    }
    $managed = @($AddressList | ForEach-Object { Get-RuleName $_ })
    foreach ($other in $existing | Where-Object { $managed -notcontains $_.Name }) {
        Add-Note "NOTE: receipt rule $($other.Name) in $RuleSetName is not in -Addresses and was left in place; delete it with: aws ses delete-receipt-rule --rule-set-name $RuleSetName --rule-name $($other.Name)"
    }

    $active = Invoke-Aws -Arguments @('ses', 'describe-active-receipt-rule-set')
    $activeName = if ($active -and $active.PSObject.Properties['Metadata']) { $active.Metadata.Name } else { $null }
    if ($activeName -eq $RuleSetName) { Write-Unchanged "receipt rule set $RuleSetName active" }
    elseif ($activeName -and -not $Force) { throw "Receipt rule set $activeName is active; activating $RuleSetName would replace it. Rerun with -Force." }
    else { Invoke-AwsChange -Description "activate receipt rule set $RuleSetName$(if ($activeName) { " (replacing $activeName)" })" -Arguments @('ses', 'set-active-receipt-rule-set', '--rule-set-name', $RuleSetName) | Out-Null }
}

function Invoke-SesInbound {
    $script:DryRun = [bool]$WhatIfPreference
    $WhatIfPreference = $false
    $script:Notes.Clear()
    $domainList = @($Domains | ForEach-Object { $_.ToLowerInvariant().TrimEnd('.') } | Select-Object -Unique)
    $addressList = @($(if ($Addresses) { $Addresses } else { Get-DefaultAddress $domainList }) | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    foreach ($address in $addressList) {
        $parts = Get-AddressPart $address
        if ($domainList -notcontains $parts.Domain) { throw "Address $address is not in -Domains." }
    }
    $forwardMap = Resolve-ForwardMap -AddressList $addressList -Target $ForwardTo -Rules $ForwardRules
    if ($forwardMap.Count -eq 0 -and -not $NoForward) {
        throw 'Pass -ForwardTo or -ForwardRules (a run without them removes forwarding from every rule), or -NoForward to store mail in S3 only.'
    }
    if ($script:DryRun) { Write-Host 'Dry run: only read-only AWS calls are made.' }

    $account = (Invoke-Aws -Arguments @('sts', 'get-caller-identity')).Account
    $zones = [ordered]@{}
    foreach ($domain in $domainList) { $zones[$domain] = Resolve-HostedZoneId $domain $HostedZoneIds }

    foreach ($domain in $domainList) {
        Write-Host "== $domain ($($zones[$domain]))"
        Sync-Identity $domain $zones[$domain]
        Sync-Spf $domain $zones[$domain]
    }

    Write-Host "== S3 bucket $Bucket"
    Sync-Bucket $account

    $functionArn = $null
    if ($forwardMap.Count -gt 0) {
        Write-Host "== Forwarder $FunctionName"
        $sendingDomains = @($forwardMap.Keys | ForEach-Object { (Get-AddressPart $_).Domain } | Select-Object -Unique)
        $roleArn = Sync-Role $account $sendingDomains
        $functionArn = Sync-Function $account $roleArn $forwardMap
    }
    else {
        Write-Host '-NoForward: no forwarding Lambda; mail is stored in S3 only.'
    }

    Write-Host "== Receipt rule set $RuleSetName"
    Sync-ReceiptRule $addressList $forwardMap $functionArn

    foreach ($domain in $domainList) {
        Sync-Mx $domain $zones[$domain]
    }

    foreach ($note in $script:Notes) { Write-Host $note }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SesInbound
}
