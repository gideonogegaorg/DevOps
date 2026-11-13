#Requires -Version 7.0
<#
.SYNOPSIS
Lists the newest SES-received messages for an address from the org mail bucket, downloads them and optionally prints their links.

.EXAMPLE
pwsh -File aws/Get-SesMail.ps1 -Address claude-test@goom.life -From noreply@music-dev.goom.life -Count 1 -Links
#>
[CmdletBinding()]
param(
    [string]$Address,
    [string]$Bucket = 'goom-life-mail',
    [datetime]$Since = (Get-Date).AddDays(-7),
    [string]$From,
    [string]$Subject,
    [int]$Count = 5,
    [switch]$Links,
    [string]$OutDir,
    [string]$Region = 'us-east-1',
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AwsCli.psm1') -Force

$script:Latin1 = [System.Text.Encoding]::Latin1

function Get-MailPrefix([string]$MailAddress) {
    if ($MailAddress -notmatch '^(?<local>[^@\s/]+)@(?<domain>[^@\s/]+\.[^@\s/]+)$') {
        throw "-Address must be a full email address such as claude-test@goom.life."
    }
    "$($Matches.domain.ToLowerInvariant())/$($Matches.local.ToLowerInvariant())/"
}

function Get-TextEncoding([string]$Charset) {
    if (-not $Charset) { return [System.Text.Encoding]::UTF8 }
    try { [System.Text.Encoding]::GetEncoding($Charset.Trim('"')) }
    catch { [System.Text.Encoding]::UTF8 }
}

function ConvertFrom-QuotedPrintable([string]$Text) {
    $joined = $Text -replace '=\r?\n', ''
    $bytes = [System.Collections.Generic.List[byte]]::new()
    for ($i = 0; $i -lt $joined.Length; $i++) {
        $c = $joined[$i]
        if ($c -eq '=' -and $i + 2 -lt $joined.Length -and $joined.Substring($i + 1, 2) -match '^[0-9A-Fa-f]{2}$') {
            $bytes.Add([Convert]::ToByte($joined.Substring($i + 1, 2), 16))
            $i += 2
        }
        else {
            $bytes.Add([byte][int]$c)
        }
    }
    $bytes.ToArray()
}

function ConvertFrom-EncodedWord([string]$Text) {
    if (-not $Text) { return $Text }
    $collapsed = [regex]::Replace($Text, '(\?=)\s+(=\?)', '$1$2')
    [regex]::Replace($collapsed, '=\?([^?]+)\?([BbQq])\?([^?]*)\?=', {
            param($m)
            $encoding = Get-TextEncoding $m.Groups[1].Value
            $payload = $m.Groups[3].Value
            $bytes = if ($m.Groups[2].Value -in 'B', 'b') { [Convert]::FromBase64String($payload) } else { ConvertFrom-QuotedPrintable ($payload -replace '_', ' ') }
            $encoding.GetString($bytes)
        })
}

function Get-HeaderParameter([string]$Value, [string]$Name) {
    if ($Value -match "(?i)(?:^|;)\s*$Name\s*=\s*(?:`"([^`"]*)`"|([^;\s]+))") {
        if ($Matches[1]) { return $Matches[1] }
        return $Matches[2]
    }
    $null
}

function Read-MimeEntity([string]$Text) {
    $split = [regex]::Match($Text, '\r?\n\r?\n')
    $headerText = if ($split.Success) { $Text.Substring(0, $split.Index) } else { $Text }
    $body = if ($split.Success) { $Text.Substring($split.Index + $split.Length) } else { '' }
    $headers = @{}
    foreach ($line in ($headerText -replace '\r?\n[ \t]+', ' ') -split '\r?\n') {
        if ($line -match '^([!-9;-~]+):\s*(.*)$') {
            $name = $Matches[1].ToLowerInvariant()
            if (-not $headers.ContainsKey($name)) { $headers[$name] = $Matches[2].Trim() }
        }
    }
    [pscustomobject]@{ Headers = $headers; Body = $body }
}

function Get-MimeTextPart($Entity) {
    $type = if ($Entity.Headers['content-type']) { $Entity.Headers['content-type'] } else { 'text/plain' }
    $mediaType = ($type -split ';')[0].Trim().ToLowerInvariant()
    if ($mediaType -like 'multipart/*') {
        $boundary = Get-HeaderParameter $type 'boundary'
        if (-not $boundary) { return }
        $pattern = '(?m)^--' + [regex]::Escape($boundary) + '(--)?[ \t]*\r?$\n?'
        $marks = [regex]::Matches($Entity.Body, $pattern)
        for ($i = 0; $i -lt $marks.Count - 1; $i++) {
            if ($marks[$i].Groups[1].Success) { break }
            $start = $marks[$i].Index + $marks[$i].Length
            Get-MimeTextPart (Read-MimeEntity $Entity.Body.Substring($start, $marks[$i + 1].Index - $start))
        }
        return
    }
    $disposition = $Entity.Headers['content-disposition']
    if ($mediaType -notin 'text/plain', 'text/html' -or ($disposition -and $disposition -match '^\s*attachment')) { return }
    $transfer = "$($Entity.Headers['content-transfer-encoding'])".Trim().ToLowerInvariant()
    $bytes = switch ($transfer) {
        'base64' { [Convert]::FromBase64String(($Entity.Body -replace '[^A-Za-z0-9+/=]', '')) }
        'quoted-printable' { ConvertFrom-QuotedPrintable $Entity.Body }
        default { $script:Latin1.GetBytes($Entity.Body) }
    }
    [pscustomobject]@{ MediaType = $mediaType; Text = (Get-TextEncoding (Get-HeaderParameter $type 'charset')).GetString($bytes) }
}

function Get-MailLink($Parts) {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $Parts) {
        $text = if ($part.MediaType -eq 'text/html') { [System.Net.WebUtility]::HtmlDecode(($part.Text -replace '<[^>]*\bhref\s*=\s*"([^"]*)"[^>]*>', ' $1 ')) } else { $part.Text }
        foreach ($m in [regex]::Matches($text, 'https?://[^\s<>"''`]+')) {
            $url = $m.Value -replace '[.,;:!?''\])}>]+$', ''
            if (-not $found.Contains($url)) { $found.Add($url) }
        }
    }
    , $found.ToArray()
}

function ConvertFrom-Eml([string]$Path) {
    $text = $script:Latin1.GetString([System.IO.File]::ReadAllBytes($Path))
    $entity = Read-MimeEntity $text
    $date = $null
    $rawDate = $entity.Headers['date']
    if ($rawDate) {
        $clean = ($rawDate -replace '\s*\([^)]*\)\s*$', '').Trim()
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($clean, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $date = $parsed }
    }
    $parts = @(Get-MimeTextPart $entity)
    [pscustomobject]@{
        From    = ConvertFrom-EncodedWord $entity.Headers['from']
        Subject = ConvertFrom-EncodedWord $entity.Headers['subject']
        Date    = $date
        Links   = Get-MailLink $parts
        Path    = $Path
    }
}

function Get-SesMail {
    $prefix = Get-MailPrefix $Address
    $target = if ($OutDir) { $OutDir } else { Join-Path ([System.IO.Path]::GetTempPath()) "ses-mail/$($prefix.TrimEnd('/'))" }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $listing = Invoke-AwsCli -Arguments @('s3api', 'list-objects-v2', '--bucket', $Bucket, '--prefix', $prefix, '--region', $Region)
    $objects = @(if ($listing -and $listing.PSObject.Properties['Contents']) { $listing.Contents }) |
        Where-Object { $_.Key -notlike '*/AMAZON_SES_SETUP_NOTIFICATION' -and ([DateTimeOffset]$_.LastModified).UtcDateTime -ge $Since.ToUniversalTime() } |
        Sort-Object { [DateTimeOffset]$_.LastModified } -Descending
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($object in $objects) {
        if ($results.Count -ge $Count) { break }
        $file = Join-Path $target (($object.Key -split '/')[-1] + '.eml')
        if (-not (Test-Path -LiteralPath $file)) {
            Invoke-AwsCli -Arguments @('s3api', 'get-object', '--bucket', $Bucket, '--key', $object.Key, '--region', $Region, $file) | Out-Null
        }
        $mail = ConvertFrom-Eml $file
        if ($From -and "$($mail.From)" -notlike "*$From*") { continue }
        if ($Subject -and "$($mail.Subject)" -notlike "*$Subject*") { continue }
        $mail | Add-Member -NotePropertyName Key -NotePropertyValue $object.Key
        $results.Add($mail)
        $when = if ($mail.Date) { $mail.Date.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') + 'Z' } else { ([DateTimeOffset]$object.LastModified).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') + 'Z' }
        Write-Host "$when  From: $($mail.From)  Subject: $($mail.Subject)  File: $file"
        if ($Links) {
            foreach ($link in $mail.Links) { Write-Host "    $link" }
        }
    }
    if ($results.Count -eq 0) {
        Write-Host "No messages under s3://$Bucket/$prefix since $($Since.ToString('u')) matching the filters."
    }
    if ($PassThru) { $results.ToArray() }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Address) { throw '-Address is required.' }
    Get-SesMail
}
