BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'ses-inbound.ps1')

    function Get-Payload([string[]]$Arguments) {
        $ref = $Arguments | Where-Object { $_ -like 'file://*' } | Select-Object -First 1
        if ($ref) { Get-Content -Raw -LiteralPath ($ref -replace '^file://', '') | ConvertFrom-Json -Depth 32 }
    }

    function New-AwsFake {
        param([hashtable]$Overrides = @{})
        $script:awsCalls = [System.Collections.Generic.List[object]]::new()
        $script:awsOverrides = $Overrides
        Mock Invoke-Aws {
            $op = "$($Arguments[0]) $($Arguments[1])"
            $script:awsCalls.Add([pscustomobject]@{ Op = $op; Arguments = $Arguments; Payload = (Get-Payload $Arguments) })
            if ($script:awsOverrides.ContainsKey($op)) { return & $script:awsOverrides[$op] $Arguments }
            switch ($op) {
                'sts get-caller-identity' { [pscustomobject]@{ Account = '111122223333' } }
                'route53 list-hosted-zones-by-name' { [pscustomobject]@{ HostedZones = @([pscustomobject]@{ Name = "$($Arguments[3])."; Id = "/hostedzone/Z-$($Arguments[3])"; Config = [pscustomobject]@{ PrivateZone = $false } }) } }
                'route53 list-resource-record-sets' { [pscustomobject]@{ ResourceRecordSets = @() } }
                'sesv2 create-email-identity' { [pscustomobject]@{ DkimAttributes = [pscustomobject]@{ Tokens = @('tok1', 'tok2', 'tok3') } } }
                'ses describe-active-receipt-rule-set' { '' }
                default { $null }
            }
        }
    }

    $readVerb = '^(get|list|describe|head|wait)-|^wait$'
}

Describe 'address helpers' {
    It 'defaults to support@ every domain plus claude-test@goom.life' {
        Get-DefaultAddress @('goom.life', 'gideonogega.com') | Should -BeExactly @('support@goom.life', 'support@gideonogega.com', 'claude-test@goom.life')
    }

    It 'adds no claude-test address without goom.life' {
        Get-DefaultAddress @('goomtech.com') | Should -BeExactly @('support@goomtech.com')
    }

    It 'builds the object prefix domain/local/' {
        (Get-AddressPart 'claude-test@goom.life').Prefix | Should -BeExactly 'goom.life/claude-test/'
    }

    It 'rejects an address that is not an email' {
        { Get-AddressPart 'support' } | Should -Throw '*Invalid address*'
    }

    It 'names rules with letters, digits and dashes only' {
        Get-RuleName 'support@gideonogega.com' | Should -BeExactly 'support-at-gideonogega-com'
    }
}

Describe 'Resolve-ForwardMap' {
    It 'forwards every support@ address to -ForwardTo and nothing else' {
        $map = Resolve-ForwardMap -AddressList @('support@goom.life', 'claude-test@goom.life', 'support@goomtech.com') -Target 'o@example.com' -Rules @{}
        @($map.Keys) | Should -BeExactly @('support@goom.life', 'support@goomtech.com')
    }

    It 'lets -ForwardRules add or override targets' {
        $map = Resolve-ForwardMap -AddressList @('support@goom.life', 'claude-test@goom.life') -Target 'o@example.com' -Rules @{ 'Claude-Test@goom.life' = 'x@example.com'; 'support@goom.life' = 'y@example.com' }
        $map['claude-test@goom.life'] | Should -BeExactly 'x@example.com'
        $map['support@goom.life'] | Should -BeExactly 'y@example.com'
    }

    It 'rejects a rule for an address that is not managed' {
        { Resolve-ForwardMap -AddressList @('support@goom.life') -Target $null -Rules @{ 'sales@goom.life' = 'o@example.com' } } | Should -Throw '*not in -Addresses*'
    }

    It 'rejects a target that is not an email address' {
        { Resolve-ForwardMap -AddressList @('support@goom.life') -Target 'nobody' -Rules @{} } | Should -Throw '*not an email address*'
    }
}

Describe 'Resolve-HostedZoneId' {
    BeforeEach {
        Mock Invoke-Aws {
            [pscustomobject]@{ HostedZones = @(
                    [pscustomobject]@{ Name = 'goom.life.'; Id = '/hostedzone/ZPRIVATE'; Config = [pscustomobject]@{ PrivateZone = $true } },
                    [pscustomobject]@{ Name = 'goom.life.'; Id = '/hostedzone/ZPUBLIC'; Config = [pscustomobject]@{ PrivateZone = $false } },
                    [pscustomobject]@{ Name = 'goom.life.example.'; Id = '/hostedzone/ZOTHER'; Config = [pscustomobject]@{ PrivateZone = $false } }
                ) }
        }
    }

    It 'uses a given id without a lookup' {
        Resolve-HostedZoneId 'goom.life' @{ 'goom.life' = 'ZGIVEN' } | Should -BeExactly 'ZGIVEN'
        Should -Invoke Invoke-Aws -Times 0 -Exactly
    }

    It 'looks up the public zone by exact name' {
        Resolve-HostedZoneId 'goom.life' @{} | Should -BeExactly 'ZPUBLIC'
    }

    It 'fails when no public zone matches' {
        { Resolve-HostedZoneId 'blademasterx.com' @{} } | Should -Throw '*No public Route 53 hosted zone*'
    }
}

Describe 'TXT values' {
    It 'round-trips quotes and backslashes' {
        $value = ConvertTo-TxtValue 'a "quoted" \ value'
        $value | Should -BeExactly '"a \"quoted\" \\ value"'
        ConvertFrom-TxtValue $value | Should -BeExactly 'a "quoted" \ value'
    }

    It 'splits values longer than 255 characters into strings' {
        $text = 'x' * 300
        $value = ConvertTo-TxtValue $text
        $value | Should -BeExactly ('"' + ('x' * 255) + '" "' + ('x' * 45) + '"')
        ConvertFrom-TxtValue $value | Should -BeExactly $text
    }
}

Describe 'Get-SpfChange' {
    It 'adds an SPF record when the apex has no TXT' {
        Get-SpfChange -ExistingValues @() | Should -BeExactly @('"v=spf1 include:amazonses.com ~all"')
    }

    It 'adds SPF and keeps other TXT values verbatim' {
        Get-SpfChange -ExistingValues @('"google-site-verification=abc"') | Should -BeExactly @('"google-site-verification=abc"', '"v=spf1 include:amazonses.com ~all"')
    }

    It 'merges the include into an existing SPF record, keeping its mechanisms and other values' {
        $result = Get-SpfChange -ExistingValues @('"keep=1"', '"v=spf1 include:_spf.google.com -all"')
        $result | Should -BeExactly @('"keep=1"', '"v=spf1 include:amazonses.com include:_spf.google.com -all"')
    }

    It 'recognises an SPF record split across strings' {
        Get-SpfChange -ExistingValues @('"v=spf1 include:amazon" "ses.com ~all"') | Should -BeNullOrEmpty
    }

    It 'returns nothing when amazonses.com is already included' {
        Get-SpfChange -ExistingValues @('"v=spf1 include:amazonses.com ~all"') | Should -BeNullOrEmpty
    }

    It 'refuses to touch two SPF records' {
        { Get-SpfChange -ExistingValues @('"v=spf1 -all"', '"v=spf1 ~all"') } | Should -Throw '*more than one SPF*'
    }
}

Describe 'Get-MxChange' {
    BeforeAll { $target = 'inbound-smtp.us-east-1.amazonaws.com' }

    It 'adds the MX when there is none' {
        Get-MxChange -Existing $null -Target $target | Should -BeExactly "10 $target"
    }

    It 'returns nothing when the MX already matches' {
        $existing = [pscustomobject]@{ Name = 'goom.life.'; ResourceRecords = @([pscustomobject]@{ Value = "10 $target." }) }
        Get-MxChange -Existing $existing -Target $target | Should -BeNullOrEmpty
    }

    It 'refuses to replace a different MX without -Force' {
        $existing = [pscustomobject]@{ Name = 'goom.life.'; ResourceRecords = @([pscustomobject]@{ Value = '1 aspmx.l.google.com.' }) }
        { Get-MxChange -Existing $existing -Target $target } | Should -Throw '*-Force*'
        Get-MxChange -Existing $existing -Target $target -Replace | Should -BeExactly "10 $target"
    }
}

Describe 'New-ReceiptRule' {
    It 'stores under the address prefix and forwards when given a function' {
        $rule = New-ReceiptRule 'support@goom.life' 'arn:fn'
        $rule.Recipients | Should -BeExactly @('support@goom.life')
        $rule.Actions[0].S3Action.ObjectKeyPrefix | Should -BeExactly 'goom.life/support/'
        $rule.Actions[1].LambdaAction.FunctionArn | Should -BeExactly 'arn:fn'
        $rule.ScanEnabled | Should -BeTrue
    }

    It 'only stores when there is no function' {
        @((New-ReceiptRule 'claude-test@goom.life' $null).Actions).Count | Should -Be 1
    }
}

Describe 'Test-SameJson' {
    It 'ignores property order' {
        Test-SameJson ([pscustomobject]@{ b = 1; a = @('x') }) ([ordered]@{ a = @('x'); b = 1 }) | Should -BeTrue
    }

    It 'detects a changed value' {
        Test-SameJson @{ a = 1 } @{ a = 2 } | Should -BeFalse
    }
}

Describe 'New-ForwarderZip' {
    It 'builds the same zip every time so unchanged code is not redeployed' {
        $first = New-ForwarderZip (Join-Path $TestDrive 'a.zip')
        $second = New-ForwarderZip (Join-Path $TestDrive 'b.zip')
        $first | Should -BeExactly $second
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $TestDrive 'a.zip'))
        try { $zip.Entries.FullName | Should -BeExactly @('forwarder.py') } finally { $zip.Dispose() }
    }
}

Describe 'Invoke-SesInbound' {
    BeforeEach {
        $Domains = @('goom.life', 'gideonogega.com')
        $HostedZoneIds = @{}
        $Addresses = $null
        $ForwardTo = 'owner@example.com'
        $ForwardRules = @{}
        $NoForward = $false
        $Force = $false
    }

    Context 'dry run with nothing in place' {
        BeforeEach {
            New-AwsFake @{
                'sesv2 get-email-identity' = { param($a) if ($a[3] -eq 'goom.life') { [pscustomobject]@{ VerifiedForSendingStatus = $true; DkimAttributes = [pscustomobject]@{ Status = 'SUCCESS'; SigningEnabled = $true; Tokens = @('g1', 'g2', 'g3') } } } }
            }
            $WhatIfPreference = $true
            $script:output = Invoke-SesInbound 6>&1 | Out-String
        }

        It 'makes only read-only AWS calls' {
            @($script:awsCalls | Where-Object { $_.Arguments[1] -notmatch $readVerb } | ForEach-Object { $_.Op }) | Should -BeNullOrEmpty
        }

        It 'prints every change it would make' {
            foreach ($expected in @(
                    'WHATIF: create SES domain identity gideonogega.com',
                    'WHATIF: UPSERT 3 DKIM CNAME(s) for goom.life',
                    'WHATIF: UPSERT apex TXT on goom.life',
                    'WHATIF: create S3 bucket goom-life-mail',
                    'WHATIF: block all public access on goom-life-mail',
                    'WHATIF: set default encryption SSE-S3',
                    'WHATIF: set lifecycle on goom-life-mail: expire goom.life/claude-test/ after 30 days',
                    'WHATIF: set bucket policy on goom-life-mail',
                    'WHATIF: create IAM role ses-inbound-forwarder',
                    'WHATIF: put inline policy forward-mail',
                    'WHATIF: create Lambda ses-inbound-forwarder',
                    'WHATIF: allow ses.amazonaws.com to invoke ses-inbound-forwarder',
                    'WHATIF: create receipt rule set org-inbound',
                    'WHATIF: create receipt rule support-at-goom-life: support@goom.life -> s3://goom-life-mail/goom.life/support/ + forward',
                    'WHATIF: create receipt rule claude-test-at-goom-life: claude-test@goom.life -> s3://goom-life-mail/goom.life/claude-test/',
                    'WHATIF: activate receipt rule set org-inbound',
                    'WHATIF: UPSERT MX goom.life -> 10 inbound-smtp.us-east-1.amazonaws.com',
                    'WHATIF: UPSERT MX gideonogega.com',
                    'PENDING: SES identity gideonogega.com is not verified yet'
                )) {
                $script:output | Should -Match ([regex]::Escape($expected))
            }
        }

        It 'does not forward claude-test mail' {
            $script:output | Should -Not -Match 'claude-test@goom.life -> s3://goom-life-mail/goom.life/claude-test/ \+ forward'
        }

        It 'reports no pending verification for a verified domain' {
            $script:output | Should -Not -Match 'PENDING: SES identity goom.life '
        }
    }

    Context 'real run with nothing in place' {
        BeforeEach {
            New-AwsFake
            Mock Start-Sleep {}
            $WhatIfPreference = $false
            Invoke-SesInbound 6>$null
            $script:writes = @($script:awsCalls | Where-Object { $_.Arguments[1] -notmatch $readVerb })
        }

        It 'writes the DKIM CNAMEs from the tokens SES issued' {
            $dkim = $script:writes | Where-Object { $_.Op -eq 'route53 change-resource-record-sets' -and $_.Payload.Changes[0].ResourceRecordSet.Type -eq 'CNAME' } | Select-Object -First 1
            $dkim.Payload.Changes.ResourceRecordSet.Name | Should -BeExactly @('tok1._domainkey.goom.life', 'tok2._domainkey.goom.life', 'tok3._domainkey.goom.life')
            $dkim.Payload.Changes[0].ResourceRecordSet.ResourceRecords[0].Value | Should -BeExactly 'tok1.dkim.amazonses.com'
        }

        It 'activates the rule set before any MX goes live' {
            $ops = @($script:writes | ForEach-Object { if ($_.Op -eq 'route53 change-resource-record-sets') { "dns-$($_.Payload.Changes[0].ResourceRecordSet.Type)" } else { $_.Op } })
            $activate = [array]::IndexOf($ops, 'ses set-active-receipt-rule-set')
            $firstMx = [array]::IndexOf($ops, 'dns-MX')
            $activate | Should -BeGreaterThan -1
            $firstMx | Should -BeGreaterThan $activate
            [array]::IndexOf($ops, 'ses create-receipt-rule') | Should -BeGreaterThan ([array]::IndexOf($ops, 'lambda add-permission'))
            [array]::IndexOf($ops, 'ses create-receipt-rule') | Should -BeGreaterThan ([array]::IndexOf($ops, 's3api put-bucket-policy'))
        }

        It 'scopes the bucket policy and Lambda permission to the account' {
            $policy = ($script:writes | Where-Object Op -eq 's3api put-bucket-policy').Payload
            $policy.Statement[0].Principal.Service | Should -BeExactly 'ses.amazonaws.com'
            $policy.Statement[0].Condition.StringEquals.'aws:SourceAccount' | Should -BeExactly '111122223333'
            $permission = ($script:writes | Where-Object Op -eq 'lambda add-permission').Arguments
            $permission[$permission.IndexOf('--source-account') + 1] | Should -BeExactly '111122223333'
        }

        It 'lets the forwarder send only from the forwarding domains' {
            $policy = ($script:writes | Where-Object Op -eq 'iam put-role-policy').Payload
            ($policy.Statement | Where-Object Action -eq 'ses:SendRawEmail').Resource | Should -BeExactly @('arn:aws:ses:us-east-1:111122223333:identity/goom.life', 'arn:aws:ses:us-east-1:111122223333:identity/gideonogega.com')
        }

        It 'passes the forward rules to the Lambda environment' {
            $create = $script:writes | Where-Object Op -eq 'lambda create-function'
            $create.Payload.Variables.MAIL_BUCKET | Should -BeExactly 'goom-life-mail'
            ($create.Payload.Variables.FORWARD_RULES | ConvertFrom-Json -AsHashtable).Keys | Sort-Object | Should -BeExactly @('support@gideonogega.com', 'support@goom.life')
        }
    }

    Context 'everything already in place' {
        It 'changes nothing on a second run' {
            $account = '111122223333'
            $mx = '10 inbound-smtp.us-east-1.amazonaws.com'
            $rules = @(Get-DefaultAddress $Domains | ForEach-Object {
                    $arn = if ($_ -like 'support@*') { "arn:aws:lambda:us-east-1:$($account):function:ses-inbound-forwarder" } else { $null }
                    New-ReceiptRule $_ $arn | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                })
            $zipSha = New-ForwarderZip (Join-Path $TestDrive 'same.zip')
            $forward = ConvertTo-CanonicalJson ([ordered]@{ 'support@goom.life' = 'owner@example.com'; 'support@gideonogega.com' = 'owner@example.com' })
            New-AwsFake @{
                'sesv2 get-email-identity'                = { [pscustomobject]@{ VerifiedForSendingStatus = $true; DkimAttributes = [pscustomobject]@{ Status = 'SUCCESS'; SigningEnabled = $true; Tokens = @('t1') } } }
                'route53 list-resource-record-sets'       = {
                    param($a)
                    $name = $a[$a.IndexOf('--start-record-name') + 1]; $type = $a[$a.IndexOf('--start-record-type') + 1]
                    $value = switch ($type) { 'MX' { $mx } 'TXT' { '"v=spf1 include:amazonses.com ~all"' } 'CNAME' { 't1.dkim.amazonses.com' } }
                    [pscustomobject]@{ ResourceRecordSets = @([pscustomobject]@{ Name = "$name."; Type = $type; TTL = 300; ResourceRecords = @([pscustomobject]@{ Value = $value }) }) }
                }
                's3api head-bucket'                       = { '' }
                's3api get-public-access-block'           = { [pscustomobject]@{ PublicAccessBlockConfiguration = [pscustomobject]@{ BlockPublicAcls = $true; IgnorePublicAcls = $true; BlockPublicPolicy = $true; RestrictPublicBuckets = $true } } }
                's3api get-bucket-encryption'             = { [pscustomobject]@{ ServerSideEncryptionConfiguration = [pscustomobject]@{ Rules = @([pscustomobject]@{ ApplyServerSideEncryptionByDefault = [pscustomobject]@{ SSEAlgorithm = 'AES256' } }) } } }
                's3api get-bucket-lifecycle-configuration' = { [pscustomobject]@{ Rules = @(Get-LifecycleRule | ConvertTo-Json -Depth 5 | ConvertFrom-Json) } }
                's3api get-bucket-policy'                 = { [pscustomobject]@{ Policy = (Get-BucketPolicy '111122223333' | ConvertTo-Json -Depth 10 -Compress) } }
                'iam get-role'                            = { [pscustomobject]@{ Role = [pscustomobject]@{ AssumeRolePolicyDocument = ([ordered]@{ Version = '2012-10-17'; Statement = @([ordered]@{ Effect = 'Allow'; Principal = [ordered]@{ Service = 'lambda.amazonaws.com' }; Action = 'sts:AssumeRole'; Condition = [ordered]@{ StringEquals = [ordered]@{ 'aws:SourceAccount' = '111122223333' } } }) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json) } } }
                'iam get-role-policy'                     = { [pscustomobject]@{ PolicyDocument = (Get-RolePolicy '111122223333' @('goom.life', 'gideonogega.com') | ConvertTo-Json -Depth 10 | ConvertFrom-Json) } }
                'lambda get-function'                     = { [pscustomobject]@{ Configuration = [pscustomobject]@{ CodeSha256 = $zipSha; Runtime = 'python3.12'; Handler = 'forwarder.handler'; Role = 'arn:aws:iam::111122223333:role/ses-inbound-forwarder'; Timeout = 60; MemorySize = 512; Environment = [pscustomobject]@{ Variables = [pscustomobject]@{ FORWARD_RULES = $forward; MAIL_BUCKET = 'goom-life-mail' } } } } }
                'lambda get-policy'                       = { [pscustomobject]@{ Policy = (@{ Statement = @(@{ Sid = 'ses-inbound'; Condition = @{ StringEquals = @{ 'AWS:SourceAccount' = '111122223333' }; ArnLike = @{ 'AWS:SourceArn' = 'arn:aws:ses:us-east-1:111122223333:receipt-rule-set/org-inbound:receipt-rule/*' } } }) } | ConvertTo-Json -Depth 10) } }
                'ses describe-receipt-rule-set'           = { [pscustomobject]@{ Rules = $rules } }
                'ses describe-active-receipt-rule-set'    = { [pscustomobject]@{ Metadata = [pscustomobject]@{ Name = 'org-inbound' } } }
            }
            $WhatIfPreference = $false
            $output = Invoke-SesInbound 6>&1 | Out-String
            @($script:awsCalls | Where-Object { $_.Arguments[1] -notmatch $readVerb } | ForEach-Object { $_.Op }) | Should -BeNullOrEmpty
            $output | Should -Not -Match 'CHANGE:'
        }
    }

    Context 'forwarding' {
        It 'refuses a run that would strip forwarding' {
            New-AwsFake
            $ForwardTo = $null
            { Invoke-SesInbound 6>$null } | Should -Throw '*-NoForward*'
            $script:awsCalls.Count | Should -Be 0
        }

        It 'stores only, with no Lambda, under -NoForward' {
            New-AwsFake
            $ForwardTo = $null
            $NoForward = $true
            $WhatIfPreference = $true
            $output = Invoke-SesInbound 6>&1 | Out-String
            $output | Should -Not -Match 'WHATIF: .*Lambda|\+ forward'
            @($script:awsCalls | Where-Object { $_.Arguments[0] -in 'lambda', 'iam' }).Count | Should -Be 0
        }
    }

    Context 'another rule set is active' {
        It 'refuses to replace it without -Force' {
            New-AwsFake @{ 'ses describe-active-receipt-rule-set' = { [pscustomobject]@{ Metadata = [pscustomobject]@{ Name = 'legacy' } } } }
            $WhatIfPreference = $true
            { Invoke-SesInbound 6>$null } | Should -Throw '*legacy is active*'
        }
    }
}
