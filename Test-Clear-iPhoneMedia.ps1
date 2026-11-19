#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$cleaner = Join-Path $PSScriptRoot 'Clear-iPhoneMedia.ps1'
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($cleaner, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
. $cleaner -WhatIf

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

# This test process substitutes a recording deleter and never accesses the phone.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Management.Automation;
namespace iPhoneClean {
    public static class NativeDeletion {
        public static List<string> Deleted = new List<string>();
        public static string FailPath;
        public static void Delete(object item) {
            string path = (string)PSObject.AsPSObject(item).Properties["Path"].Value;
            if (path == FailPath) throw new InvalidOperationException("Simulated device failure");
            Deleted.Add(path);
        }
    }
}
'@

function New-TestNamespace {
    param([object[]] $Children)
    $result = [pscustomobject]@{ Children = $Children; Scans = 0 }
    $result | Add-Member ScriptMethod Items { $this.Scans++; return $this.Children }
    return $result
}

$nested = [pscustomobject]@{ Name = 'NeverOpen'; IsFolder = $true }
$nested | Add-Member ScriptProperty GetFolder { throw 'Subfolder traversal is forbidden.' }
$content = New-TestNamespace @(
    [pscustomobject]@{ Name = 'photo.JPG'; Path = 'device\photo.JPG'; IsFolder = $false },
    [pscustomobject]@{ Name = 'clip.MOV'; Path = 'device\clip.MOV'; IsFolder = $false },
    [pscustomobject]@{ Name = 'edit.AAE'; Path = 'device\edit.AAE'; IsFolder = $false },
    [pscustomobject]@{ Name = 'hidden-extension'; Path = 'device\hidden-extension.aae'; IsFolder = $false },
    [pscustomobject]@{ Name = 'suffix.aae.JPG'; Path = 'device\suffix.aae.JPG'; IsFolder = $false },
    $nested
)
$empty = New-TestNamespace @()
$root = New-TestNamespace @(
    [pscustomobject]@{ Name = '202611_a'; IsFolder = $true; GetFolder = $empty },
    [pscustomobject]@{ Name = '202610_a'; IsFolder = $true; GetFolder = $content }
)
$device = New-TestNamespace @(
    [pscustomobject]@{ Name = 'Internal Storage'; IsFolder = $true; GetFolder = $root }
)
$pc = New-TestNamespace @(
    [pscustomobject]@{ Name = 'Apple iPhone'; GetFolder = $device }
)
$script:fakeShell = [pscustomobject]@{ PC = $pc }
$script:fakeShell | Add-Member ScriptMethod Namespace { param($Id) return $this.PC }
function New-Object {
    param([string] $ComObject)
    if ($ComObject -ne 'Shell.Application') { throw 'Unexpected COM activation in test.' }
    return $script:fakeShell
}
$script:events = [System.Collections.Generic.List[object]]::new()
function Send-WorkerEvent {
    param([hashtable] $Data)
    $script:events.Add($Data)
}

$originalInput = [Console]::In
try {
    [Console]::SetIn([IO.StringReader]::new("DELETE`n"))
    Assert-True (Request-FolderApproval -Folder 'test' -Eligible 1 -Protected 0) 'Explicit approval must allow the folder.'
    [Console]::SetIn([IO.StringReader]::new("SKIP`n"))
    Assert-True (-not (Request-FolderApproval -Folder 'test' -Eligible 1 -Protected 0)) 'Skip must deny the folder.'
    [Console]::SetIn([IO.StringReader]::new(''))
    $rejected = $false
    try { Request-FolderApproval -Folder 'test' -Eligible 1 -Protected 0 } catch { $rejected = $true }
    Assert-True $rejected 'Missing approval must fail closed.'
}
finally {
    [Console]::SetIn($originalInput)
}
$script:events.Clear()
$script:approvals = [System.Collections.Generic.Queue[bool]]::new()
$script:approvalRequests = [System.Collections.Generic.List[object]]::new()
function Request-FolderApproval {
    param([string] $Folder, [int] $Eligible, [int] $Protected)
    if ($script:approvals.Count -eq 0) { throw 'Unexpected folder approval request.' }
    $script:approvalRequests.Add([pscustomobject]@{
        Folder = $Folder; DeletedBefore = [iPhoneClean.NativeDeletion]::Deleted.Count
    })
    return $script:approvals.Dequeue()
}

$ListOnly = $false
$script:approvals.Enqueue($true)
Invoke-DeviceWorker
$counted = @($script:events | Where-Object Type -eq 'Counted')
Assert-True ($root.Scans -eq 1) 'Root must be enumerated exactly once per pass.'
Assert-True ($counted[0].Files -eq 5) 'File counts must exclude directories.'
Assert-True ($counted[0].Protected -eq 2) 'AAE files must be protected even when extensions are hidden.'
Assert-True ($counted[0].Eligible -eq 3) 'Eligible count must exclude protected files.'
Assert-True ([iPhoneClean.NativeDeletion]::Deleted.Count -eq 3) 'Only eligible files may be deleted.'
Assert-True (-not ([iPhoneClean.NativeDeletion]::Deleted -match '\.aae$')) 'An AAE file was deleted.'
$types = @($script:events | ForEach-Object { $_.Type })
Assert-True ([array]::IndexOf($types, 'Folders') -lt [array]::IndexOf($types, 'Counting')) 'Root listing must finish before any folder is opened.'
$listing = @($script:events | Where-Object Type -eq 'Folders')[0]
Assert-True (($listing.Names -join ',') -eq '202610_a,202611_a') 'Folder listing must be oldest first, regardless of device enumeration order.'
Assert-True ($counted[1].Files -eq 0) 'Empty folders must be supported.'
Assert-True ($script:approvalRequests.Count -eq 1) 'Only folders with eligible files need approval.'
Assert-True ($script:approvalRequests[0].DeletedBefore -eq 0) 'Approval must precede deletion.'

[iPhoneClean.NativeDeletion]::Deleted.Clear()
$script:events.Clear()
$ListOnly = $true
Invoke-DeviceWorker
Assert-True ([iPhoneClean.NativeDeletion]::Deleted.Count -eq 0) 'ListOnly must never delete files.'
Assert-True ($root.Scans -eq 2) 'Each new pass must rescan the root.'
Assert-True ($script:approvalRequests.Count -eq 1) 'ListOnly must not ask for deletion approval.'

# Simulate a changed root after a reconnect, rather than retaining the original list.
$root.Children = @(
    [pscustomobject]@{ Name = '202701_a'; IsFolder = $true; GetFolder = $empty },
    [pscustomobject]@{ Name = '202601_b'; IsFolder = $true; GetFolder = $empty },
    [pscustomobject]@{ Name = '202512_a'; IsFolder = $true; GetFolder = $empty },
    [pscustomobject]@{ Name = '202601_a'; IsFolder = $true; GetFolder = $empty }
)
$script:events.Clear()
Invoke-DeviceWorker
$listing = @($script:events | Where-Object Type -eq 'Folders')[0]
Assert-True ($listing.Total -eq 4 -and ($listing.Names -join ',') -eq '202512_a,202601_a,202601_b,202701_a') 'Rescan must sort changed folder names by year, month, then suffix.'
$countingOrder = @($script:events | Where-Object Type -eq 'Counting' | ForEach-Object { $_.Folder })
Assert-True (($countingOrder -join ',') -eq ($listing.Names -join ',')) 'Folders must be opened in the same oldest-first order as the listing.'

$root.Children = @(
    [pscustomobject]@{ Name = '202611_b'; IsFolder = $true; GetFolder = $content },
    [pscustomobject]@{ Name = '202610_a'; IsFolder = $true; GetFolder = $content }
)
$ListOnly = $false
$script:events.Clear()
$script:approvalRequests.Clear()
$script:approvals.Enqueue($true)
$script:approvals.Enqueue($false)
Invoke-DeviceWorker
Assert-True ($script:approvalRequests.Count -eq 2) 'Each eligible folder must require its own approval.'
Assert-True (($script:approvalRequests.Folder -join ',') -eq '202610_a,202611_b') 'Deletion approval must follow oldest-first folder order.'
Assert-True ([iPhoneClean.NativeDeletion]::Deleted.Count -eq 3) 'Approving one folder must not approve the next.'
Assert-True (@($script:events | Where-Object { $_.Type -eq 'Deleted' -and $_.Folder -ne '202610_a' }).Count -eq 0) 'Deletion must target the oldest approved folder, not the device enumeration order.'
Assert-True (@($script:events | Where-Object Type -eq 'FolderSkipped').Count -eq 1) 'Declined folders must be reported as skipped.'

[iPhoneClean.NativeDeletion]::Deleted.Clear()
$root.Children = @([pscustomobject]@{ Name = '202610_a'; IsFolder = $true; GetFolder = $content })
$ListOnly = $false
$script:approvals.Enqueue($true)
[iPhoneClean.NativeDeletion]::FailPath = 'device\clip.MOV'
$script:events.Clear()
$failed = $false
try { Invoke-DeviceWorker } catch { $failed = $_.Exception.Message -like '*Simulated device failure*' }
Assert-True $failed 'A deletion failure must stop the pass.'
Assert-True ([iPhoneClean.NativeDeletion]::Deleted.Count -eq 1) 'Deletion must stop immediately after failure.'
Assert-True (@($script:events | Where-Object Type -eq 'Deleted').Count -eq 1) 'Only confirmed deletions may advance progress.'

function New-TestProcess {
    param([string] $Command)
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -STA -EncodedCommand $encoded"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $null = $process.Start()
    return $process
}

$ListOnly = $true
$process = New-TestProcess '[Console]::WriteLine(''IPHONE_EVENT:{"Type":"Complete","Deleted":0,"Protected":2}'')'
Assert-True (Watch-DeviceWorker $process) 'Successful worker must complete.'
$process = New-TestProcess '[Console]::WriteLine(''IPHONE_EVENT:{"Type":"Error","Message":"Simulated disconnect"}''); exit 1'
Assert-True (-not (Watch-DeviceWorker $process)) 'Worker errors must request recovery.'
$process = New-TestProcess 'exit 0'
Assert-True (-not (Watch-DeviceWorker $process)) 'Exit without completion must not count as success.'
$process = New-TestProcess '[Console]::WriteLine(''IPHONE_EVENT:{"Type":"Status","Message":"Simulated frozen device"}''); Start-Sleep -Seconds 120'
$workerId = $process.Id
$StallTimeoutSeconds = 5
Assert-True (-not (Watch-DeviceWorker $process)) 'A stalled worker must request recovery.'
Assert-True ($null -eq (Get-Process -Id $workerId -ErrorAction SilentlyContinue)) 'A stalled worker must be terminated before recovery.'

$ListOnly = $false
$script:promptAnswer = 'Y'
$script:promptDelay = 6
$script:promptCount = 0
function Read-Host {
    param([string] $Prompt)
    $script:promptCount++
    if ($script:promptDelay) { Start-Sleep -Seconds $script:promptDelay }
    return $script:promptAnswer
}
$approvalWorker = @'
[Console]::WriteLine('IPHONE_EVENT:{"Type":"ApprovalRequired","Folder":"202610_a","Eligible":3,"Protected":2}')
if ([Console]::In.ReadLine() -cne 'EXPECTED_RESPONSE') { exit 1 }
[Console]::WriteLine('IPHONE_EVENT:{"Type":"Complete","Deleted":0,"Protected":2}')
'@
$process = New-TestProcess $approvalWorker.Replace('EXPECTED_RESPONSE', 'DELETE')
Assert-True (Watch-DeviceWorker $process) 'Explicit folder approval must reach the worker; time spent answering must not trigger the stall watchdog.'
$script:promptDelay = 0
$twoFolderWorker = @'
foreach ($folder in @('202610_a', '202611_b')) {
    [Console]::WriteLine(('IPHONE_EVENT:{"Type":"ApprovalRequired","Folder":"' + $folder + '","Eligible":3,"Protected":2}'))
    if ([Console]::In.ReadLine() -cne 'DELETE') { exit 1 }
}
[Console]::WriteLine('IPHONE_EVENT:{"Type":"Complete","Deleted":0,"Protected":4}')
'@
$script:promptCount = 0
$process = New-TestProcess $twoFolderWorker
Assert-True (Watch-DeviceWorker $process) 'Y must approve each folder individually.'
Assert-True ($script:promptCount -eq 2) 'Y must not suppress the next folder confirmation.'
foreach ($allAnswer in @('A', 'all')) {
    $script:promptAnswer = $allAnswer
    $script:promptCount = 0
    $process = New-TestProcess $twoFolderWorker
    Assert-True (Watch-DeviceWorker $process) 'All must approve the current and remaining folders.'
    Assert-True ($script:promptCount -eq 1) 'All must stop asking for the remaining folders in the current pass.'
}
$script:promptAnswer = ''
$script:promptCount = 0
$process = New-TestProcess $approvalWorker.Replace('EXPECTED_RESPONSE', 'SKIP')
Assert-True (Watch-DeviceWorker $process) 'An empty answer must skip, never approve, deletion.'
Assert-True ($script:promptCount -eq 1) 'All approval must reset when a new pass starts after recovery.'

# Exercise the real COM interop only against a uniquely named local test file.
$escapedCleaner = $cleaner.Replace("'", "''")
$nativeTest = @'
$ErrorActionPreference = 'Stop'
. 'CLEANER_PATH' -WhatIf
Initialize-NativeDeletion
$fixture = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.iphone-clean-test')
$folderFixture = $fixture + '-folder'
$childFixture = Join-Path $folderFixture 'keep.txt'
try {
    [IO.File]::WriteAllText($fixture, 'Owned temporary deletion fixture')
    $shell = New-Object -ComObject Shell.Application
    $parent = $shell.Namespace([IO.Path]::GetDirectoryName($fixture))
    $fileItem = $parent.ParseName([IO.Path]::GetFileName($fixture))
    [iPhoneClean.NativeDeletion]::Delete($fileItem)
    if (Test-Path -LiteralPath $fixture) { throw 'Native deletion left the fixture behind.' }
    $null = [IO.Directory]::CreateDirectory($folderFixture)
    [IO.File]::WriteAllText($childFixture, 'Must survive folder deletion rejection')
    $folderItem = $parent.ParseName([IO.Path]::GetFileName($folderFixture))
    $rejected = $false
    try { [iPhoneClean.NativeDeletion]::Delete($folderItem) }
    catch { $rejected = $_.Exception.Message -like '*deleting folders is forbidden*' }
    if (-not $rejected -or -not (Test-Path -LiteralPath $childFixture)) {
        throw 'Native deletion must reject folders and preserve their contents.'
    }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force }
    if (Test-Path -LiteralPath $childFixture) { Remove-Item -LiteralPath $childFixture -Force }
    if (Test-Path -LiteralPath $folderFixture) { [IO.Directory]::Delete($folderFixture) }
}
'@
$process = New-TestProcess $nativeTest.Replace('CLEANER_PATH', $escapedCleaner)
$output = $process.StandardOutput.ReadToEndAsync()
$errors = $process.StandardError.ReadToEndAsync()
try {
    if (-not $process.WaitForExit(30000)) { throw 'Native deletion test timed out.' }
    Assert-True ($process.ExitCode -eq 0) ("Native deletion test failed: " + $errors.GetAwaiter().GetResult())
}
finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
Write-Host 'All tests passed. No iPhone files were accessed or deleted.'
