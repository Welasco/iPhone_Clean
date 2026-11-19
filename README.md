# iPhone Clean

A Windows PowerShell script for deleting media exposed by a USB-connected iPhone, with folder-by-folder confirmation, progress reporting, and recovery when the device stops responding.

> **Warning:** Treat deletion as permanent and irreversible. Back up your media independently before running the cleaner. Preserving `.AAE` files does not preserve the photos or videos they describe.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7.
- An iPhone connected by USB, unlocked, and trusted by Windows.
- The iPhone's Internal Storage must be accessible in Windows Explorer.

No additional PowerShell modules are required. The script accesses only the media storage Windows exposes, not the full iOS filesystem or private app folders.

## Get started

```powershell
git clone https://github.com/Welasco/iPhone_Clean.git
Set-Location .\iPhone_Clean
```

First, preview the folders and file counts without deleting anything:

```powershell
.\Clear-iPhoneMedia.ps1 -ListOnly
```

To describe the destructive operation without accessing the device:

```powershell
.\Clear-iPhoneMedia.ps1 -WhatIf
```

To start cleaning:

```powershell
.\Clear-iPhoneMedia.ps1
```

The script asks for initial confirmation. After counting the files in each folder, it offers:

| Answer | Action |
| --- | --- |
| `Y` or `Yes` | Delete eligible files in this folder only. |
| `A` or `All` | Delete eligible files in this folder and approve all remaining folders in the current pass. |
| Enter, `N`, or any other answer | Skip this folder without deleting its files. |

Approval for all folders resets after a reconnect/rescan. Folders without eligible files do not require confirmation.

## Processing and safeguards

The script first enumerates only the folders directly inside Internal Storage. It sorts that list by folder name, oldest first, using the iPhone's `YYYYMM_suffix` naming convention. For example:

```text
201812_a
202512_a
202601_a
202601_b
202610_a
```

It then opens each folder in that order and enumerates its immediate files to determine the total file count, protected AAE count, and eligible deletion count. File order is unchanged.

- `.AAE` files are excluded case-insensitively, including when Windows hides their extensions.
- Folders are never deleted, and subfolders are never traversed.
- Progress shows the current folder and confirmed deletions out of its eligible files.
- Windows Shell item identities are used instead of treating portable-device paths as normal filesystem paths.

Keep the iPhone unlocked while the script runs.

## Stalls and reconnecting

All device operations run in a separate worker process. After **30 seconds without progress**, the script terminates the worker, reports the last operation, and prompts you to reconnect the iPhone. Time spent answering a confirmation prompt does not count as a device stall.

After a stall:

1. Unplug and reconnect the iPhone.
2. Unlock it and accept any Trust/Allow prompt.
3. Press Enter at the script's recovery prompt to start a fresh pass, or type `Q` to stop.

Each new pass rescans Internal Storage and sorts the currently available folders again. It does not reuse folder names, file queues, or Windows Shell objects from the previous connection.

An in-flight deletion may finish before the worker is terminated. The next pass uses the current device contents rather than assuming whether that file was deleted. Reported deletion totals apply to the current pass.

Other operation errors are also displayed and stop the pass, but do not necessarily require reconnection. Resolve the reported error before retrying.

### Options

```powershell
# Change the no-progress timeout (5 to 3600 seconds)
.\Clear-iPhoneMedia.ps1 -StallTimeoutSeconds 20

# Select the device name shown under This PC in Windows Explorer
.\Clear-iPhoneMedia.ps1 -DeviceName 'Apple iPhone'
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-DeviceName` | `Apple iPhone` | Select the connected device by its Windows display name. |
| `-StallTimeoutSeconds` | `30` | Maximum time without worker progress before stopping it. |
| `-ListOnly` | Off | List root folders and count their files without deleting anything. |
| `-WhatIf` | Off | Describe the deletion operation without accessing the device. |

## Tests

```powershell
.\Test-Clear-iPhoneMedia.ps1
```

The tests use mocked device data, simulated worker processes, and uniquely named local temporary fixtures. They do not access or delete iPhone files. They cover folder ordering and rescans, confirmations and approve-all scope, AAE preservation, folder-deletion rejection, progress accounting, worker failures, and stall recovery.
