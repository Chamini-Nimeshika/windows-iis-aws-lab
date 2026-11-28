#[CmdletBinding()] --> Makes a script/function an advanced script/function
[CmdletBinding()]
param(
    [string]$SiteName    = 'LabSite',
    [string]$AppPoolName = 'LabAppPool',
    [string]$SiteRoot    = 'C:\sites\lab',

    # .NET 10 Hosting Bundle (latest 10.0.x). If this link ever fails, open the .NET 10 download page,
    # right-click "click here to download manually" on the Hosting Bundle page, copy the link and pass it with -HostingBundleUrl.
    [string]$HostingBundleUrl = 'https://aka.ms/dotnet/10.0/dotnet-hosting-win.exe'
)

# Stop on the first error instead of carrying on with a half-configured server.
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 draws a progress bar during downloads that makes them many times slower; turn it off.
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Message) {
    Write-Output "`n==> $Message"
}

# ---------------------------------------------------------------------------
Write-Step '1. IIS role and features'
# Web-Server         = IIS itself (includes the default static-content features)
# Web-Http-Logging   = writes IIS access logs (C:\inetpub\logs\LogFiles) - your first stop in troubleshooting
# Web-Request-Monitor= shows requests currently running inside worker processes
$features = 'Web-Server', 'Web-Http-Logging', 'Web-Request-Monitor'
$missing  = $features | Where-Object { -not (Get-WindowsFeature -Name $_).Installed }
if ($missing) {
    Write-Output "Installing: $($missing -join ', ')"
    $result = Install-WindowsFeature -Name $missing -IncludeManagementTools   # also installs IIS Manager + the WebAdministration module
    if (-not $result.Success) { throw "IIS feature installation failed." }
} else {
    Write-Output 'Already installed.'
}

# The WebAdministration module (IIS: drive, *-Website, *-WebAppPool cmdlets) exists only after IIS is installed.
Import-Module WebAdministration

# ---------------------------------------------------------------------------
Write-Step '2. ASP.NET Core Hosting Bundle (.NET 10)'
# Two things must be true: IIS has the ASP.NET Core Module, AND the ASP.NET Core 10 runtime is present.
$ancmLoaded   = [bool](Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue)
$runtime10    = Test-Path "$env:ProgramFiles\dotnet\shared\Microsoft.AspNetCore.App\10.*"
if ($ancmLoaded -and $runtime10) {
    Write-Output 'Already installed.'
} else {
    $installer = Join-Path $env:TEMP 'dotnet-hosting-10-win.exe'
    Write-Output "Downloading $HostingBundleUrl"
    Invoke-WebRequest -Uri $HostingBundleUrl -OutFile $installer -UseBasicParsing

    Write-Output 'Installing silently (1-3 minutes)...'
    $proc = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    # 0 = success, 3010 = success but a reboot is recommended. Anything else is a failure.
    if ($proc.ExitCode -notin 0, 3010) { throw "Hosting Bundle installer failed with exit code $($proc.ExitCode)." }

    # IIS only loads newly installed modules after a restart of its services.
    Write-Output 'Restarting IIS services...'
    net stop was /y | Out-Null     # stops WAS and W3SVC (the services that run IIS)
    net start w3svc | Out-Null     # starts W3SVC again (WAS starts with it)
}

# ---------------------------------------------------------------------------
Write-Step '3. Verify the ASP.NET Core Module is registered in IIS'
if (-not (Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue)) {
    throw 'AspNetCoreModuleV2 not found. Re-run the Hosting Bundle installer, then restart IIS.'
}
Write-Output 'AspNetCoreModuleV2 is registered.'

# ---------------------------------------------------------------------------
Write-Step '4. Site folders'
# releases\ = one folder per deployed version (rollback = point the site back at an older one)
# current\  = the site's starting path until the first real deploy
# logs\     = ASP.NET Core stdout logs when you need to debug a startup failure
foreach ($dir in "$SiteRoot\releases", "$SiteRoot\current", "$SiteRoot\logs") {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
        Write-Output "Created $dir"
    }
}
# A placeholder page so you can prove IIS works before any app is deployed.
$placeholder = "$SiteRoot\current\index.html"
if (-not (Test-Path $placeholder)) {
    Set-Content -Path $placeholder -Value '<h1>LabSite is up. Waiting for the first deploy.</h1>'
}

# ---------------------------------------------------------------------------
Write-Step "5. App pool '$AppPoolName' (No Managed Code)"
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    New-WebAppPool -Name $AppPoolName | Out-Null
    Write-Output 'Created.'
}
# '' = No Managed Code. ASP.NET Core brings its own runtime; it does not use the .NET Framework CLR inside IIS.
# Setting a property to the value it already has changes nothing, so this line is idempotent by itself.
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value ''

# ---------------------------------------------------------------------------
Write-Step "6. Default Web Site off, '$SiteName' on port 80"
if (Test-Path 'IIS:\Sites\Default Web Site') {
    if ((Get-WebsiteState -Name 'Default Web Site').Value -ne 'Stopped') {
        Stop-Website -Name 'Default Web Site'
        Write-Output 'Stopped Default Web Site.'
    }
    # Also stop it auto-starting after a reboot, or it would grab port 80 again.
    Set-ItemProperty 'IIS:\Sites\Default Web Site' -Name serverAutoStart -Value $false
}

if (-not (Test-Path "IIS:\Sites\$SiteName")) {
    New-Website -Name $SiteName -Port 80 -PhysicalPath "$SiteRoot\current" -ApplicationPool $AppPoolName | Out-Null
    Write-Output "Created $SiteName."
}
if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') { Start-Website -Name $SiteName }

# ---------------------------------------------------------------------------
Write-Step '7. Folder permissions for the app pool identity'
# Each app pool runs as its own virtual account: "IIS AppPool\<pool name>".
# ${AppPoolName} needs braces here: "$AppPoolName:" would be read by PowerShell as a drive/scope prefix.
# (OI)(CI) = inherit to files and subfolders.  RX = read & execute.  M = modify (write logs).
icacls $SiteRoot           /grant "IIS AppPool\${AppPoolName}:(OI)(CI)RX" | Out-Null
icacls "$SiteRoot\logs"    /grant "IIS AppPool\${AppPoolName}:(OI)(CI)M"  | Out-Null
Write-Output 'Read on the site root, modify on logs.'

# ---------------------------------------------------------------------------
Write-Step '8. Windows Firewall allows HTTP'
# IIS creates this rule when it installs. Remember: traffic must ALSO pass the AWS security group.
$rules = Get-NetFirewallRule -DisplayName 'World Wide Web Services*' -ErrorAction SilentlyContinue
if (-not $rules) { throw 'IIS firewall rules not found.' }
$rules | Where-Object Enabled -ne 'True' | Enable-NetFirewallRule
$rules | Select-Object DisplayName, Enabled | Format-Table -AutoSize

# ---------------------------------------------------------------------------
Write-Step '9. Test from the server itself'
$response = Invoke-WebRequest -Uri 'http://localhost/' -UseBasicParsing
Write-Output "HTTP $($response.StatusCode): $($response.Content)"
if ($response.StatusCode -ne 200) { throw "Expected HTTP 200 from http://localhost/." }

Write-Output "`nDone. $SiteName is serving from $SiteRoot\current."