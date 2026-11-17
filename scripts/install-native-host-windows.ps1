# 只注册指定浏览器的当前用户宿主。一次安装后由浏览器按需启动同一个 PBsync.exe。
param(
    [Parameter(Mandatory=$true)][ValidateSet('Edge','Chrome','Firefox')][string]$Browser,
    [string]$Exe,
    [string]$ExtensionId,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$hostName = 'com.gcsa.pbsync'
$base = switch ($Browser) {
    'Edge'    { 'Software\Microsoft\Edge\NativeMessagingHosts' }
    'Chrome'  { 'Software\Google\Chrome\NativeMessagingHosts' }
    'Firefox' { 'Software\Mozilla\NativeMessagingHosts' }
}
$key = "$base\$hostName"
$directory = Join-Path $env:LOCALAPPDATA 'PBsync\NativeMessaging'
$manifest = Join-Path $directory ($Browser.ToLowerInvariant() + '.json')
$registry = [Microsoft.Win32.Registry]::CurrentUser
$previous = $registry.OpenSubKey($key)
if ($previous) {
    try {
        if ($previous.GetValue('') -ne $manifest) { throw '已有其他宿主使用该名称，保留原注册。' }
    } finally { $previous.Dispose() }
}
if ($Remove) {
    if ($previous) { $registry.DeleteSubKey($key, $false) }
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { Remove-Item -LiteralPath $manifest }
    return
}
if (!$Exe -or !$ExtensionId) { throw '请指定 PBsync.exe 路径和扩展 ID。' }
$binary = (Resolve-Path -LiteralPath $Exe).Path
if (![IO.File]::Exists($binary) -or [IO.Path]::GetFileName($binary) -ne 'PBsync.exe') { throw '需要 Windows 版 PBsync.exe。' }
$value = [ordered]@{name=$hostName;description='PBsync bookmark native messaging';path=$binary;type='stdio'}
if ($Browser -eq 'Firefox') {
    if ($ExtensionId -cne 'pbsync-bookmarks@gcsa.local') { throw '需要 PBsync 仅书签扩展的 Firefox ID。' }
    $value.allowed_extensions = @($ExtensionId)
} else {
    if ($ExtensionId -cnotmatch '^[a-p]{32}$') { throw '浏览器扩展 ID 无效。' }
    $value.allowed_origins = @("chrome-extension://$ExtensionId/")
}
[IO.Directory]::CreateDirectory($directory) | Out-Null
$temp = $manifest + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
try {
    [IO.File]::WriteAllText($temp, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($manifest)) { [IO.File]::Replace($temp, $manifest, $null) }
    else { [IO.File]::Move($temp, $manifest) }
    $handle = $registry.CreateSubKey($key)
    try { $handle.SetValue('', $manifest, [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $handle.Dispose() }
    Write-Output $manifest
} finally {
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
}
