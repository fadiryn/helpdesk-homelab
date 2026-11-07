<#
.SYNOPSIS
    Bulk-creates new hire accounts in Active Directory from a CSV file.

.DESCRIPTION
    For each row in the CSV, the script:
      - Builds a logon name (first initial + last name, lowercase)
      - Skips the user if that logon name already exists
      - Checks that the department OU and security group exist
      - Creates the account in OU=<Department>,OU=Corp
      - Fills in title, department and company
      - Sets a temporary password that must be changed at first logon
      - Adds the user to the SG-<Department> security group
    Every result is written to the screen and to a log file.

.PARAMETER CsvPath
    Path to the CSV file. Required columns: FirstName, LastName, Department, Title

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath C:\Scripts\new_hires.csv -WhatIf
    Test run: shows what would happen without creating anything.

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath C:\Scripts\new_hires.csv
    Real run: creates the accounts.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$DomainDN  = "DC=corp,DC=local",
    [string]$UpnSuffix = "corp.local",
    [string]$LogPath   = "C:\Scripts\Logs\onboarding_$(Get-Date -Format 'yyyy-MM-dd_HHmm').log"
)

Import-Module ActiveDirectory -ErrorAction Stop

# ---------- Setup ----------
if (-not (Test-Path $CsvPath)) { throw "CSV file not found: $CsvPath" }

$logFolder = Split-Path $LogPath
if (-not (Test-Path $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder -WhatIf:$false | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogPath -Value $line -WhatIf:$false
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Green }
    }
}

# ---------- Read and validate the CSV ----------
$users = @(Import-Csv -Path $CsvPath)
if ($users.Count -eq 0) { throw "CSV file has no rows: $CsvPath" }

$required = "FirstName", "LastName", "Department", "Title"
$missing  = $required | Where-Object { $_ -notin $users[0].PSObject.Properties.Name }
if ($missing) { throw "CSV is missing column(s): $($missing -join ', ')" }

$mode = if ($WhatIfPreference) { "TEST RUN (-WhatIf)" } else { "LIVE RUN" }
Write-Log "Starting bulk onboarding - $mode - $($users.Count) row(s) from $CsvPath"

# Ask for the temporary password once (never stored in the script or the CSV)
$tempPassword = Read-Host -AsSecureString "Enter the temporary password for new users"

$created = 0; $skipped = 0; $failed = 0

# ---------- Process each new hire ----------
foreach ($u in $users) {
    $first = "$($u.FirstName)".Trim()
    $last  = "$($u.LastName)".Trim()
    $dept  = "$($u.Department)".Trim()
    $title = "$($u.Title)".Trim()

    if (-not $first -or -not $last -or -not $dept) {
        Write-Log "FAILED row '$first $last' - first name, last name or department is empty" "ERROR"
        $failed++; continue
    }

    $displayName = "$first $last"
    $sam         = ($first.Substring(0, 1) + $last).ToLower() -replace '[^a-z0-9]', ''
    $ouPath      = "OU=$dept,OU=Corp,$DomainDN"
    $group       = "SG-$dept"

    # 1. Duplicate check
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
        Write-Log "SKIPPED $displayName - logon name '$sam' already exists" "WARN"
        $skipped++; continue
    }

    # 2. Department OU must exist
    try { Get-ADOrganizationalUnit -Identity $ouPath -ErrorAction Stop | Out-Null }
    catch {
        Write-Log "FAILED $displayName - department OU not found: $ouPath" "ERROR"
        $failed++; continue
    }

    # 3. Department group must exist
    try { Get-ADGroup -Identity $group -ErrorAction Stop | Out-Null }
    catch {
        Write-Log "FAILED $displayName - security group not found: $group" "ERROR"
        $failed++; continue
    }

    # 4. Create the user and add to the group
    $target = "$displayName ($sam) in $ouPath, member of $group"
    if ($PSCmdlet.ShouldProcess($target, "Create user")) {
        try {
            $params = @{
                Name                  = $displayName
                GivenName             = $first
                Surname               = $last
                DisplayName           = $displayName
                SamAccountName        = $sam
                UserPrincipalName     = "$sam@$UpnSuffix"
                Department            = $dept
                Company               = "Corp"
                Path                  = $ouPath
                AccountPassword       = $tempPassword
                ChangePasswordAtLogon = $true
                Enabled               = $true
            }
            if ($title) { $params.Title = $title }

            New-ADUser @params -ErrorAction Stop
            Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop

            Write-Log "CREATED $displayName ($sam) in $dept, added to $group"
            $created++
        }
        catch {
            Write-Log "FAILED $displayName ($sam) - $($_.Exception.Message)" "ERROR"
            $failed++
        }
    }
}

# ---------- Summary ----------
Write-Log "Finished ($mode). Created: $created  Skipped: $skipped  Failed: $failed"
Write-Log "Log file: $LogPath"
