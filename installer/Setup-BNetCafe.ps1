# BNet Cafe 一键安装 — 安装后配置脚本
# 由 Inno Setup 安装器以管理员身份调用。
# 做四件事：开网站服务器、装 MariaDB、建网站、开防火墙 + WebSocket 开机自启。
# 网站服务器：优先用完整 IIS（DISM 开，专业版/服务器版）；家庭版没有 IIS 时
# 自动改用 IIS Express（捆绑的 MSI，全部 Windows 版本都能装）。
# 参数：
#   -InstallDir  安装目录，例如 C:\BNetCafe
#   -DbPassword  MariaDB root 密码（安装器随机生成），同时写入 Server\Web.config
#   -MariaDbMsi  捆绑的 MariaDB MSI 路径
#   -IisExpressMsi  捆绑的 IIS Express MSI 路径（家庭版兜底用）
# 日志写到 $InstallDir\Setup-Log.txt，装完打不开先看它。
param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $false)][string]$DbPassword = "",
    [Parameter(Mandatory = $true)][string]$MariaDbMsi,
    [Parameter(Mandatory = $true)][string]$IisExpressMsi
)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $InstallDir "Setup-Log.txt"
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}
New-Item -ItemType File -Force -Path $logFile | Out-Null

# 没传密码就随机生成一个（20 位字母数字，不含易混淆字符）
if ([string]::IsNullOrEmpty($DbPassword)) {
    $chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789".ToCharArray()
    $rng = New-Object System.Random
    $DbPassword = -join (1..20 | ForEach-Object { $chars[$rng.Next($chars.Length)] })
    # 把密码存一份在安装目录，网管以后直连数据库用得上
    Set-Content -Path (Join-Path $InstallDir "数据库密码.txt") -Value "MariaDB root 密码（安装器自动生成）：$DbPassword`r`n数据库：BNetCafe，端口 3306，本机直连。" -Encoding UTF8
}
Log "BNet Cafe 安装配置开始，目录=$InstallDir"

# ---------- 1. 网站服务器：先试完整 IIS，不行再用 IIS Express ----------
# 完整 IIS 只有专业版/服务器版有；家庭版 DISM 会失败，这时改用 IIS Express。
$useIisExpress = $false
Log "正在启用 IIS + ASP.NET 4.8（第一次可能要几分钟）…"
$features = @(
    "IIS-WebServerRole", "IIS-WebServer", "IIS-CommonHttpFeatures",
    "IIS-HttpErrors", "IIS-ApplicationDevelopment", "IIS-NetFxExtensibility45",
    "IIS-ASPNET45", "IIS-ISAPIExtensions", "IIS-ISAPIFilter",
    "IIS-DefaultDocument", "IIS-StaticContent", "IIS-HttpLogging",
    "IIS-RequestMonitor", "IIS-HttpCompressionStatic", "IIS-Security",
    "IIS-RequestFiltering", "IIS-ManagementConsole"
)
$featArgs = ($features | ForEach-Object { "/featurename:$_" }) -join " "
$proc = Start-Process -FilePath "dism.exe" -ArgumentList "/online /enable-feature $featArgs /all /norestart" -Wait -PassThru -NoNewWindow
$appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
if (($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) -and (Test-Path $appcmd)) {
    Log "完整 IIS 已启用。"
} else {
    Log "完整 IIS 启用失败（dism 退出码=$($proc.ExitCode)，多半是家庭版没有 IIS），改用 IIS Express。"
    $useIisExpress = $true
    $iisExpressExe = Join-Path ${env:ProgramFiles} "IIS Express\iisexpress.exe"
    if (-not (Test-Path $iisExpressExe)) {
        if (-not (Test-Path $IisExpressMsi)) { throw "找不到 IIS Express 安装包：$IisExpressMsi" }
        Log "正在安装 IIS Express…"
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$IisExpressMsi`" /qn /norestart" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { throw "安装 IIS Express 失败，msiexec 退出码=$($proc.ExitCode)" }
        Log "IIS Express 已安装。"
    } else {
        Log "IIS Express 已存在，跳过安装。"
    }
}

# ---------- 2. 装 MariaDB（root 密码随机，服务名 BNetMariaDB） ----------
$svc = Get-Service -Name "BNetMariaDB" -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    if (-not (Test-Path $MariaDbMsi)) { throw "找不到 MariaDB 安装包：$MariaDbMsi" }
    Log "正在安装 MariaDB（约 1 分钟）…"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$MariaDbMsi`" SERVICENAME=BNetMariaDB PASSWORD=`"$DbPassword`" PORT=3306 /qn /norestart" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "安装 MariaDB 失败，msiexec 退出码=$($proc.ExitCode)" }
    Log "MariaDB 已安装。"
} else {
    Log "MariaDB 服务已存在，跳过安装（沿用已有 root 密码——若不是本安装器装的，请确认 Web.config 里 DbPassword 一致）。"
}
# 等服务跑起来
$svc = Get-Service -Name "BNetMariaDB" -ErrorAction Stop
if ($svc.Status -ne "Running") { Start-Service -Name "BNetMariaDB" }
for ($i = 0; $i -lt 30; $i++) {
    $svc.Refresh()
    if ($svc.Status -eq "Running") { break }
    Start-Sleep -Seconds 2
}
if ((Get-Service -Name "BNetMariaDB").Status -ne "Running") { throw "MariaDB 服务启动失败。" }
Log "MariaDB 服务运行中。"

# ---------- 3. 写数据库密码进 Server\Web.config ----------
$webConfig = Join-Path $InstallDir "Server\Web.config"
if (Test-Path $webConfig) {
    [xml]$xml = Get-Content $webConfig -Encoding UTF8
    $node = $xml.SelectSingleNode("//appSettings/add[@key='DbPassword']")
    if ($null -ne $node) {
        $node.SetAttribute("value", $DbPassword)
        $xml.Save($webConfig)
        Log "数据库密码已写入 Web.config。"
    } else {
        Log "警告：Web.config 里没有 DbPassword 项，数据库连接将用空密码，MariaDB 可能连不上。"
    }
} else {
    throw "找不到 Server\Web.config：$webConfig"
}

# ---------- 4. 建网站 BNetCafe（2000 端口） ----------
$serverPath = Join-Path $InstallDir "Server"
if (-not $useIisExpress) {
    # 完整 IIS：用 appcmd 建应用池 + 网站
    if (-not (Test-Path $appcmd)) { throw "找不到 appcmd.exe，IIS 可能没装好。" }
    $existingSite = & $appcmd list site "BNetCafe" 2>$null
    if ([string]::IsNullOrWhiteSpace($existingSite)) {
        & $appcmd add apppool /name:"BNetCafe" /managedRuntimeVersion:"v4.0" /managedPipelineMode:"Integrated" | Out-Null
        & $appcmd add site /name:"BNetCafe" /bindings:"http/*:2000:" /physicalPath:"$serverPath" | Out-Null
        & $appcmd set app "BNetCafe/" /applicationPool:"BNetCafe" | Out-Null
        Log "IIS 网站 BNetCafe 已建（http://localhost:2000/BNet.Cafe.Server/）。"
    } else {
        & $appcmd set site "BNetCafe" /physicalPath:"$serverPath" | Out-Null
        Log "IIS 网站 BNetCafe 已存在，路径已更新。"
    }
    & $appcmd start site "BNetCafe" | Out-Null
} else {
    # IIS Express：拷一份自带模板配置，改成我们的站（*:2000，局域网也能访问），开机自启
    $iisExpressExe = Join-Path ${env:ProgramFiles} "IIS Express\iisexpress.exe"
    $templateCfg = Join-Path ${env:ProgramFiles} "IIS Express\config\templates\PersonalWebServer\applicationhost.config"
    $expressDir = Join-Path $InstallDir "iisexpress"
    New-Item -ItemType Directory -Force -Path $expressDir | Out-Null
    $siteCfg = Join-Path $expressDir "applicationhost.config"
    if (-not (Test-Path $templateCfg)) { throw "找不到 IIS Express 配置模板：$templateCfg" }
    Copy-Item $templateCfg $siteCfg -Force
    [xml]$cfg = Get-Content $siteCfg -Encoding UTF8
    $site = $cfg.SelectSingleNode("//system.applicationHost/sites/site[1]")
    if ($null -eq $site) { throw "IIS Express 配置模板里没有 site 节点，无法配置。" }
    $site.SetAttribute("name", "BNetCafe")
    $app = $site.SelectSingleNode("application")
    if ($null -ne $app) { $app.SetAttribute("applicationPool", "Clr4IntegratedAppPool") }
    $vdir = $site.SelectSingleNode("application/virtualDirectory")
    if ($null -ne $vdir) { $vdir.SetAttribute("physicalPath", $serverPath) }
    $binding = $site.SelectSingleNode("bindings/binding")
    if ($null -ne $binding) { $binding.SetAttribute("bindingInformation", "*:2000:") }
    $cfg.Save($siteCfg)
    # 局域网访问要放行 URL 保留（SYSTEM 跑本可不加，加上更稳）
    netsh http add urlacl url=http://*:2000/ user=Everyone 2>$null | Out-Null
    # 开机自启：计划任务跑 iisexpress（SYSTEM，最高权限）
    $expressLauncher = Join-Path $expressDir "Start-IisExpress.bat"
    Set-Content -Path $expressLauncher -Value "@echo off`r`ncd /d %~dp0`r`nstart `"`" /min `"$iisExpressExe`" /config:`"$siteCfg`" /site:BNetCafe" -Encoding ASCII
    $expressTask = "BNetCafe IIS Express"
    schtasks /delete /tn "$expressTask" /f 2>$null | Out-Null
    schtasks /create /tn "$expressTask" /tr "`"$expressLauncher`"" /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建 IIS Express 开机任务失败。" }
    schtasks /run /tn "$expressTask" | Out-Null
    Log "IIS Express 网站 BNetCafe 已建并启动（http://localhost:2000/BNet.Cafe.Server/，局域网可访问）。"
}

# ---------- 5. 防火墙放行 2000（网站）与 2050（WebSocket），供局域网客户机访问 ----------
foreach ($port in @(2000, 2050)) {
    $ruleName = "BNet Cafe ($port)"
    # 先删后加，保证幂等（已存在也不报错）
    netsh advfirewall firewall delete rule name="$ruleName" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$port | Out-Null
    Log "防火墙已放行 $port 端口。"
}

# ---------- 6. WebSocket 开机自启（计划任务，最高权限） ----------
$wsDir = Join-Path $InstallDir "WebSocket"
$wsExe = Join-Path $wsDir "BNet.Cafe.Websocket.exe"
$launcher = Join-Path $wsDir "Start-WebSocket.bat"
if (Test-Path $wsExe) {
    # 启动器：先切到 WebSocket 目录再跑，避免工作目录不对导致读不到配置/日志
    Set-Content -Path $launcher -Value "@echo off`r`ncd /d %~dp0`r`nstart `"`" /min `"$wsExe`"" -Encoding ASCII
    $taskName = "BNetCafe WebSocket"
    schtasks /delete /tn "$taskName" /f 2>$null | Out-Null
    schtasks /create /tn "$taskName" /tr "`"$launcher`"" /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建 WebSocket 开机任务失败。" }
    # 立即跑一次（不用等重启）
    schtasks /run /tn "$taskName" | Out-Null
    Log "WebSocket 已设开机自启，并已启动。"
} else {
    Log "警告：找不到 WebSocket 程序 $wsExe，跳过自启设置。"
}

# ---------- 7. 自检：网站能不能打开 ----------
Start-Sleep -Seconds 3
try {
    $resp = Invoke-WebRequest -Uri "http://localhost:2000/BNet.Cafe.Server/Login.aspx" -UseBasicParsing -TimeoutSec 15
    Log "自检通过：管理后台可访问（HTTP $($resp.StatusCode)）。"
} catch {
    Log "警告：自检没能打开管理后台：$($_.Exception.Message)。先别急，IIS 刚启动可能还在预热，稍后手动打开 http://localhost:2000/BNet.Cafe.Server/ 试试。"
}

Log "安装配置完成。"
