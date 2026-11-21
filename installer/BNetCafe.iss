; BNet Cafe 一键安装器（Inno Setup 6）
; 给网吧老板用的：双击，下一步，等几分钟，装完打开管理后台注册账号就能用。
; 安装器自动做：开 IIS + ASP.NET、装 MariaDB（随机 root 密码）、建网站（2000 端口）、
; 放行防火墙（2000/2050）、WebSocket 开机自启、数据库密码写进 Web.config。
; 要求：Windows 10/11 专业版或服务器版（家庭版没有 IIS，装不了）+ 管理员权限 + 联网（仅首次装 .NET 时需要）。
; 编译：CI 里 choco 安装 Inno Setup 后 iscc 本文件；MariaDB MSI 由 CI 先下载到 installer\redist\。

#define AppName "BNet Cafe"
#define AppVersion "1.0.0"
#define AppPublisher "BNet Cafe Fork"
#define MariaDbMsi "mariadb-11.4.5-winx64.msi"

[Setup]
AppId={{BNetCafe-OneClick-20261121}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName=C:\BNetCafe
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir=..\installer-output
OutputBaseFilename=BNetCafe-Setup-{#AppVersion}
SetupIconFile=
UninstallDisplayIcon={app}\Client\BNet.Cafe.Client.exe
WizardStyle=modern

[Languages]
Name: "chinese"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
; 服务端网站（CI 打包的 server-package，去掉了源码）
Source: "..\server-package\*"; DestDir: "{app}\Server"; Flags: ignoreversion recursesubdirs createallsubdirs
; 客户端（发给各台客户机用，也可从服务端下载页下载）
Source: "..\BNet.Cafe.Client\bin\Debug\BNet.Cafe.Client.exe"; DestDir: "{app}\Client"; Flags: ignoreversion
Source: "..\BNet.Cafe.Client\bin\Debug\*.dll"; DestDir: "{app}\Client"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\BNet.Cafe.Client\bin\Debug\*.config"; DestDir: "{app}\Client"; Flags: ignoreversion skipifsourcedoesntexist
; WebSocket 引擎
Source: "..\BNet.Cafe.Websocket\bin\Debug\BNet.Cafe.Websocket.exe"; DestDir: "{app}\WebSocket"; Flags: ignoreversion
Source: "..\BNet.Cafe.Websocket\bin\Debug\*.dll"; DestDir: "{app}\WebSocket"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\BNet.Cafe.Websocket\bin\Debug\*.config"; DestDir: "{app}\WebSocket"; Flags: ignoreversion skipifsourcedoesntexist
; 安装配置脚本与说明
Source: "Setup-BNetCafe.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "README-安装说明.md"; DestDir: "{app}"; Flags: ignoreversion isreadme
; MariaDB 安装包（CI 下载到 redist\，本地编译请先手动下载一份放这里）
Source: "redist\{#MariaDbMsi}"; DestDir: "{app}\redist"; Flags: ignoreversion

[Icons]
Name: "{autodesktop}\BNet Cafe 管理后台"; Filename: "http://localhost:2000/BNet.Cafe.Server/Login.aspx"
Name: "{autodesktop}\BNet Cafe 客户端"; Filename: "{app}\Client\BNet.Cafe.Client.exe"
Name: "{group}\BNet Cafe 管理后台"; Filename: "http://localhost:2000/BNet.Cafe.Server/Login.aspx"
Name: "{group}\卸载 BNet Cafe"; Filename: "{uninstallexe}"

[Run]
; 核心配置：IIS + MariaDB + 网站 + 防火墙 + WebSocket 自启（约 3 分钟，界面会停在这一步等它跑完）
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-BNetCafe.ps1"" -InstallDir ""{app}"" -MariaDbMsi ""{app}\redist\{#MariaDbMsi}"""; StatusMsg: "正在配置 IIS、数据库和服务（约 3 分钟，请稍候）…"; Flags: runhidden waituntilterminated
; 装完打开管理后台（注册第一个管理员账号）
Filename: "http://localhost:2000/BNet.Cafe.Server/Login.aspx"; Description: "打开管理后台"; Flags: postinstall shellexec skipifsilent

[UninstallRun]
; 卸载时停掉 WebSocket 开机任务（IIS 网站与数据库保留，免得误删数据；要彻底清掉见 README）
Filename: "schtasks.exe"; Parameters: "/delete /tn ""BNetCafe WebSocket"" /f"; Flags: runhidden

[Code]
function IsDotNet48Installed(): Boolean;
var
  Release: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release) and (Release >= 528040);
end;

function InstallDotNet48(): Boolean;
var
  ResultCode: Integer;
  NetFxPath: String;
begin
  Result := False;
  NetFxPath := ExpandConstant('{tmp}\ndp48-web.exe');
  { 用 PowerShell 下载 .NET Framework 4.8 联网安装器（微软官方 fwlink） }
  if Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri ''https://go.microsoft.com/fwlink/?LinkId=2085155'' -OutFile ''' + NetFxPath + '''"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and FileExists(NetFxPath) then
  begin
    if Exec(NetFxPath, '/q /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
      Result := (ResultCode = 0) or (ResultCode = 3010);
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  { .NET Framework 4.8 是必须的（Win10 1903+ / Win11 自带，基本不会缺） }
  if not IsDotNet48Installed() then
  begin
    if MsgBox('本机没有 .NET Framework 4.8，需要先下载安装（约 1 分钟，需要联网）。现在安装吗？', mbConfirmation, MB_YESNO) = IDYES then
    begin
      if InstallDotNet48() then
      begin
        MsgBox('.NET Framework 4.8 已安装。请重启电脑后，再运行一次本安装程序继续安装 BNet Cafe。', mbInformation, MB_OK);
        Result := False;
      end
      else
      begin
        MsgBox('.NET Framework 4.8 安装失败。请联网后重试，或手动安装 .NET Framework 4.8 再运行本安装程序。', mbError, MB_OK);
        Result := False;
      end;
    end
    else
      Result := False;
  end;
end;
