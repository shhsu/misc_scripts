## This script Install updates and restart if needed
param(
    # action to take on the host
    [ValidateSet("SetupTaskAndRun", "SetupTask", "RemoveTask", "RunTask", "CleanUp")]
    $action,

    # the directory where patch logs are saved
    $logsDir = $(Join-Path $env:UserProfile logs),

    # max number of iterations this script can run, it's initialization + times rebooted
    $maxReboot = 10,

    # action to take on cleanup time. "Disable" ation should be used on debugging only as it allow easier inspection on what task look like
    [ValidateSet("Disable", "Remove")]
    $cleanupAction = "Remove",

    $scheduledTaskName = "OCIC Windows Patch Task",

    $scheduledTaskDescription = "This task is created by OCIC. It install Windows patches on boot and reboot if needed.",
    
    $errorLogPrefix = "ocic_setup_error_",

    $updateLogsPrefix = "ocic_windows_updates_",

    $initLogsPrefix = "ocic_setup_init_",

    $patchConclusionLog = "ocic_setup_result.log"
)

$ErrorActionPreference = "Stop"

$internetOptionsRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains"
$azureEdgeRoot = "${internetOptionsRoot}\azureedge.net"
$azureOneGetCdn = "${azureEdgeRoot}\onegetcdn"
$goMicrosoftRegPath = "${internetOptionsRoot}\microsoft.com\go"

function Test-RegistryKey {
    [OutputType('bool')]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key
    )

    if (Get-Item -Path $Key -ErrorAction Ignore) {
        $true
    }
}

function Test-RegistryValue {
    [OutputType('bool')]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    if (Get-ItemProperty -Path $Key -Name $Value -ErrorAction Ignore) {
        $true
    }
}

function Test-RegistryValueNotNull {
    [OutputType('bool')]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    if (($regVal = Get-ItemProperty -Path $Key -Name $Value -ErrorAction Ignore) -and $regVal.($Value)) {
        $true
    }
}

function Test-PendingRestart {
    [OutputType('bool')]
    [CmdletBinding()]

    # Added "test-path" to each test that did not leverage a custom function from above since
    # an exception is thrown when Get-ItemProperty or Get-ChildItem are passed a nonexistant key path
    $tests = @(
        { Test-RegistryKey -Key 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }
        { Test-RegistryKey -Key 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress' }
        { Test-RegistryKey -Key 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' }
        { Test-RegistryKey -Key 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending' }
        { Test-RegistryKey -Key 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting' }
        { Test-RegistryValueNotNull -Key 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Value 'PendingFileRenameOperations' }
        { Test-RegistryValueNotNull -Key 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Value 'PendingFileRenameOperations2' }
        {
            $regPath = 'HKLM:\SOFTWARE\Microsoft\Updates'
            if (Test-Path $regPath -PathType Container) {
                $updateReg = Get-Item $regPath
                if ($updateReg.UpdateExeVolatile) {
                    $true
                }
            }
            $false
        }
        { Test-RegistryValue -Key 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Value 'DVDRebootSignal' }
        { Test-RegistryKey -Key 'HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttemps' }
        { Test-RegistryValue -Key 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Value 'JoinDomain' }
        { Test-RegistryValue -Key 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Value 'AvoidSpnSet' }
        {
            # Added test to check first if keys exists, if not each group will return $Null
            # May need to evaluate what it means if one or both of these keys do not exist
            ( 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' | Where-Object { Test-Path $_ } | %{ (Get-ItemProperty -Path $_ ).ComputerName } ) -ne 
            ( 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' | Where-Object { Test-Path $_ } | %{ (Get-ItemProperty -Path $_ ).ComputerName } )
        }
        {
            # Added test to check first if key exists
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Services\Pending' | Where-Object { 
                (Test-Path $_) -and (Get-ChildItem -Path $_) } | ForEach-Object { $true }
        }
    )
    
    foreach ($test in $tests) {
        if (& $test) {
            return $true
        }
    }
    return $false
}

function CleanupRegKey {
    Remove-ItemProperty -Path $goMicrosoftRegPath -Name https -Confirm:$false -ErrorAction "Continue"
    Remove-Item -Recurse -Force $azureEdgeRoot -ErrorAction "Continue"
}

function CleanupTask {
    Unregister-ScheduledTask -TaskName $scheduledTaskName -Confirm:$false  -ErrorAction "Continue"
}

function CleanUp {
    WriteLogs "CleanUp removing reg keys..."
    CleanupRegKey
    WriteLogs "CleanUp removing task..."
    CleanupTask
    WriteLogs "CleanUp completed"
}

function GetLogsPath {
    param(
        $logsPrefix,
        $maxRecords
    )
    $ErrorActionPreference = "Stop"
    $recordsCount = (Get-ChildItem -Path $logsDir "${logsPrefix}*.log").Count
    if ($maxRecords -and ($recordsCount -ge $maxRecords)) {
        throw "Installation has rebooted ${maxRecords} times, this is unexpected. Manual intervention is required"
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH.mm.ss.fff"
    $logsPath = Join-Path $logsDir "${logsPrefix}${timestamp}.log"
    New-Item -ItemType File -Path $logsPath | Out-Null
    return $logsPath
}

function WriteLogs {
    param(
        $message
    )
    $timestamp = Get-Date -Format "O"
    $message = "[${timestamp}] $message"
    Write-Host $message
    if (!(Test-Path $script:initLogs)) {
        New-Item -ItemType File -Path $script:initLogs | Out-Null
    }
    Add-Content $script:initLogs $message -Force
}

function EnsureUpdatePrereq {
    $ErrorActionPreference = "Stop"
    if ((Get-Module -ListAvailable -Name PSWindowsUpdate).Count -le 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        WriteLogs "Allowing download against https://go.microsoft.com, https://onegetcdn.azureedge.net, https://www.powershellgallery.com"
        try {
            ## https://go.microsoft.com
            Set-ItemProperty -Path $goMicrosoftRegPath -Name https -Value 2

            ## https://onegetcdn.azureedge.net
            New-Item -Path $internetOptionsRoot -ItemType File -Name azureedge.net
            New-Item -Path $azureEdgeRoot -ItemType File -Name onegetcdn
            Set-ItemProperty -Path $azureOneGetCdn -Name https -Value 2

            WriteLogs "Installing NuGet"
            Install-PackageProvider -Name NuGet -Force
            WriteLogs "Installing PSWindowsUpdate"
            Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
            WriteLogs "Finished installing all prerequsites"
        } finally {
            CleanupRegKey
        }
    }
}

function SetupTask {
    $ErrorActionPreference = "Stop"
    WriteLogs "SetupTask started"
    EnsureUpdatePrereq
    ## NOTE: putting file in DVD drive messes up the file name. Hardcode for now

    $action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "$PSCommandPath -action RunTask"
    $trigger = New-JobTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopOnIdleEnd -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 5)
    $winUser = "Administrator"
    $winPassword = "Welcome1"
    Register-ScheduledTask -TaskName $scheduledTaskName -Action $action -Trigger $trigger -Description $scheduledTaskDescription -RunLevel Highest -User $winUser -Password $winPassword -Settings $settings
}

function SetupTaskAndRun {
    $ErrorActionPreference = "Stop"
    SetupTask
    WriteLogs "SetupTask succeeded, triggering first run..."
    Start-ScheduledTask -TaskName $scheduledTaskName -AsJob
}

function RemoveTask {
    $ErrorActionPreference = "Stop"
    WriteLogs "RemoveTask started"
    if ($cleanupAction -eq "Disable") {
        WriteLogs "RemoveTask is disabling $scheduledTaskName"
        Disable-ScheduledTask -TaskName $scheduledTaskName
    } else {
        CleanupTask
    }
    WriteLogs "RemoveTask completed"
}

function CMDRetryLoop {
    param(
        [int]
        $count,

        [int]
        $delay,

        [string]
        $cmd,

        [parameter(ValueFromRemainingArguments = $true)]
        [string[]]
        $args
    )
    $ErrorActionPreference = "Stop"
    for ($i = 0; $i -lt $count; $i++) {
        if ($i -gt 0) {
            WriteLogs "Script sleeps for $delay seconds for command to take effect"
            Start-Sleep $delay
        }
        $cmd = "$cmd $flags $args"
        WriteLogs "Caling $cmd, retry count: $i"
        cmd.exe /c $cmd
    }
}

function StartWindowsUpdateService() {
    $ErrorActionPreference = "Stop"
    $maxServiceStartCount = 10
    $serviceStartWait = 30
    $count = 0
    while ((Get-Service wuauserv).Status -ne "Running") {
        try {
            Start-Service wuauserv
            WriteLogs "Windows update servie started"
        } catch {
            $exceptionString = $_.Exception | Format-List -force
            WriteLogs "WARNING: failed to start service $exceptionString, waiting $serviceStartWait seconds to restart"
            if ($count -lt $maxServiceStartCount) {
                $count++
                Start-Sleep $serviceStartWait
            } else {
                throw $_
            }
        }
    }
}

function RunTask() {
    $ErrorActionPreference = "Stop"
    WriteLogs "RunTask is started"
    try {
        StartWindowsUpdateService
        $updateLogs = GetLogsPath -logsPrefix $updateLogsPrefix -maxRecords $maxReboot
        WriteLogs "RunTask will save logs to $updateLogs"
        # AutoReboot seens to bring down the VM completely for some reason. We will detect if reboot is required on our own
        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose 2>"${updateLogs}.err" 3>"${updateLogs}.warn" 4>"${updateLogs}.verbose" | Tee-Object -FilePath $updateLogs
        WriteLogs "Install-WindowsUpdate completed"
        if (Test-PendingRestart) {
            # In case our pending restart logic is bugged, add insurance
            if ((Get-ChildItem -Path $(Join-Path $logsDir "${updateLogsPrefix}*.log") | Where-Object { $_.Length -le 0 }).Count -ge 2) {
                WriteLogs "ERROR: Test-PendingRestart falsely identified system needed to restart, but there has already been 2 empty update iterations. Restart is skipped"
            } else {
                WriteLogs "Reboot required"
                CMDRetryLoop 10 90 SHUTDOWN /r /f /t 0
            }
        }
        if (!(Test-Path $updateLogs) -or ((Get-Item $updateLogs).Length -le 0)) {
            WriteLogs "Patch completed, results would be summarized in $patchReportPath"
            RemoveTask
            "$scheduledTaskName has successfully updated Windows, completion time: $(Get-Date -format O)" | Tee-Object -FilePath $patchReportPath
        }
        WriteLogs "RunTask completed, shutting down..."
        CMDRetryLoop 10 90 SHUTDOWN /s /f /t 0
    } catch {
        $errorReportPath = GetLogsPath $errorLogPrefix
        $exceptionString = $_.Exception | Format-List -force
        $exceptionString | Tee-Object -FilePath $errorReportPath
        WriteLogs "ERROR: RunTask encountered error, exception is saved in $errorReportPath"
        throw
    }
}

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$patchReportPath = Join-Path $logsDir $patchConclusionLog
if (Test-Path $patchReportPath) {
    WriteLogs "Task should be completed already"
    throw "Unexpected run"
}

$script:initLogs = GetLogsPath $initLogsPrefix
WriteLogs "$action starting..."
&$action
WriteLogs "$action complete..."
