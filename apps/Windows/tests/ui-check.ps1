# 在远程 Windows 会话里驱动成品窗口。只使用指定的临时用户目录和合成数据。
param([Parameter(Mandatory=$true)][string]$Root, [int]$Port = 49176, [switch]$CaptureOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PBsyncUi {
    private delegate bool Enumerate(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Enumerate callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern int GetWindowThreadProcessId(IntPtr window, out int process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr window, int index);
    // WinRM does not show the ancestor desktop. Read the window's own visibility flag.
    public static bool IsWindowVisible(IntPtr window) { return (GetWindowLongW(window, -16) & 0x10000000) != 0; }
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int operation);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr w, string l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, int message, IntPtr w, IntPtr l);
    public static IntPtr Find(int process, string className) {
        IntPtr selected = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            int owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != process || (className != "PBsyncMainWindow" && !IsWindowVisible(window))) return true;
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != className) return true;
            selected = window;
            return false;
        }, IntPtr.Zero);
        return selected;
    }
    public static void Command(IntPtr window, int id) {
        IntPtr child = GetDlgItem(window, id);
        if (child == IntPtr.Zero || !IsWindowEnabled(child) || !IsWindowVisible(child))
            throw new InvalidOperationException("Control unavailable: " + id);
        PostMessage(window, 0x111, new IntPtr(id), child);
    }
    public static void SetText(IntPtr window, int id, string text) {
        if (SendMessage(GetDlgItem(window,id), 0x000C, IntPtr.Zero, text) == IntPtr.Zero)
            throw new InvalidOperationException("Text input failed: " + id);
    }
    public static string GetText(IntPtr window, int id) {
        var text = new StringBuilder(512);
        SendMessage(GetDlgItem(window,id), 0x000D, new IntPtr(text.Capacity), text);
        return text.ToString();
    }
    public static int Count(IntPtr window, int id) { return SendMessage(GetDlgItem(window,id), 0x018B, IntPtr.Zero, IntPtr.Zero).ToInt32(); }
    public static void Select(IntPtr window, int id, int index) {
        IntPtr item = GetDlgItem(window, id);
        if (SendMessage(item, 0x0186, new IntPtr(index), IntPtr.Zero).ToInt32() < 0)
            throw new InvalidOperationException("List selection failed");
        SendMessage(window, 0x111, new IntPtr((1 << 16) | id), item);
    }
    public static bool Capture(IntPtr window) { return SendMessage(window, 0x8011, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero; }
}
'@

function Wait-Until {
    param([string]$Label, [scriptblock]$Condition)
    $deadline = [DateTime]::UtcNow.AddSeconds(28)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 150
    }
    throw "Timed out: $Label"
}
function Open-Form {
    param([int]$Id)
    [PBsyncUi]::Command($window, $Id)
    Wait-Until 'native form' { [PBsyncUi]::Find($app.Id, 'PBsyncForm') -ne [IntPtr]::Zero }
    return [PBsyncUi]::Find($app.Id, 'PBsyncForm')
}
function Connect-Space {
    param([string]$Kind, [string]$Master, [int]$Expected)
    $form = Open-Form 106
    [PBsyncUi]::SetText($form, 500, "http://127.0.0.1:$Port/dav/$Kind/")
    [PBsyncUi]::SetText($form, 501, 'qa')
    [PBsyncUi]::SetText($form, 502, 'SYNTHETIC-webdav-secret')
    [PBsyncUi]::SetText($form, 503, $Master)
    [PBsyncUi]::Command($form, 1)
    Wait-Until "$Kind rows" { [PBsyncUi]::Count($window, 105) -eq $Expected }
}

$env:LOCALAPPDATA = Join-Path $Root ('ui-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item $env:LOCALAPPDATA -ItemType Directory)
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$books = 9
$passwords = 12
$executable = 'PBsync.exe'
if ($CaptureOnly) {
    $books = 10
    $passwords = 13
    $env:PBSYNC_QA_SCREENSHOT_DIR = $Root
    $executable = 'WindowCheck.exe'
}
$app = Start-Process (Join-Path $Root $executable) -PassThru
try {
    Wait-Until 'Win32 process window' { [PBsyncUi]::Find($app.Id, 'PBsyncMainWindow') -ne [IntPtr]::Zero }
    $window = [PBsyncUi]::Find($app.Id, 'PBsyncMainWindow')
    [void][PBsyncUi]::ShowWindow($window, 5)
    [void][PBsyncUi]::MoveWindow($window, 8, 8, 1176, 746, $true)
    Wait-Until 'visible native main window' { [PBsyncUi]::IsWindowVisible([PBsyncUi]::GetDlgItem($window, 102)) }
    [PBsyncUi]::Command($window, 102)
    Wait-Until 'synchronization view' { [PBsyncUi]::IsWindowVisible([PBsyncUi]::GetDlgItem($window, 121)) }
    [PBsyncUi]::Command($window, 121)
    Start-Sleep -Milliseconds 250
    [PBsyncUi]::Command($window, 100)
    Wait-Until 'bookmarks view' { [PBsyncUi]::IsWindowVisible([PBsyncUi]::GetDlgItem($window, 106)) }

    Connect-Space 'bookmarks' ([IO.File]::ReadAllText((Join-Path $Root 'bookmark-master')).Trim()) $books
    [PBsyncUi]::SetText($window, 103, 'MDN')
    Wait-Until 'search filtering' { [PBsyncUi]::Count($window, 105) -eq 1 }
    [PBsyncUi]::SetText($window, 103, 'MDN Web')
    Wait-Until 'search refinement' { [PBsyncUi]::Count($window, 105) -eq 1 }
    [PBsyncUi]::SetText($window, 103, '')
    Wait-Until 'clear search' { [PBsyncUi]::Count($window, 105) -eq $books }
    [PBsyncUi]::Select($window, 104, 1)
    Wait-Until 'folder navigation' { [PBsyncUi]::Count($window, 105) -eq 2 }
    [PBsyncUi]::Select($window, 104, 0)
    [PBsyncUi]::Select($window, 105, 1)
    if ($CaptureOnly -and ![PBsyncUi]::Capture($window)) { throw 'Render failed: bookmarks' }

    if (!$CaptureOnly) {
        $form = Open-Form 106
        [PBsyncUi]::SetText($form, 500, 'Windows GUI Test Bookmark')
        [PBsyncUi]::SetText($form, 501, 'https://native-gui.example.invalid/')
        [PBsyncUi]::Command($form, 1)
        Wait-Until 'bookmark publish' {
            [PBsyncUi]::Count($window, 105) -eq 10 -and [PBsyncUi]::IsWindowEnabled([PBsyncUi]::GetDlgItem($window, 101))
        }

    }

    [PBsyncUi]::Command($window, 101)
    Wait-Until 'password view' { ![PBsyncUi]::IsWindowVisible([PBsyncUi]::GetDlgItem($window, 104)) }
    Connect-Space 'vault' ([IO.File]::ReadAllText((Join-Path $Root 'vault-master')).Trim()) $passwords
    if ($CaptureOnly -and ![PBsyncUi]::Capture($window)) { throw 'Render failed: passwords' }
    if (!$CaptureOnly) {
        [PBsyncUi]::Command($window, 115)
        Wait-Until 'show password' { [PBsyncUi]::GetText($window, 115) -eq ('{0}{1}{2}{3}' -f [char]0x9690,[char]0x85CF,[char]0x5BC6,[char]0x7801) }
        [PBsyncUi]::Command($window, 115)
        $form = Open-Form 106
        [PBsyncUi]::SetText($form, 500, 'Windows GUI Test Login')
        [PBsyncUi]::SetText($form, 501, 'https://native-gui.example.invalid/')
        [PBsyncUi]::SetText($form, 502, 'synthetic-ui')
        [PBsyncUi]::SetText($form, 503, 'SYNTHETIC-gui-password')
        [PBsyncUi]::Command($form, 1)
        Wait-Until 'password publish' {
            [PBsyncUi]::Count($window, 105) -eq 13 -and [PBsyncUi]::IsWindowEnabled([PBsyncUi]::GetDlgItem($window, 102))
        }
    }
    [PBsyncUi]::Command($window, 102)
    Wait-Until 'connection view after sync' { [PBsyncUi]::IsWindowVisible([PBsyncUi]::GetDlgItem($window, 121)) }
    if ($CaptureOnly -and ![PBsyncUi]::Capture($window)) { throw 'Render failed: sync' }
    $external = @($app.Modules | Where-Object { $_.FileName -ne $app.Path -and
        $_.FileName -notmatch '^C:\\Windows\\(System32|WinSxS)\\' } | Select-Object -ExpandProperty FileName)
    if ($external.Count) { throw "Unexpected runtime modules: $($external -join ', ')" }
    [pscustomobject]@{
        executable = $app.Path
        version = (Get-Item $app.Path).VersionInfo.FileVersion
        session = $app.SessionId
        kernelModules = @($app.Modules).Count
        nonSystemModules = $external
        result = if ($CaptureOnly) {'three native UI views rendered'} else {
            'search, folder navigation, bookmark and login creation, and password reveal passed'
        }
    } | ConvertTo-Json -Compress
} finally {
    if (!$app.HasExited) { Stop-Process -Id $app.Id }
}
