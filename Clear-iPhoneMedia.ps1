#requires -Version 5.1
<#
.SYNOPSIS
Deletes Windows-accessible iPhone media while preserving AAE files.
.DESCRIPTION
Lists only the folders directly inside Internal Storage, then counts and processes
the files in each folder. Lists and processes folders oldest first by YYYYMM_suffix
name, including after reconnecting. Never traverses subfolders or deletes folders.
Before deleting any files in a folder, asks for explicit approval for that folder.
Y or Yes approves that folder; A or All approves it and all remaining folders
in the current pass. Approval resets after a reconnect/rescan.
Every device operation runs in a disposable process. If it stops reporting progress,
the process is terminated and you are prompted to reconnect the phone. Continuing
starts a new root scan; no folder names or COM objects survive reconnection.

Deletion is permanent. Back up your media first. This only accesses the media
storage Windows exposes, not the full iOS filesystem. Keep the phone unlocked.
.EXAMPLE
.\Clear-iPhoneMedia.ps1 -ListOnly
Lists folders and counts files without deleting anything.
.EXAMPLE
.\Clear-iPhoneMedia.ps1 -StallTimeoutSeconds 30
Asks for confirmation, then deletes non-AAE files with progress and reconnect support.
.EXAMPLE
.\Clear-iPhoneMedia.ps1 -WhatIf
Describes the destructive operation without accessing the device.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $DeviceName = 'Apple iPhone',

    [ValidateRange(5, 3600)]
    [int] $StallTimeoutSeconds = 30,

    [switch] $ListOnly,

    [Parameter(DontShow = $true)]
    [switch] $Worker,

    [Parameter(DontShow = $true)]
    [string] $WorkerToken
)

$ErrorActionPreference = 'Stop'

function Send-WorkerEvent {
    param([hashtable] $Data)
    [Console]::Out.WriteLine(('IPHONE_EVENT:' + ($Data | ConvertTo-Json -Compress -Depth 5)))
    [Console]::Out.Flush()
}

function Test-ProtectedMediaFile {
    param([string] $Name, [string] $Path)
    # Shell display names can hide extensions; also check the device parsing path.
    return ([System.IO.Path]::GetExtension($Name) -ieq '.aae' -or
        [System.IO.Path]::GetExtension($Path) -ieq '.aae')
}

function Request-FolderApproval {
    param([string] $Folder, [int] $Eligible, [int] $Protected)
    Send-WorkerEvent @{
        Type = 'ApprovalRequired'; Folder = $Folder
        Eligible = $Eligible; Protected = $Protected
    }
    $response = [Console]::In.ReadLine()
    switch -CaseSensitive ($response) {
        'DELETE' { return $true }
        'SKIP' { return $false }
        default { throw 'Folder approval was not received. No files in this folder will be deleted.' }
    }
}

function Initialize-NativeDeletion {
    if ('iPhoneClean.NativeDeletion' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace iPhoneClean
{
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr context, ref Guid handlerId, ref Guid interfaceId, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint kind, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOperation
    {
        void Advise(IntPtr sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(IntPtr window);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IShellItem item, IShellItem destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void MoveItems(IntPtr items, IShellItem destination);
        void CopyItem(IShellItem item, IShellItem destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        void CopyItems(IntPtr items, IShellItem destination);
        void DeleteItem(IShellItem item, IFileOperationProgressSink sink);
        void DeleteItems(IntPtr items);
        void NewItem(IShellItem destination, uint attributes,
            [MarshalAs(UnmanagedType.LPWStr)] string name,
            [MarshalAs(UnmanagedType.LPWStr)] string template, IntPtr sink);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }

    [ComVisible(true), Guid("04B0F1A7-9490-44BC-96E1-4296A31252E2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOperationProgressSink
    {
        [PreserveSig] int StartOperations();
        [PreserveSig] int FinishOperations(int result);
        [PreserveSig] int PreRenameItem(uint flags, IntPtr item,
            [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostRenameItem(uint flags, IntPtr item,
            [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IntPtr newItem);
        [PreserveSig] int PreMoveItem(uint flags, IntPtr item, IntPtr destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostMoveItem(uint flags, IntPtr item, IntPtr destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IntPtr newItem);
        [PreserveSig] int PreCopyItem(uint flags, IntPtr item, IntPtr destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostCopyItem(uint flags, IntPtr item, IntPtr destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IntPtr newItem);
        [PreserveSig] int PreDeleteItem(uint flags, IntPtr item);
        [PreserveSig] int PostDeleteItem(uint flags, IntPtr item, int result, IntPtr newItem);
        [PreserveSig] int PreNewItem(uint flags, IntPtr destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostNewItem(uint flags, IntPtr destination,
            [MarshalAs(UnmanagedType.LPWStr)] string name,
            [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes,
            int result, IntPtr newItem);
        [PreserveSig] int UpdateProgress(uint total, uint completed);
        [PreserveSig] int ResetTimer();
        [PreserveSig] int PauseTimer();
        [PreserveSig] int ResumeTimer();
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DeleteSink : IFileOperationProgressSink
    {
        public bool Completed;
        public int Result;
        public int StartOperations() { return 0; }
        public int FinishOperations(int result) { return 0; }
        public int PreRenameItem(uint f, IntPtr i, string n) { return 0; }
        public int PostRenameItem(uint f, IntPtr i, string n, int r, IntPtr x) { return 0; }
        public int PreMoveItem(uint f, IntPtr i, IntPtr d, string n) { return 0; }
        public int PostMoveItem(uint f, IntPtr i, IntPtr d, string n, int r, IntPtr x) { return 0; }
        public int PreCopyItem(uint f, IntPtr i, IntPtr d, string n) { return 0; }
        public int PostCopyItem(uint f, IntPtr i, IntPtr d, string n, int r, IntPtr x) { return 0; }
        public int PreDeleteItem(uint f, IntPtr i) { return 0; }
        public int PostDeleteItem(uint f, IntPtr i, int result, IntPtr x)
        {
            Completed = true;
            Result = result;
            return 0;
        }
        public int PreNewItem(uint f, IntPtr d, string n) { return 0; }
        public int PostNewItem(uint f, IntPtr d, string n, string t, uint a, int r, IntPtr x) { return 0; }
        public int UpdateProgress(uint t, uint c) { return 0; }
        public int ResetTimer() { return 0; }
        public int PauseTimer() { return 0; }
        public int ResumeTimer() { return 0; }
    }

    public static class NativeDeletion
    {
        [DllImport("shell32.dll")]
        static extern int SHGetIDListFromObject(
            [MarshalAs(UnmanagedType.IUnknown)] object folderItem, out IntPtr itemIdList);

        [DllImport("shell32.dll")]
        static extern int SHCreateItemFromIDList(IntPtr itemIdList,
            ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

        static void CheckResult(int result, string stage)
        {
            if (result < 0)
                throw new COMException(String.Format("{0} failed (HRESULT 0x{1:X8}).", stage, result), result);
        }

        public static void Delete(object folderItem)
        {
            IntPtr itemIdList = IntPtr.Zero;
            IShellItem item = null;
            IFileOperation operation = null;
            try
            {
                // Portable-device display paths are not reliably parseable. Use the
                // enumerated Shell object's identity, as Explorer does.
                CheckResult(SHGetIDListFromObject(folderItem, out itemIdList), "Read Shell item identity");
                Guid interfaceId = typeof(IShellItem).GUID;
                CheckResult(SHCreateItemFromIDList(itemIdList, ref interfaceId, out item),
                    "Create Shell item from identity");
                uint attributes;
                item.GetAttributes(0x20000000, out attributes);
                if ((attributes & 0x20000000) != 0)
                    throw new InvalidOperationException("Safety check: deleting folders is forbidden.");
                operation = (IFileOperation)Activator.CreateInstance(
                    Type.GetTypeFromCLSID(new Guid("3AD05575-8857-4850-9277-11B85BDB8E09")));
                // No undo/recycle flags: portable-device deletion is permanent.
                // Suppress shell dialogs so they cannot silently block the worker.
                operation.SetOperationFlags(0x0004 | 0x0010 | 0x0400 | 0x00100000);
                DeleteSink sink = new DeleteSink();
                operation.DeleteItem(item, sink);
                operation.PerformOperations();
                bool aborted;
                operation.GetAnyOperationsAborted(out aborted);
                if (aborted || !sink.Completed)
                    throw new InvalidOperationException("The device did not confirm deletion.");
                // Shell also reports completed leaf deletion as DONT_PROCESS_CHILDREN.
                // Other informational codes can mean skipped or pending, not deleted.
                if (sink.Result != 0 && sink.Result != 0x00270008)
                    throw new COMException(String.Format(
                        "The device returned deletion status 0x{0:X8}.", sink.Result), sink.Result);
            }
            finally
            {
                if (operation != null) Marshal.FinalReleaseComObject(operation);
                if (item != null) Marshal.FinalReleaseComObject(item);
                if (itemIdList != IntPtr.Zero) Marshal.FreeCoTaskMem(itemIdList);
            }
        }
    }
}
'@
}

function Invoke-DeviceWorker {
    Send-WorkerEvent @{ Type = 'Status'; Message = 'Connecting to the iPhone' }
    if (-not $ListOnly) { Initialize-NativeDeletion }
    $shell = New-Object -ComObject Shell.Application
    $devices = @($shell.Namespace(17).Items() | Where-Object { $_.Name -eq $DeviceName })
    if ($devices.Count -ne 1) {
        throw "Expected one '$DeviceName' device; found $($devices.Count). Unlock and trust the iPhone."
    }
    $storageRoots = @($devices[0].GetFolder.Items() | Where-Object { $_.IsFolder })
    if ($storageRoots.Count -ne 1) {
        throw "Expected one Internal Storage root; found $($storageRoots.Count). Unlock and trust the iPhone."
    }

    Send-WorkerEvent @{ Type = 'Status'; Message = 'Listing folders directly inside Internal Storage' }
    $root = $storageRoots[0].GetFolder
    if ($null -eq $root) { throw 'Cannot open Internal Storage.' }
    $folders = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $root.Items()) {
        if ($item.IsFolder) {
            $folders.Add([pscustomobject]@{ Name = $item.Name; Item = $item })
        }
        Send-WorkerEvent @{ Type = 'Heartbeat' }
    }
    $folders = @($folders | Sort-Object -Property Name)
    Send-WorkerEvent @{
        Type = 'Folders'; Names = @($folders | ForEach-Object { $_.Name }); Total = $folders.Count
    }

    $deletedTotal = 0
    $protectedTotal = 0
    for ($index = 0; $index -lt $folders.Count; $index++) {
        $folder = $folders[$index].Item
        $folderName = $folders[$index].Name
        Send-WorkerEvent @{
            Type = 'Counting'; Folder = $folderName
            Index = $index + 1; Total = $folders.Count
        }
        $namespace = $folder.GetFolder
        if ($null -eq $namespace) { throw "Cannot open folder '$folderName'." }
        $files = [System.Collections.Generic.List[object]]::new()
        $fileCount = 0
        $protected = 0
        $heartbeat = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($item in $namespace.Items()) {
            if (-not $item.IsFolder) {
                $fileCount++
                $fileName = $item.Name
                $filePath = $item.Path
                if ([string]::IsNullOrWhiteSpace($filePath)) {
                    throw "A file in '$folderName' has no device parsing path; refusing to process it."
                }
                if (Test-ProtectedMediaFile -Name $fileName -Path $filePath) {
                    $protected++
                }
                elseif (-not $ListOnly) {
                    $files.Add($item)
                }
            }
            if ($heartbeat.ElapsedMilliseconds -ge 1000) {
                Send-WorkerEvent @{ Type = 'Heartbeat' }
                $heartbeat.Restart()
            }
        }
        $eligible = $fileCount - $protected
        $protectedTotal += $protected
        Send-WorkerEvent @{
            Type = 'Counted'; Folder = $folderName; Files = $fileCount
            Protected = $protected; Eligible = $eligible
        }
        if ($files.Count -gt 0 -and -not (Request-FolderApproval -Folder $folderName -Eligible $eligible -Protected $protected)) {
            $files.Clear()
            Send-WorkerEvent @{ Type = 'FolderSkipped'; Folder = $folderName }
        }

        $deleted = 0
        foreach ($file in $files) {
            # Recheck the exclusions at the destructive boundary.
            if ($file.IsFolder) {
                throw 'Safety check: deleting folders is forbidden.'
            }
            if (Test-ProtectedMediaFile -Name $file.Name -Path $file.Path) {
                throw 'Safety check: an AAE file reached the deletion queue.'
            }
            [iPhoneClean.NativeDeletion]::Delete($file)
            $deleted++
            $deletedTotal++
            Send-WorkerEvent @{
                Type = 'Deleted'; Folder = $folderName; Deleted = $deleted
                Eligible = $eligible; DeletedTotal = $deletedTotal
            }
        }
        Send-WorkerEvent @{ Type = 'FolderDone'; Folder = $folderName; Index = $index + 1 }
    }
    Send-WorkerEvent @{
        Type = 'Complete'; Deleted = $deletedTotal; Protected = $protectedTotal
    }
}

function Start-DeviceWorker {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $info.FileName)) {
        $info.FileName = Join-Path $PSHOME 'pwsh.exe'
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $token = [guid]::NewGuid().ToString('N')
    $info.EnvironmentVariables['IPHONE_CLEAN_WORKER_TOKEN'] = $token
    # EncodedCommand avoids Windows argument quoting issues in script/device names.
    $scriptLiteral = $PSCommandPath.Replace("'", "''")
    $deviceLiteral = $DeviceName.Replace("'", "''")
    $command = "& '$scriptLiteral' -Worker -WorkerToken '$token' -DeviceName '$deviceLiteral'"
    if ($ListOnly) { $command += ' -ListOnly' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -STA -EncodedCommand $encoded"
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Unable to start the device worker.' }
    return $process
}

function Watch-DeviceWorker {
    param([System.Diagnostics.Process] $Process)
    $stderr = $Process.StandardError.ReadToEndAsync()
    $pending = $Process.StandardOutput.ReadLineAsync()
    $idle = [System.Diagnostics.Stopwatch]::StartNew()
    $lastOperation = 'Starting the device worker'
    $completed = $false
    $workerError = $null
    $folderTotal = 0
    $deleted = 0
    $approveAll = $false
    try {
        while ($true) {
            if ($pending.Wait(200)) {
                $line = $pending.GetAwaiter().GetResult()
                if ($null -eq $line) { break }
                if (-not $line.StartsWith('IPHONE_EVENT:')) {
                    throw "Unexpected worker output: $line"
                }
                $event = $line.Substring(13) | ConvertFrom-Json
                $idle.Restart()
                switch ($event.Type) {
                    'Status' {
                        $lastOperation = $event.Message
                        Write-Host $lastOperation
                    }
                    'Heartbeat' {}
                    'Folders' {
                        $folderTotal = $event.Total
                        Write-Host ("Found {0} root folders: {1}" -f $folderTotal, ($event.Names -join ', '))
                    }
                    'Counting' {
                        $lastOperation = "Counting files in $($event.Folder)"
                        Write-Progress -Id 1 -Activity 'iPhone folders' -Status "$($event.Index) / $folderTotal - $($event.Folder)" -PercentComplete ((($event.Index - 1) / $folderTotal) * 100)
                        Write-Progress -Id 2 -ParentId 1 -Activity $lastOperation -Status 'Enumerating files; deletion has not started' -PercentComplete -1
                    }
                    'Counted' {
                        $lastOperation = "Files in $($event.Folder)"
                        Write-Host ("{0}: {1} files, {2} AAE preserved, {3} eligible" -f $event.Folder, $event.Files, $event.Protected, $event.Eligible)
                        if (-not $ListOnly) {
                            Write-Progress -Id 2 -ParentId 1 -Activity $lastOperation -Status "0 / $($event.Eligible) deleted" -PercentComplete 0
                        }
                    }
                    'ApprovalRequired' {
                        if ($ListOnly -or $event.Eligible -le 0) {
                            throw 'Unexpected folder approval request; refusing deletion.'
                        }
                        Write-Progress -Id 2 -ParentId 1 -Activity 'Folder files' -Completed
                        $approved = $approveAll
                        if (-not $approveAll) {
                            $answer = Read-Host "Permanently delete $($event.Eligible) files in '$($event.Folder)'? $($event.Protected) AAE files and the folder itself will be kept. Y = this folder, A = all remaining folders this pass, Enter/N = skip [y/a/N]"
                            $approveAll = $answer -ieq 'A' -or $answer -ieq 'All'
                            $approved = $approveAll -or $answer -ieq 'Y' -or $answer -ieq 'Yes'
                            if ($approveAll) {
                                Write-Host 'Approved all remaining folders for this pass. Confirmation resets after a reconnect/rescan.'
                            }
                        }
                        $response = if ($approved) { 'DELETE' } else { 'SKIP' }
                        $Process.StandardInput.WriteLine($response)
                        $Process.StandardInput.Flush()
                        # Human decision time is not a device stall.
                        $idle.Restart()
                        $lastOperation = if ($approved) { "Deleting files in $($event.Folder)" } else { "Skipping $($event.Folder)" }
                    }
                    'FolderSkipped' { Write-Host "Skipped '$($event.Folder)'; no files in this folder were deleted." }
                    'Deleted' {
                        $deleted = $event.DeletedTotal
                        Write-Progress -Id 2 -ParentId 1 -Activity $lastOperation -Status "$($event.Deleted) / $($event.Eligible) deleted" -PercentComplete (($event.Deleted / $event.Eligible) * 100)
                    }
                    'FolderDone' {
                        Write-Progress -Id 2 -ParentId 1 -Activity 'Folder files' -Completed
                        Write-Progress -Id 1 -Activity 'iPhone folders' -Status "$($event.Index) / $folderTotal completed" -PercentComplete (($event.Index / $folderTotal) * 100)
                    }
                    'Error' { $workerError = $event.Message }
                    'Complete' {
                        $completed = $true
                        if ($ListOnly) {
                            Write-Host 'Listing complete. No files were deleted.'
                        }
                        else {
                            Write-Host "Pass complete: $($event.Deleted) files deleted; $($event.Protected) AAE files preserved."
                        }
                    }
                    default { throw "Unknown worker event '$($event.Type)'." }
                }
                $pending = $Process.StandardOutput.ReadLineAsync()
            }
            elseif ($idle.Elapsed.TotalSeconds -ge $StallTimeoutSeconds) {
                Write-Warning "No device progress for $StallTimeoutSeconds seconds. Stopped the worker during: $lastOperation. Reconnect the iPhone before continuing."
                Write-Warning 'An in-flight delete may already have completed. The next pass will rescan current device contents.'
                return $false
            }
        }
        if (-not $Process.WaitForExit(5000)) { throw 'The worker did not exit after closing its output.' }
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($workerError -or $Process.ExitCode -ne 0 -or -not $completed) {
            Write-Warning "Device pass failed during: $lastOperation. Confirmed deletions this pass: $deleted."
            if ($workerError) { Write-Warning $workerError }
            if ($errorText) { Write-Warning $errorText }
            return $false
        }
        return $true
    }
    finally {
        try {
            if (-not $Process.HasExited) {
                $Process.Kill()
                if (-not $Process.WaitForExit(5000)) {
                    throw "Worker PID $($Process.Id) did not stop. Do not retry until it has exited."
                }
            }
        }
        finally {
            $Process.Dispose()
            Write-Progress -Id 2 -Activity 'Folder files' -Completed
            Write-Progress -Id 1 -Activity 'iPhone folders' -Completed
        }
    }
}

if ($Worker) {
    if (-not $WorkerToken -or $WorkerToken -cne $env:IPHONE_CLEAN_WORKER_TOKEN) {
        throw 'Worker mode is internal. Run this script without -Worker.'
    }
    try {
        Invoke-DeviceWorker
        exit 0
    }
    catch {
        Send-WorkerEvent @{ Type = 'Error'; Message = $_.Exception.Message }
        exit 1
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
if (-not $ListOnly -and -not $PSCmdlet.ShouldProcess(
    "$DeviceName - all files directly inside all Internal Storage root folders, excluding .AAE",
    'PERMANENTLY DELETE media (back up first; cannot undo)'
)) { return }

while ($true) {
    $process = Start-DeviceWorker
    if (Watch-DeviceWorker -Process $process) { break }
    Write-Warning 'If the device stalled or disconnected, unplug/reconnect it, unlock it, and accept Trust/Allow if prompted. Other errors may not require reconnection.'
    $answer = Read-Host 'After resolving the error or reconnecting, press Enter to rescan from scratch, or type Q to stop'
    if ($answer -ieq 'Q') { break }
}
