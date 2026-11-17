# 只在回环接口服务一个独立的合成收藏夹和密码库。
param(
    [Parameter(Mandatory=$true)][string]$Seed,
    [int]$Port = 49176
)
$ErrorActionPreference = 'Stop'
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$authorized = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('qa:SYNTHETIC-webdav-secret'))
$listener.Start()
try {
    while ($true) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            if ($request.Headers['Authorization'] -cne $authorized) { $response.StatusCode = 401; continue }
            $path = $request.Url.AbsolutePath
            if ($path -cnotmatch '^/dav/(bookmarks|vault)/(space\.pbsync|[a-f0-9-]{36}\.(pbop|pbatt))?$') {
                $response.StatusCode = 404; continue
            }
            $dir = Join-Path $Seed $Matches[1]
            $name = $Matches[2]
            $body = $null
            switch -CaseSensitive ($request.HttpMethod) {
                'GET' {
                    if (!$name -or !(Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf)) { $response.StatusCode = 404 }
                    else { $body = [IO.File]::ReadAllBytes((Join-Path $dir $name)); $response.StatusCode = 200 }
                }
                'PUT' {
                    if (!$name -or $request.Headers['If-None-Match'] -cne '*') { $response.StatusCode = 428; break }
                    if ($request.ContentLength64 -lt 0 -or $request.ContentLength64 -gt 2MB) { $response.StatusCode = 413; break }
                    $target = Join-Path $dir $name
                    if (Test-Path -LiteralPath $target) { $response.StatusCode = 412; break }
                    $file = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $request.InputStream.CopyTo($file) } finally { $file.Dispose() }
                    $response.StatusCode = 201
                }
                'PROPFIND' {
                    if ($name -or $request.Headers['Depth'] -ne '1') { $response.StatusCode = 400; break }
                    $contents = Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object {
                        if ($_.Name -cmatch '^(space\.pbsync|[a-f0-9-]{36}\.(pbop|pbatt))$') {
                            '<d:response><d:href>' + $path + $_.Name + '</d:href></d:response>'
                        }
                    }
                    $body = [Text.Encoding]::UTF8.GetBytes('<d:multistatus xmlns:d="DAV:">' + ($contents -join '') + '</d:multistatus>')
                    $response.ContentType = 'application/xml; charset=utf-8'
                    $response.StatusCode = 207
                }
                default { $response.StatusCode = 405 }
            }
            if ($body) { $response.ContentLength64 = $body.Length; $response.OutputStream.Write($body, 0, $body.Length) }
            else { $response.ContentLength64 = 0 }
        } catch { $response.StatusCode = 500 }
        finally { $response.Close() }
    }
} finally { $listener.Close() }
