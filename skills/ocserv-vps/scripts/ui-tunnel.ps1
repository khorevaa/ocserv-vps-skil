[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('Host')]
    [string]$SshTarget,

    [ValidateRange(0, 65535)]
    [int]$LocalPort = 0,

    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,

    [string]$IdentityFile,

    [switch]$AcceptNewHostKey
)

$ErrorActionPreference = 'Stop'
if ($SshTarget.StartsWith('-') -or $SshTarget.ToCharArray().Where({
    [char]::IsWhiteSpace($_) -or [char]::IsControl($_)
}).Count -gt 0) {
    throw 'SshTarget must not begin with a dash or contain whitespace/control characters.'
}
$remoteSocket = '/run/ocserv-ui-web/web.sock'
$sshCommonArgs = @(
    '-T',
    '-p', $SshPort.ToString(),
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=3'
)

if ($IdentityFile) {
    $resolvedIdentity = (Resolve-Path -LiteralPath $IdentityFile).Path
    $sshCommonArgs += @('-i', $resolvedIdentity, '-o', 'IdentitiesOnly=yes')
}
if ($AcceptNewHostKey) {
    $sshCommonArgs += @('-o', 'StrictHostKeyChecking=accept-new')
}

$metadata = & ssh @sshCommonArgs '--' $SshTarget "grep -E '^OCSERV_UI_LOCAL_(HOST|PORT)=' /opt/ocserv-vps/ui.env"
if ($LASTEXITCODE -ne 0) {
    throw 'Cannot read the installed UI tunnel metadata from the VPS.'
}
$browserHost = $null
$configuredPort = 0
foreach ($line in $metadata) {
    if ($line -match '^OCSERV_UI_LOCAL_HOST=(.+)$') {
        $browserHost = $Matches[1]
    }
    elseif ($line -match '^OCSERV_UI_LOCAL_PORT=([0-9]+)$') {
        $configuredPort = [int]$Matches[1]
    }
}
if ($browserHost -notmatch '^ocserv-[0-9a-f]{32}\.localhost$') {
    throw 'The VPS returned an unsafe UI browser hostname.'
}
if ($configuredPort -lt 1 -or $configuredPort -gt 65535) {
    throw 'The VPS returned an invalid UI origin port.'
}
if ($LocalPort -ne 0 -and $LocalPort -ne $configuredPort) {
    throw "Requested local port ${LocalPort} does not match installed UI origin port ${configuredPort}."
}
$LocalPort = $configuredPort

Write-Host "SSH-only UI tunnel: http://${browserHost}:${LocalPort}/"
Write-Host 'Keep this process running while the UI is in use; press Ctrl+C to close it.'

& ssh @sshCommonArgs '-N' '-L' "localhost:${LocalPort}:${remoteSocket}" '--' $SshTarget
exit $LASTEXITCODE
