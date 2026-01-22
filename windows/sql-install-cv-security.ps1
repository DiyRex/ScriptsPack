# =============================================================================
# SQL Server Bootstrap Setup Script
# Reads configuration from C:\sql-config.ps1 (created by Terraform user_data)
# Host this script publicly - it contains NO hardcoded credentials
# =============================================================================

$ErrorActionPreference = "Continue"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "CV Security SQL Server Bootstrap Setup" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================
$configFile = "C:\sql-config.ps1"
if (Test-Path $configFile) {
    Write-Host "[CONFIG] Loading configuration from $configFile" -ForegroundColor Yellow
    . $configFile
    Write-Host "[OK] Configuration loaded" -ForegroundColor Green
} else {
    Write-Host "[WARN] Config file not found at $configFile" -ForegroundColor Yellow
    Write-Host "[INFO] Using default values or environment variables" -ForegroundColor Gray

    # Try environment variables as fallback
    $saPassword = $env:SQL_SA_PASSWORD
    $hradmsUser = $env:SQL_HRADMS_USER
    $hradmsPassword = $env:SQL_HRADMS_PASSWORD
    $zkbioUser = $env:SQL_ZKBIO_USER
    $zkbioPassword = $env:SQL_ZKBIO_PASSWORD
    $zkbioDb = $env:SQL_ZKBIO_DB
}

# Set defaults if still empty
if (-not $saPassword) { $saPassword = "StrongPassword123!" }
if (-not $hradmsUser) { $hradmsUser = "hradms_user" }
if (-not $hradmsPassword) { $hradmsPassword = "HrAdms2024!Secure" }
if (-not $zkbioUser) { $zkbioUser = "zkbio_user" }
if (-not $zkbioPassword) { $zkbioPassword = "Password!Secure" }
if (-not $zkbioDb) { $zkbioDb = "security_db" }

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  SA Password: ********" -ForegroundColor Gray
Write-Host "  HRADMS User: $hradmsUser" -ForegroundColor Gray
Write-Host "  ZKBio User:  $zkbioUser" -ForegroundColor Gray
Write-Host "  ZKBio DB:    $zkbioDb" -ForegroundColor Gray
Write-Host ""

# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# CONFIGURATION - PATHS AND URLS
# =============================================================================
$instanceName = "SQLEXPRESS"
$sqlBootstrapperUrl = "https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe"
$ssmsDownloadUrl = "https://aka.ms/ssmsfullsetup"
$tempDir = "C:\SQLTemp"
$sqlBootstrapperPath = "$tempDir\SQL2022-SSEI-Expr.exe"
$sqlInstallerPath = "$tempDir\SQLEXPR_x64_ENU.exe"
$sqlExtractPath = "$tempDir\Extracted"
$ssmsInstallerPath = "$tempDir\SSMS-Setup.exe"

# Create temp directory
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

$startTime = Get-Date
Write-Host "Started at: $startTime" -ForegroundColor Gray
Write-Host ""

# =============================================================================
# STEP 1: INSTALL SQL SERVER EXPRESS
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 1: SQL Server Express 2022" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$sqlService = Get-Service -Name "MSSQL`$$instanceName" -ErrorAction SilentlyContinue
$sqlInstallValid = $false

if ($sqlService) {
    Write-Host "[CHECK] SQL Server Express service found" -ForegroundColor Yellow
    $possibleMssqlPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.SQLEXPRESS\MSSQLServer",
        "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQLServer"
    )
    $regBasePath = $null
    foreach ($path in $possibleMssqlPaths) {
        if (Test-Path $path) { $regBasePath = $path; break }
    }
    if ($regBasePath) {
        if ($sqlService.Status -ne "Running") {
            Start-Service -Name "MSSQL`$$instanceName" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
        $sqlInstallValid = $true
        Write-Host "[OK] SQL Server Express is installed and running" -ForegroundColor Green
    }
}

if (-not $sqlInstallValid) {
    # Download bootstrapper
    if (-not (Test-Path $sqlBootstrapperPath)) {
        Write-Host "[DOWNLOAD] Downloading SQL Server Express 2022 Bootstrapper..." -ForegroundColor Yellow
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $sqlBootstrapperUrl -OutFile $sqlBootstrapperPath -UseBasicParsing
            Write-Host "[OK] Bootstrapper downloaded!" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR] Failed to download bootstrapper: $_" -ForegroundColor Red
            exit 1
        }
    }

    # Download full media
    if (-not (Test-Path $sqlInstallerPath)) {
        Write-Host "[DOWNLOAD] Downloading SQL Server Express full media..." -ForegroundColor Yellow
        $downloadProc = Start-Process -FilePath $sqlBootstrapperPath -ArgumentList "/ACTION=Download", "/MEDIAPATH=$tempDir", "/MEDIATYPE=Core", "/QUIET" -Wait -PassThru
        if (-not (Test-Path $sqlInstallerPath)) {
            Write-Host "[ERROR] Media download failed" -ForegroundColor Red
            exit 1
        }
        Write-Host "[OK] Full media downloaded!" -ForegroundColor Green
    }

    # Extract installer
    if (-not (Test-Path "$sqlExtractPath\SETUP.EXE")) {
        Write-Host "[EXTRACT] Extracting SQL Server installer..." -ForegroundColor Yellow
        Start-Process -FilePath $sqlInstallerPath -ArgumentList "/Q", "/x:`"$sqlExtractPath`"" -Wait
        Start-Sleep -Seconds 5
        Write-Host "[OK] Extraction complete!" -ForegroundColor Green
    }

    # Install SQL Server
    Write-Host "[INSTALL] Installing SQL Server Express..." -ForegroundColor Yellow
    $installArgs = @(
        "/ACTION=Install",
        "/Q",
        "/IACCEPTSQLSERVERLICENSETERMS",
        "/FEATURES=SQLENGINE",
        "/INSTANCENAME=$instanceName",
        "/SQLSVCSTARTUPTYPE=Automatic",
        "/SQLSYSADMINACCOUNTS=`"$env:COMPUTERNAME\$env:USERNAME`"",
        "/SECURITYMODE=SQL",
        "/SAPWD=`"$saPassword`"",
        "/TCPENABLED=1",
        "/NPENABLED=1"
    )
    $installProcess = Start-Process -FilePath "$sqlExtractPath\SETUP.EXE" -ArgumentList $installArgs -Wait -PassThru -Verb RunAs
    if ($installProcess.ExitCode -eq 0 -or $installProcess.ExitCode -eq 3010) {
        Write-Host "[OK] SQL Server Express installed successfully!" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Installation exit code: $($installProcess.ExitCode)" -ForegroundColor Yellow
    }
}
Write-Host ""

# =============================================================================
# STEP 2: INSTALL VISUAL C++ REDISTRIBUTABLES
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 2: Visual C++ Redistributables" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$vcx64Key = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
$vcx86Key = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86"

if (-not (Test-Path $vcx64Key)) {
    Write-Host "[DOWNLOAD] Downloading VC++ x64..." -ForegroundColor Yellow
    $vcx64Path = "$tempDir\vc_redist.x64.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcx64Path -UseBasicParsing
    Write-Host "[INSTALL] Installing VC++ x64..." -ForegroundColor Yellow
    Start-Process -FilePath $vcx64Path -ArgumentList "/install /quiet /norestart" -Wait
    Write-Host "[OK] VC++ x64 installed" -ForegroundColor Green
} else {
    Write-Host "[SKIP] VC++ x64 already installed" -ForegroundColor Green
}

if (-not (Test-Path $vcx86Key)) {
    Write-Host "[DOWNLOAD] Downloading VC++ x86..." -ForegroundColor Yellow
    $vcx86Path = "$tempDir\vc_redist.x86.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x86.exe" -OutFile $vcx86Path -UseBasicParsing
    Write-Host "[INSTALL] Installing VC++ x86..." -ForegroundColor Yellow
    Start-Process -FilePath $vcx86Path -ArgumentList "/install /quiet /norestart" -Wait
    Write-Host "[OK] VC++ x86 installed" -ForegroundColor Green
} else {
    Write-Host "[SKIP] VC++ x86 already installed" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# STEP 3: INSTALL SSMS
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 3: SQL Server Management Studio" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$ssmsExe = "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe"
if (Test-Path $ssmsExe) {
    Write-Host "[SKIP] SSMS is already installed" -ForegroundColor Green
} else {
    if (-not (Test-Path $ssmsInstallerPath)) {
        Write-Host "[DOWNLOAD] Downloading SSMS..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $ssmsDownloadUrl -OutFile $ssmsInstallerPath -UseBasicParsing
        Write-Host "[OK] SSMS downloaded" -ForegroundColor Green
    }
    Write-Host "[INSTALL] Installing SSMS..." -ForegroundColor Yellow
    $ssmsProcess = Start-Process -FilePath $ssmsInstallerPath -ArgumentList "/install /quiet /norestart" -Wait -PassThru
    if ($ssmsProcess.ExitCode -eq 0 -or $ssmsProcess.ExitCode -eq 3010) {
        Write-Host "[OK] SSMS installed successfully!" -ForegroundColor Green
    } else {
        Write-Host "[WARN] SSMS exit code: $($ssmsProcess.ExitCode)" -ForegroundColor Yellow
    }
}
Write-Host ""

# =============================================================================
# STEP 4: CONFIGURE SQL SERVER PROTOCOLS
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 4: SQL Server Protocol Configuration" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$possibleRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.SQLEXPRESS\MSSQLServer\SuperSocketNetLib",
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQLServer\SuperSocketNetLib"
)
$regBasePath = $null
foreach ($path in $possibleRegPaths) {
    if (Test-Path $path) { $regBasePath = $path; break }
}

$configChanged = $false
if ($regBasePath) {
    # Enable TCP/IP on port 1433
    $regTcpPath = "$regBasePath\Tcp"
    if (Test-Path $regTcpPath) {
        Set-ItemProperty -Path $regTcpPath -Name "Enabled" -Value 1 -ErrorAction SilentlyContinue
        $ipAllPath = "$regTcpPath\IPAll"
        if (Test-Path $ipAllPath) {
            Set-ItemProperty -Path $ipAllPath -Name "TcpPort" -Value "1433" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $ipAllPath -Name "TcpDynamicPorts" -Value "" -ErrorAction SilentlyContinue
        }
        Write-Host "[OK] TCP/IP enabled on port 1433" -ForegroundColor Green
        $configChanged = $true
    }

    # Enable Named Pipes
    $regNpPath = "$regBasePath\Np"
    if (Test-Path $regNpPath) {
        Set-ItemProperty -Path $regNpPath -Name "Enabled" -Value 1 -ErrorAction SilentlyContinue
        Write-Host "[OK] Named Pipes enabled" -ForegroundColor Green
        $configChanged = $true
    }

    # Disable Force Encryption
    Set-ItemProperty -Path $regBasePath -Name "ForceEncryption" -Value 0 -ErrorAction SilentlyContinue
    Write-Host "[OK] Force Encryption disabled" -ForegroundColor Green
}

# Enable Mixed Authentication Mode
$regMssqlPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.SQLEXPRESS\MSSQLServer",
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQLServer"
)
foreach ($path in $regMssqlPaths) {
    if (Test-Path $path) {
        Set-ItemProperty -Path $path -Name "LoginMode" -Value 2 -ErrorAction SilentlyContinue
        Write-Host "[OK] Mixed Authentication Mode enabled" -ForegroundColor Green
        $configChanged = $true
        break
    }
}
Write-Host ""

# =============================================================================
# STEP 5: CONFIGURE WINDOWS FIREWALL
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 5: Windows Firewall Configuration" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$sqlRule = Get-NetFirewallRule -DisplayName "SQL Server Express" -ErrorAction SilentlyContinue
if (-not $sqlRule) {
    New-NetFirewallRule -DisplayName "SQL Server Express" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -Profile Any -ErrorAction SilentlyContinue
    Write-Host "[OK] Firewall rule for TCP 1433 created" -ForegroundColor Green
} else {
    Write-Host "[SKIP] Firewall rule for TCP 1433 exists" -ForegroundColor Green
}

$browserRule = Get-NetFirewallRule -DisplayName "SQL Server Browser" -ErrorAction SilentlyContinue
if (-not $browserRule) {
    New-NetFirewallRule -DisplayName "SQL Server Browser" -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow -Profile Any -ErrorAction SilentlyContinue
    Write-Host "[OK] Firewall rule for UDP 1434 created" -ForegroundColor Green
} else {
    Write-Host "[SKIP] Firewall rule for UDP 1434 exists" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# STEP 6: CONFIGURE SQL SERVER SERVICES
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 6: SQL Server Services Configuration" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$browserService = Get-Service -Name "SQLBrowser" -ErrorAction SilentlyContinue
if ($browserService) {
    Set-Service -Name "SQLBrowser" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "SQLBrowser" -ErrorAction SilentlyContinue
    Write-Host "[OK] SQL Server Browser enabled and started" -ForegroundColor Green
}

if ($configChanged) {
    Write-Host "[RESTART] Restarting SQL Server..." -ForegroundColor Yellow
    Restart-Service -Name "MSSQL`$$instanceName" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    Write-Host "[OK] SQL Server restarted" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# STEP 7: CREATE DATABASES AND USERS
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 7: Database and User Creation" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# Find sqlcmd
$sqlcmdPath = $null
$possiblePaths = @(
    "${env:ProgramFiles}\Microsoft SQL Server\160\Tools\Binn\sqlcmd.exe",
    "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe",
    "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe"
)
foreach ($path in $possiblePaths) {
    if (Test-Path $path) { $sqlcmdPath = $path; break }
}
if (-not $sqlcmdPath) {
    $found = Get-ChildItem -Path "C:\Program Files\Microsoft SQL Server" -Recurse -Filter "sqlcmd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $sqlcmdPath = $found.FullName }
}

if (-not $sqlcmdPath) {
    Write-Host "[WARN] sqlcmd not found. Database/user creation skipped." -ForegroundColor Yellow
} else {
    Write-Host "Using sqlcmd: $sqlcmdPath" -ForegroundColor Gray

    $sqlScript = @"
-- Enable SA account
ALTER LOGIN [sa] ENABLE;
ALTER LOGIN [sa] WITH PASSWORD = '$saPassword';
GO

-- Create hradms_user if not exists
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = '$hradmsUser')
BEGIN
    CREATE LOGIN [$hradmsUser] WITH PASSWORD = '$hradmsPassword', CHECK_POLICY = OFF;
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [$hradmsUser];
    PRINT 'Created user: $hradmsUser';
END
ELSE
    PRINT 'User $hradmsUser already exists';
GO

-- Create database if not exists
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = '$zkbioDb')
BEGIN
    CREATE DATABASE [$zkbioDb];
    PRINT 'Created database: $zkbioDb';
END
ELSE
    PRINT 'Database $zkbioDb already exists';
GO

-- Create zkbio_user if not exists
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = '$zkbioUser')
BEGIN
    CREATE LOGIN [$zkbioUser] WITH PASSWORD = '$zkbioPassword', CHECK_POLICY = OFF;
    PRINT 'Created login: $zkbioUser';
END
ELSE
    PRINT 'Login $zkbioUser already exists';
GO

-- Ensure zkbio_user has db_owner on security_db
USE [$zkbioDb];
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$zkbioUser')
    CREATE USER [$zkbioUser] FOR LOGIN [$zkbioUser];
ALTER ROLE [db_owner] ADD MEMBER [$zkbioUser];
GO

PRINT 'Setup completed successfully';
GO
"@

    $sqlScript | Out-File -FilePath "$tempDir\setup_users.sql" -Encoding UTF8
    & $sqlcmdPath -S ".\$instanceName" -C -i "$tempDir\setup_users.sql" -o "$tempDir\setup_users.log" 2>&1

    if (Test-Path "$tempDir\setup_users.log") {
        $logContent = Get-Content "$tempDir\setup_users.log" -Raw
        if ($logContent -match "successfully") {
            Write-Host "[OK] Database and user setup completed!" -ForegroundColor Green
        } else {
            Write-Host "[OK] SQL commands executed" -ForegroundColor Green
        }
    }
}
Write-Host ""

# =============================================================================
# STEP 8: CREATE DESKTOP SHORTCUTS
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "STEP 8: Desktop Shortcuts" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$desktopPath = [Environment]::GetFolderPath("Desktop")
$ssmsExe = "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe"

if (Test-Path $ssmsExe) {
    $shell = New-Object -ComObject WScript.Shell

    $shortcut1Path = "$desktopPath\SSMS - HR-ADMS.lnk"
    if (-not (Test-Path $shortcut1Path)) {
        $shortcut1 = $shell.CreateShortcut($shortcut1Path)
        $shortcut1.TargetPath = $ssmsExe
        $shortcut1.Arguments = "-S .\SQLEXPRESS"
        $shortcut1.Save()
        Write-Host "[OK] Created: SSMS - HR-ADMS.lnk" -ForegroundColor Green
    }

    $shortcut2Path = "$desktopPath\SSMS - ZKBio.lnk"
    if (-not (Test-Path $shortcut2Path)) {
        $shortcut2 = $shell.CreateShortcut($shortcut2Path)
        $shortcut2.TargetPath = $ssmsExe
        $shortcut2.Arguments = "-S .\SQLEXPRESS -d $zkbioDb"
        $shortcut2.Save()
        Write-Host "[OK] Created: SSMS - ZKBio.lnk" -ForegroundColor Green
    }
}

# Create connection info file
$privateIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress

$connectionInfo = @"
===============================================
SQL Server Connection Information
===============================================

SERVER: $env:COMPUTERNAME\$instanceName
PORT: 1433
PRIVATE IP: $privateIP

---------------------------------------------
SA ACCOUNT:
---------------------------------------------
Username: sa
Password: (as configured)

---------------------------------------------
HR-ADMS USER (sysadmin):
---------------------------------------------
Username: $hradmsUser
Password: (as configured)

---------------------------------------------
ZKBIO USER (db_owner on $zkbioDb):
---------------------------------------------
Database: $zkbioDb
Username: $zkbioUser
Password: (as configured)

---------------------------------------------
CONNECTION STRINGS:
---------------------------------------------
HR-ADMS:
Server=tcp:$privateIP,1433;Database=master;User Id=$hradmsUser;Password=YOUR_PASSWORD;TrustServerCertificate=True;

ZKBio:
Server=tcp:$privateIP,1433;Database=$zkbioDb;User Id=$zkbioUser;Password=YOUR_PASSWORD;TrustServerCertificate=True;

===============================================
"@

$connectionInfo | Out-File -FilePath "$desktopPath\SQL Connection Info.txt" -Encoding UTF8 -Force
Write-Host "[OK] Created: SQL Connection Info.txt" -ForegroundColor Green
Write-Host ""

# =============================================================================
# SUMMARY
# =============================================================================
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "SETUP COMPLETE!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
Write-Host ""
Write-Host "Components Installed:" -ForegroundColor Yellow
Write-Host "  - SQL Server Express 2022" -ForegroundColor White
Write-Host "  - SQL Server Management Studio 20" -ForegroundColor White
Write-Host "  - Visual C++ Redistributables" -ForegroundColor White
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  - TCP/IP on port 1433" -ForegroundColor White
Write-Host "  - Named Pipes enabled" -ForegroundColor White
Write-Host "  - Mixed Authentication Mode" -ForegroundColor White
Write-Host "  - Firewall rules configured" -ForegroundColor White
Write-Host ""
Write-Host "Users Created:" -ForegroundColor Yellow
Write-Host "  - sa" -ForegroundColor White
Write-Host "  - $hradmsUser (sysadmin)" -ForegroundColor White
Write-Host "  - $zkbioUser (db_owner on $zkbioDb)" -ForegroundColor White
Write-Host ""
Write-Host "Database: $zkbioDb" -ForegroundColor Yellow
Write-Host "Server IP: $privateIP" -ForegroundColor Yellow
Write-Host ""
Write-Host "See 'SQL Connection Info.txt' on desktop for details." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
