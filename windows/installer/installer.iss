; vbox Windows 侧载安装包 —— 「静默安装内核」（路线 A 的 core）
;
; 路线 A 说明（见 docs/网盘登录11问题_对齐修复清单_v1.3.md 第 8 章）：
;   最终交付物 vbox-setup.exe 是 .NET 壳（windows/setup-shell），本脚本编译产物
;   vbox-installer-core.exe 作为「内嵌资源」被壳释放并以静默模式执行，负责真正的
;   安装动作；所有既有安装逻辑（含常驻进程查杀）保持不变，仅新增进度上报钩子，
;   供壳轮询后驱动自绘 UI。
;
; 编译方式：ISCC.exe windows/installer/installer.iss
;   （GitHub Actions 工作流 .github/workflows/build-release-assets.yml 自动执行）
; 可选注入版本号：ISCC /DMyAppVersion=X.Y.Z windows/installer/installer.iss
; 无壳时单独调试 core（原生向导模式）：直接双击 vbox-installer-core.exe
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

; 主程序可执行文件名：必须与 windows/CMakeLists.txt 的 BINARY_NAME 一致。
; Flutter 产物名为 vbox.exe；CMake target 名 "runner" 只体现在中间目录
; （build\windows\x64\runner\Release\），不是产物文件名。
#define MyAppExeName "vbox.exe"

[Setup]
; 固定 AppId（{{ 是 Inno 的转义），保证覆盖安装识别同一应用
AppId={{4A2B1C9E-7F63-4B0A-9D2E-1C8A0F6B4D51}
AppName=vbox
AppVersion={#MyAppVersion}
AppPublisher=vbox
DefaultDirName={autopf}\vbox
DefaultGroupName=vbox
; 安装程序自身图标（vbox 品牌图标，与桌面快捷方式一致）
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\app_icon.ico
Compression=lzma2
SolidCompression=yes
OutputDir=Output
; 路线 A：本产物是「静默安装内核」，由 .NET 壳内嵌；最终交付名 vbox-setup.exe
; 归壳所有（避免与外层同名冲突）。
OutputBaseFilename=vbox-installer-core
; 静默模式不需要向导配色；保留 modern 便于无壳时单独调试 core 的原生向导。
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
; 单实例防护（第二道防线）：安装包被重复启动时（双击两次 / 浏览器自动打开 +
; 手动双击叠加），两个静默内核并发会互相杀进程、并发覆盖文件。占用时第二个
; 内核提示后退出（/SUPPRESSMSGBOXES 下静默退出）。第一道防线在 .NET 壳的
; App_Startup（Local\vbox-setup-shell Mutex），向导 UI 根本不会出现第二个。
SetupMutex=vbox-setup-core-mutex

; 升级时用 Windows Restart Manager 协助关闭占用安装目录内文件的进程
; （vbox.exe / 常驻 node.exe）。注意 Inno 6 没有 CloseApplicationsForce
; 指令；RM 对无窗口的 node.exe 常驻进程 Graceful 关闭会失败，真正的
; 兜底是下方 [Code] PrepareToInstall 的显式查杀。
CloseApplications=yes
RestartApplications=no

; 安装界面简体中文（语言文件随仓库分发：languages/ChineseSimplified.isl，
; 来源 jrsoftware/issrc Files/Languages/ChineseSimplified.isl，UTF-8 BOM；
; 不依赖 Inno Setup 安装目录——choco 安装的 innosetup 缺 Languages 中文文件）
[Languages]
Name: "chinesesimp"; MessagesFile: "Languages\ChineseSimplified.isl"

[Files]
; 相对本文件（windows/installer/）两级的 build/windows/x64/runner/Release 全量文件
; （含 vbox.exe + Flutter DLL + libmpv-windows-*.dll，D28 随安装包分发）
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; vbox 品牌图标随包分发，供快捷方式 / 卸载列表使用
Source: "..\..\windows\runner\resources\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion
; 进程清理脚本：仅释放到临时目录（dontcopy 不进安装目录），由 [Code] 用 -File 调用
Source: "kill-runtime.ps1"; DestDir: "{tmp}"; Flags: dontcopy deleteafterinstall

[Icons]
Name: "{autoprograms}\vbox"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"
Name: "{autodesktop}\vbox"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\app_icon.ico"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 vbox"; Flags: nowait postinstall skipifsilent

; ── 升级 / 卸载前结束旧版进程 ──────────────────────────────────────
; 常驻 node.exe（ND-02 Node 引擎内置 + Node 常驻系统）与内置 python.exe
; （ND-02-desktop CPython 子进程）在 vbox.exe 退出后仍按设计驻留后台。
; Inno 覆盖 {app}\noderuntime\node.exe、{app}\pyruntime\python.exe 时，Windows
; 拒绝删除正在运行的 exe → 「DeleteFile 失败；错误代码 5。拒绝访问」。
; 此处在复制文件前显式查杀：
;   - vbox.exe 按映像名连进程树强杀（/t 连带其子进程）；
;   - node.exe / python.exe 只按完整路径杀安装目录内的实例，不误伤系统其他
;     Node / Python 应用；
;   - 杀完等 800ms 让句柄释放，再由 ignoreversion 覆盖文件。
[Code]
// ══════════════════════════════════════════════════════════════════
//  进度上报通道（路线 A 新增 · 供 .NET 壳轮询读取，驱动自绘 UI）
//  ──────────────────────────────────────────────────────────────
//  路径由壳通过自定义参数 /VBOXPROG="<path>" 注入（Inno 6 支持
//  {param:VBOXPROG|} 常量；末尾竖线给出「参数缺失时的默认值=空串」，
//  避免无壳调试时 ExpandConstant 因参数不存在而抛异常）。
//  未注入时退化到临时目录下的固定文件名。
//  写入内容为单行 JSON：
//    · 阶段事件： {"stage":"extract","cur":-1,"max":-1}
//    · 字节进度： {"stage":"<当前阶段键>","cur":<n>,"max":<m>}（CurInstallProgressChanged，
//      阶段键粘性携带，避免覆写成空串导致页面不切卡）
//  壳解析后补上 "type":"progress" 再推给页面。
//
//  ⚠ 阶段键必须是纯 ASCII（prepare/extract/shortcut/done）：
//  Inno 的 SaveStringToFile 第二参数是 AnsiString，中文会按「系统 ANSI 代码页」
//  （中文 Windows = GBK）写出；而 .NET 壳用 File.ReadAllText 按 UTF-8 读取 →
//  中文阶段名变乱码 → 页面 STAGE_DEF 匹配失败 → 进度被压进「准备安装」的
//  0~8% 区间并封顶（实测卡 8%、卡片停在「1 准备安装」）。纯 ASCII 无编码歧义。
//  中文显示文案由 installer.html 内的映射表负责。
// ══════════════════════════════════════════════════════════════════
var
  { 是否已真正进入「已安装完成」状态；用于避免用户取消安装时误报“安装完成”。 }
  gInstallDone: Boolean;
  { 当前阶段键（粘性，纯 ASCII）。
    原因：Inno 的 CurInstallProgressChanged 在复制文件期间高频触发，每次都覆写
    同一份进度快照；若快照里 stage 留空，壳 150ms 轮询到的大概率是「字节进度」
    快照，页面就会永远停在上一阶段（实测卡在「准备安装」的 8% 上限）。
    因此把最近一次阶段名记住，每条快照都带上它。 }
  gStage: String;

function ProgPath(): String;
begin
  Result := ExpandConstant('{param:VBOXPROG|}');
  if Result = '' then
    Result := ExpandConstant('{tmp}\vbox-setup-progress.json');
end;

procedure WriteProgress(const Json: String);
begin
  { Append=False：整文件覆写，保证壳每次读到的是最新一条快照。
    单行小文件写入足够快，无需额外的原子替换。 }
  SaveStringToFile(ProgPath(), Json, False);
end;

{ 上报「阶段」——与定稿 UI 的 5 张步骤卡片对应（每步的基准百分比由壳/页面侧换算）。
  参数为纯 ASCII 阶段键（prepare/extract/shortcut/done），中文显示文案由页面映射。 }
procedure ReportStage(const Stage: String);
begin
  gStage := Stage; { 粘住当前阶段，供后续字节进度快照一并带上 }
  WriteProgress('{"stage":"' + Stage + '","cur":-1,"max":-1}');
end;

{ 上报「真实字节进度」——Inno 官方事件；静默（/VERYSILENT）模式下同样会被调用。
  若个别环境不触发，页面侧会退化为「按阶段推进的估算进度」（见 installer.html）。 }
procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  { 关键：带上 gStage，否则本快照会把阶段事件的 stage 覆盖成空串，页面永远不切卡。 }
  WriteProgress('{"stage":"' + gStage + '","cur":' + IntToStr(CurProgress) +
                ',"max":' + IntToStr(MaxProgress) + '}');
end;

// ── 升级前收尾旧版进程 ─────────────────────────────────────────────
//
// 顺序（对齐 QQ / 微信 / Discord 的做法，不是上来就强杀）：
//   ① 发「优雅退出」标记 → 等应用自己停子进程并退出（最长 8s）
//   ② 还不退（崩溃残留 / 不响应）→ 才 taskkill + kill-runtime.ps1 兜底
//
// ⚠ 为什么用 tasklist 判断而不是「探测文件能不能改名」：
//   实测 Windows 允许给「正在运行」的 exe 改名，甚至允许 DeleteFile
//   （映像 section 以 FILE_SHARE_DELETE 打开，名字删了进程照跑），
//   因此改名探测会**误判为可覆盖**；真正的门槛是「有没有别的句柄不共享删除」，
//   只有真去覆盖才会暴露。所以这里只判断进程是否还在，别再用改名/删除试探。
//
// ⚠ 历史坑（别再写回 -Command）：Inno 的 Exec 把参数原样拼进命令行，
//   PowerShell 把 -Command 后的内容当脚本重新解析，那一层会吃掉所有双引号
//   （单引号包住也保不住）→ ParserError → 退出码 1 → 一个进程都杀不掉。
//   现改为 kill-runtime.ps1 落盘 + -File 调用。

const
  UPGRADE_FLAG = '.vbox-upgrade-request';

function UpgradeFlagPath(): String;
begin
  Result := ExpandConstant('{app}\' + UPGRADE_FLAG);
end;

procedure ClearUpgradeFlag();
var
  FlagPath: String;
begin
  FlagPath := UpgradeFlagPath();
  if FileExists(FlagPath) then
  begin
    if DeleteFile(FlagPath) then
      Log('升级握手: 已清理标记 ' + FlagPath);
  end;
end;

{ 是否还有 node / python 常驻进程（不区分路径）——一个都没有时就没必要启动
  PowerShell 去按路径枚举，省掉几秒开销。 }
function AnyRuntimeProcess(): Boolean;
var
  ResultCode: Integer;
begin
  ResultCode := -1;
  Exec(ExpandConstant('{cmd}'),
       '/C tasklist /NH | findstr /I /C:"python.exe" /C:"pythonw.exe" /C:"node.exe" >nul',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

function IsVboxRunning(): Boolean;
var
  ResultCode: Integer;
begin
  ResultCode := -1;
  Exec(ExpandConstant('{cmd}'),
       '/C tasklist /FI "IMAGENAME eq vbox.exe" /NH | find /I "vbox.exe" >nul',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

{ 下发退出请求并等待 vbox.exe 退出；最长 8s（25 × 320ms）。 }
procedure RequestGracefulExitAndWait();
var
  Round: Integer;
  FlagPath: String;
begin
  if not IsVboxRunning() then
  begin
    Log('升级握手: 未检测到 vbox.exe，跳过等待');
    Exit;
  end;
  FlagPath := UpgradeFlagPath();
  SaveStringToFile(FlagPath, 'upgrade ' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':'), False);
  Log('升级握手: 已下发退出请求 ' + FlagPath);
  for Round := 1 to 25 do
  begin
    Sleep(320);
    if not IsVboxRunning() then
    begin
      Log('升级握手: 应用已自行退出（第 ' + IntToStr(Round) + ' 次探测，约 ' +
          IntToStr(Round * 320) + ' ms）');
      Exit;
    end;
  end;
  Log('升级握手: 等待 8s 应用未退出，转为强制清理');
end;

{ 释放并运行 kill-runtime.ps1（[Files] 里 Flags: dontcopy，不进安装目录）。 }
procedure RunKillScript(const AppDir: String);
var
  ResultCode: Integer;
  ScriptPath: String;
begin
  ExtractTemporaryFile('kill-runtime.ps1');
  ScriptPath := ExpandConstant('{tmp}\kill-runtime.ps1');
  if not FileExists(ScriptPath) then
  begin
    Log('KillVboxProcesses: kill-runtime.ps1 释放失败，跳过进程清理');
    Exit;
  end;
  Exec('powershell.exe',
       '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ScriptPath +
       '" -AppDir "' + AppDir + '"',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Log('KillVboxProcesses: ps 退出码=' + IntToStr(ResultCode) + '（仅参考）');
end;

// UseWmi 保留形参以兼容调用点；脚本内部已同时覆盖「Get-Process 快路径 + CIM 兜底」。
procedure KillVboxProcesses(UseWmi: Boolean);
var
  AppDir: String;
  Round: Integer;
  ResultCode: Integer;
begin
  AppDir := ExpandConstant('{app}');
  Log('KillVboxProcesses: AppDir=' + AppDir + ' UseWmi=' + IntToStr(Ord(UseWmi)));

  { ① 主程序按映像名连进程树一起杀（这时它已经拒绝优雅退出）。 }
  Exec(ExpandConstant('{cmd}'), '/C taskkill /f /t /im vbox.exe',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Log('KillVboxProcesses: taskkill vbox.exe 退出码=' + IntToStr(ResultCode));

  { ② 杀安装目录与用户数据目录下的 node / python 常驻进程，最多三轮。 }
  for Round := 1 to 3 do
  begin
    RunKillScript(AppDir);
    Sleep(400);
    if not IsVboxRunning() then
    begin
      Log('KillVboxProcesses: vbox.exe 已终止（第 ' + IntToStr(Round) + ' 轮）');
      Exit;
    end;
    Log('KillVboxProcesses: 第 ' + IntToStr(Round) + ' 轮后 vbox.exe 仍在，重试');
  end;
end;

{ 覆盖安装时的准备：先请应用自退，不行再强杀；仍不退就明确告知用户。 }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Round: Integer;
begin
  ReportStage('prepare');
  Result := '';
  { 全新安装（既无程序目录，也无用户数据目录）时没有旧进程要处理，直接跳过。 }
  if DirExists(ExpandConstant('{app}')) or
     DirExists(ExpandConstant('{userappdata}\com.vbox\vbox')) then
  begin
    { ① 先请应用优雅退出（QQ/微信式）：vbox.exe 自己停子进程、自己退。 }
    RequestGracefulExitAndWait();
    { ② 无论 ① 是否成功都再跑一遍清理：覆盖「vbox.exe 已崩溃，但 pid 残留的
         python / node 还借着自己那份解释器占着文件」这种线上最常见的残局。
        kill-runtime.ps1 只匹配本安装目录与 com.vbox 数据目录，不会误伤别家进程。 }
    if AnyRuntimeProcess() then
      KillVboxProcesses(False)
    else
      Log('升级握手: 无 node/python 常驻进程，跳过强制清理');

    for Round := 1 to 10 do
    begin
      if not IsVboxRunning() then
        Break;
      Sleep(300);
    end;

    if IsVboxRunning() then
      Result := 'vbox 仍在运行，无法覆盖程序文件。' + #13#10 +
                '请先退出 vbox（含托盘图标），再重试安装。';
  end;
end;

{ 阶段推进：ssInstall = 开始复制文件（含 Node 引擎，页面侧用字节进度切「部署 Node 引擎」）；
  ssPostInstall = 文件复制完成、开始写快捷方式 / 运行项；
  ssDone = 安装流程全部收尾（进入完成态）。 }
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    ReportStage('extract');
  if CurStep = ssPostInstall then
  begin
    ReportStage('shortcut');
    gInstallDone := True;
    { 文件已全部落盘：撤掉升级标记，否则随后启动的 vbox.exe 会立刻退出。 }
    ClearUpgradeFlag();
  end;
  { ssDone 提前写 done 快照：原实现仅在 DeinitializeSetup（进程退出前最后一刻）
    写 done，壳的 150ms 轮询可能最后一次只读到上一阶段快照（实测停在 62%），
    配合壳侧渲染窗口过短，用户看到「62% → 安装窗口直接关闭」。此处提前到
    ssDone 事件写，给轮询留出至少一个完整 tick 的可见窗口。 }
  if CurStep = ssDone then
    ReportStage('done');
end;

procedure DeinitializeSetup();
begin
  { 兜底：取消安装 / 中途失败也要撤标记，否则下次启动会被当成升级请求直接退出。 }
  ClearUpgradeFlag();
  { 仅在真正安装完成后上报，避免用户中途取消时误报。 }
  if gInstallDone then
    ReportStage('done');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    KillVboxProcesses(True);
end;
