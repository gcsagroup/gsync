param([string]$Root, [int]$ProcessId, [ValidateSet('ordered','edit','remaining','app-seed')][string]$Action)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$source=[IO.File]::ReadAllText((Join-Path $Root 'ui-check.ps1'))
$type=($source -split "Add-Type -TypeDefinition @'\r?\n",2)[1] -split "\r?\n'@",2
$listing=@'
    public static string Row(IntPtr window, int id, int index) {
        var text = new StringBuilder(1024);
        SendMessage(GetDlgItem(window,id), 0x0189, new IntPtr(index), text);
        return text.ToString();
    }
'@
Add-Type -TypeDefinition $type[0].Insert($type[0].LastIndexOf('}'),$listing)
function Wait-State([scriptblock]$Condition) {
    $until=[DateTime]::UtcNow.AddSeconds(16)
    while([DateTime]::UtcNow -lt $until) {
        if(& $Condition){return}
        Start-Sleep -Milliseconds 180
    }
    throw 'PBsync native window did not reach the expected state'
}
function Rows([int]$Id) {
    $count=[PBsyncUi]::Count($window,$Id)
    for($i=0;$i -lt $count;++$i){ [PBsyncUi]::Row($window,$Id,$i) }
}
$window=[PBsyncUi]::Find($ProcessId,'PBsyncMainWindow')
if($window -eq [IntPtr]::Zero){throw 'PBsync.exe window unavailable'}
[PBsyncUi]::Command($window,100)
Wait-State { [PBsyncUi]::IsWindowVisible([PBsyncUi]::GetDlgItem($window,104)) }
if($Action -eq 'app-seed'){
    if(@(Rows 105) -notcontains 'PBsync App Seed'){throw 'Missing initial app bookmark'}
    exit 0
}
Wait-State { @(Rows 104) -contains 'PBsync QA Folder' }
[PBsyncUi]::Select($window,104,[Array]::IndexOf(@(Rows 104),'PBsync QA Folder'))
switch($Action){
    'ordered' { Wait-State { (@(Rows 105) -join '|') -eq 'PBsync QA B|PBsync QA A' } }
    'edit' {
        Wait-State { (@(Rows 105) -join '|') -eq 'PBsync QA B|PBsync QA A' }
        [PBsyncUi]::Select($window,105,1)
        [PBsyncUi]::Command($window,110)
        Wait-State { [PBsyncUi]::Find($ProcessId,'PBsyncForm') -ne [IntPtr]::Zero }
        $form=[PBsyncUi]::Find($ProcessId,'PBsyncForm')
        [PBsyncUi]::SetText($form,500,'PBsync QA A from App')
        [PBsyncUi]::Command($form,1)
        Wait-State { (@(Rows 105) -join '|') -eq 'PBsync QA B|PBsync QA A from App' }
        [PBsyncUi]::Select($window,105,1)
        [PBsyncUi]::Command($window,112)
        Wait-State { (@(Rows 105) -join '|') -eq 'PBsync QA A from App|PBsync QA B' }
    }
    'remaining' { Wait-State { (@(Rows 105) -join '|') -eq 'PBsync QA A from App' } }
}
ConvertTo-Json -Compress -InputObject @(Rows 105)
