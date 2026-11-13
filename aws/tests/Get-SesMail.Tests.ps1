BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Get-SesMail.ps1')
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
    $confirmUrl = 'https://music-dev.goom.life/Account/ConfirmEmail?userId=3f2a9c1e-7b44-4d0e-9a51-0c6f2b8e1d77&code=CfDJ8KxQ%2Bq7Wm2nVb4ZpR9sLh3TgYc6uE1oA5dF8jN0kM'
}

Describe 'Get-MailPrefix' {
    It 'maps a full address to domain/local/' {
        Get-MailPrefix 'Claude-Test@Goom.Life' | Should -Be 'goom.life/claude-test/'
    }

    It 'rejects <value>' -ForEach @(@{ value = 'claude-test' }, @{ value = 'a@b' }, @{ value = '../x@goom.life' }) {
        { Get-MailPrefix $value } | Should -Throw '*full email address*'
    }
}

Describe 'ConvertFrom-EncodedWord' {
    It 'decodes Q and B words and joins adjacent ones' {
        ConvertFrom-EncodedWord '=?UTF-8?Q?Caf=C3=A9?= =?UTF-8?B?IGJhcg==?= tail' | Should -BeExactly 'Café bar tail'
    }

    It 'leaves plain text alone' {
        ConvertFrom-EncodedWord 'Reset your password' | Should -BeExactly 'Reset your password'
    }
}

Describe 'ConvertFrom-QuotedPrintable' {
    It 'removes soft line breaks and decodes escapes' {
        $bytes = ConvertFrom-QuotedPrintable "a=3Db=`nc=C3=A9"
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly 'a=bcé'
    }

    It 'keeps a trailing = that is not an escape' {
        [System.Text.Encoding]::UTF8.GetString((ConvertFrom-QuotedPrintable 'x=')) | Should -BeExactly 'x='
    }
}

Describe 'ConvertFrom-Eml' {
    It 'reads a multipart quoted-printable message with an intact confirmation link' {
        $mail = ConvertFrom-Eml (Join-Path $fixtures 'multipart-quoted-printable.eml')
        $mail.From | Should -BeExactly 'GOOM Music <noreply@music-dev.goom.life>'
        $mail.Subject | Should -BeExactly "Confirm your email $([char]0x2013) GOOM Music"
        $mail.Date | Should -Be ([DateTimeOffset]'2026-11-13T14:05:00Z')
        $mail.Links | Should -BeExactly @($confirmUrl)
    }

    It 'reads a single-part base64 message and trims trailing punctuation from links' {
        $mail = ConvertFrom-Eml (Join-Path $fixtures 'single-part-base64.eml')
        $mail.Subject | Should -BeExactly 'Reset your password'
        $mail.Date | Should -Be ([DateTimeOffset]'2026-11-12T14:30:00Z')
        $mail.Links | Should -BeExactly @('https://familytree-dev.goom.life/Account/ResetPassword?email=claude-test%40goom.life&code=Q2ZESjhLeFFx', 'https://goom.life/help')
    }

    It 'reads nested multipart with a base64 html part and ignores attachments' {
        $mail = ConvertFrom-Eml (Join-Path $fixtures 'multipart-mixed-attachment.eml')
        $mail.From | Should -BeExactly 'René Dupont <rene@example.org>'
        $mail.Subject | Should -BeExactly 'Export broken'
        $mail.Links | Should -BeExactly @('https://example.org/export?id=42')
    }

    It 'decodes &amp; in html links' {
        $parts = @([pscustomobject]@{ MediaType = 'text/html'; Text = '<a href="https://x.example/a?b=1&amp;c=2">go</a>' })
        Get-MailLink $parts | Should -BeExactly @('https://x.example/a?b=1&c=2')
    }
}

Describe 'Get-SesMail' {
    BeforeEach {
        $Bucket = 'goom-life-mail'
        $Region = 'us-east-1'
        $OutDir = Join-Path $TestDrive ([guid]::NewGuid())
        $Since = [datetime]'2026-11-10T00:00:00Z'
        $From = $null
        $Subject = $null
        $Count = 5
        $Links = $false
        $PassThru = $true
        $Address = 'claude-test@goom.life'
        $script:keys = @{
            'goom.life/claude-test/m-confirm' = 'multipart-quoted-printable.eml'
            'goom.life/claude-test/m-reset'   = 'single-part-base64.eml'
            'goom.life/claude-test/m-support' = 'multipart-mixed-attachment.eml'
        }
        Mock Invoke-AwsCli -ParameterFilter { $Arguments[1] -eq 'list-objects-v2' } {
            [pscustomobject]@{
                Contents = @(
                    [pscustomobject]@{ Key = 'goom.life/claude-test/AMAZON_SES_SETUP_NOTIFICATION'; LastModified = '2026-11-13T15:00:00+00:00' },
                    [pscustomobject]@{ Key = 'goom.life/claude-test/m-reset'; LastModified = '2026-11-12T14:30:05+00:00' },
                    [pscustomobject]@{ Key = 'goom.life/claude-test/m-confirm'; LastModified = '2026-11-13T14:05:05+00:00' },
                    [pscustomobject]@{ Key = 'goom.life/claude-test/m-support'; LastModified = '2026-11-11T18:00:05+00:00' },
                    [pscustomobject]@{ Key = 'goom.life/claude-test/m-old'; LastModified = '2026-10-01T00:00:00+00:00' }
                )
            }
        }
        Mock Invoke-AwsCli -ParameterFilter { $Arguments[1] -eq 'get-object' } {
            $key = $Arguments[$Arguments.IndexOf('--key') + 1]
            Copy-Item (Join-Path $fixtures $script:keys[$key]) $Arguments[-1]
        }
    }

    It 'lists the address prefix, newest first, skipping the SES setup object and old mail' {
        $result = Get-SesMail 6>$null
        $result.Key | Should -BeExactly @('goom.life/claude-test/m-confirm', 'goom.life/claude-test/m-reset', 'goom.life/claude-test/m-support')
        Should -Invoke Invoke-AwsCli -ParameterFilter { $Arguments[1] -eq 'list-objects-v2' -and ($Arguments -join ' ') -match '--prefix goom.life/claude-test/ ' } -Times 1 -Exactly
        Should -Invoke Invoke-AwsCli -ParameterFilter { $Arguments[1] -eq 'get-object' -and $Arguments -contains 'goom.life/claude-test/m-old' } -Times 0 -Exactly
    }

    It 'filters by sender and stops at -Count' {
        $From = 'goom.life'
        $Count = 1
        $result = @(Get-SesMail 6>$null)
        $result.Key | Should -BeExactly @('goom.life/claude-test/m-confirm')
        Should -Invoke Invoke-AwsCli -ParameterFilter { $Arguments[1] -eq 'get-object' } -Times 1 -Exactly
    }

    It 'filters by subject' {
        $Subject = 'reset'
        (Get-SesMail 6>$null).Key | Should -BeExactly @('goom.life/claude-test/m-reset')
    }

    It 'prints sender, subject and links with -Links' {
        $Links = $true
        $PassThru = $false
        $Count = 1
        $printed = (Get-SesMail 6>&1 | Out-String)
        $printed | Should -Match 'From: GOOM Music <noreply@music-dev.goom.life>'
        $printed | Should -Match 'Subject: Confirm your email'
        $printed | Should -Match ([regex]::Escape("    $confirmUrl"))
    }

    It 'reuses an already downloaded file' {
        Get-SesMail 6>$null | Out-Null
        Get-SesMail 6>$null | Out-Null
        Should -Invoke Invoke-AwsCli -ParameterFilter { $Arguments[1] -eq 'get-object' } -Times 3 -Exactly
    }
}
