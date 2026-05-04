# ============================================================================== 
# build_llama_server_arm64.ps1
# 适用平台：高通 Snapdragon X Elite · Windows ARM64 · 64GB RAM
# 目标产物：llama-server.exe（完整 OpenAI API Server 模式）
# 支持端点：/v1/chat/completions  /v1/completions  /v1/responses
#           /v1/embeddings  /v1/models  /health
# 用法：以管理员权限在 PowerShell 中运行本脚本
# ============================================================================== 

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 颜色输出辅助函数 ──────────────────────────────────────────────────────────
function Write-Step   { param($msg) Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-OK     { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail   { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red; exit 1 }

# ── 用户可修改的配置 ──────────────────────────────────────────────────────────
$ROOT          = "C:\llama_build"          # 工作根目录
$REPO_DIR      = "$ROOT\llama.cpp"         # 源码目录
$BUILD_DIR     = "$REPO_DIR\build"         # CMake 构建目录
$OUT_DIR       = "$ROOT\output"            # 最终产物目录
$LLAMA_REPO    = "https://github.com/ggml-org/llama.cpp.git"
$PARALLEL_JOBS = 12                        # 并行编译线程数（可按核心数调整）

# ── 管理员权限检查 ────────────────────────────────────────────────────────────
Write-Step "检查管理员权限"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Fail "请以【管理员权限】运行 PowerShell 后重试" }
Write-OK "管理员权限确认"

# ── Step 1：安装 Chocolatey ───────────────────────────────────────────────────
Write-Step "Step 1/8 · 安装 Chocolatey 包管理器"
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-OK "Chocolatey 已安装，跳过"
} else {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
    Write-OK "Chocolatey 安装完成"
}

# ── Step 2：安装 Git / CMake / Ninja / Python ─────────────────────────────────
Write-Step "Step 2/8 · 安装基础工具（git / cmake / ninja / python）"
$tools = @("git", "cmake", "ninja", "python")
foreach ($t in $tools) {
    if (Get-Command $t -ErrorAction SilentlyContinue) {
        Write-OK "$t 已存在，跳过"
    } else {
        Write-Host "    安装 $t ..."
        choco install -y $t | Out-Null
        Write-OK "$t 安装完成"
    }
}

# 刷新环境变量
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")

# ── Step 3：安装 VS Build Tools 2022（ARM64 工具链）─────────────────────────
Write-Step "Step 3/8 · 安装 Visual Studio 2022 Build Tools（ARM64 工具链）"
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstalled = $false
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -property installationPath 2>$null
    if ($vsPath) {
        # 检查 ARM64 组件
        $arm64Check = & $vsWhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath 2>$null
        if ($arm64Check) { $vsInstalled = $true }
    }
}

if ($vsInstalled) {
    Write-OK "VS 2022 ARM64 工具链已安装，跳过"
} else {
    Write-Host "    下载并安装 VS 2022 Build Tools（含 ARM64 + Windows SDK）..."
    $vsInstallerUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
    $vsInstaller    = "$env:TEMP\vs_buildtools.exe"
    Invoke-WebRequest -Uri $vsInstallerUrl -OutFile $vsInstaller -UseBasicParsing
    $vsArgs = @(
        "--quiet", "--wait", "--norestart",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
        "--add", "Microsoft.VisualStudio.Component.VC.Tools.ARM64EC",
        "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22621",
        "--includeRecommended"
    )
    Start-Process -FilePath $vsInstaller -ArgumentList $vsArgs -Wait -NoNewWindow
    Write-OK "VS 2022 Build Tools 安装完成"
}

# 重新定位 vswhere 并添加备用路径检测
$vsPath = $null

# 方法1：使用 vswhere.exe
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -property installationPath 2>$null
}

# 方法2：检查常见安装路径（备用）
if (-not $vsPath) {
    Write-Host "    vswhere 查询失败，检查常见路径..."
    $commonPaths = @(
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise",
        "C:\Program Files\Microsoft Visual Studio\2022\Community",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community"
    )
    
    foreach ($path in $commonPaths) {
        if (Test-Path "$path\Common7\Tools\Microsoft.VisualStudio.DevShell.dll") {
            $vsPath = $path
            Write-Host "    在 $path 找到 Visual Studio"
            break
        }
    }
}

if (-not $vsPath) { 
    Write-Fail "无法定位 Visual Studio 安装路径。请确保 VS 2022 Build Tools 已安装，或手动设置 `$vsPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'" 
}
Write-OK "VS 路径：$vsPath"

# ── Step 4：克隆 llama.cpp ────────────────────────────────────────────────────
Write-Step "Step 4/8 · 克隆 llama.cpp 仓库（最新 main 分支）"
if (-not (Test-Path $ROOT)) { New-Item -ItemType Directory -Path $ROOT | Out-Null }

if (Test-Path "$REPO_DIR\.git") {
    Write-Host "    仓库已存在，执行 git pull ..."
    Set-Location $REPO_DIR
    git pull --ff-only
    Write-OK "仓库已更新到最新"
} else {
    Write-Host "    克隆中，请稍候..."
    git clone --depth 1 $LLAMA_REPO $REPO_DIR
    Write-OK "克隆完成：$REPO_DIR"
}

# ── Step 5：进入 ARM64 开发者环境并配置 CMake ─────────────────────────────────
Write-Step "Step 5/8 · 初始化 ARM64 开发者 Shell 并配置 CMake"

# 加载 VS DevShell（ARM64 Host + ARM64 Target）
$devShellDll = "$vsPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
if (-not (Test-Path $devShellDll)) { Write-Fail "找不到 DevShell DLL：$devShellDll" }

Import-Module $devShellDll
Enter-VsDevShell -VsInstallPath $vsPath -Arch arm64 -HostArch arm64 -SkipAutomaticLocation
Write-OK "ARM64 开发者环境已激活"

# 创建构建目录
if (Test-Path $BUILD_DIR) {
    Write-Warn "构建目录已存在，清理中..."
    Remove-Item -Recurse -Force $BUILD_DIR
}
New-Item -ItemType Directory -Path $BUILD_DIR | Out-Null
Set-Location $BUILD_DIR

Write-Host "    运行 CMake 配置..."
$cmakeArgs = @(
    "..",
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_SYSTEM_NAME=Windows",
    "-DCMAKE_SYSTEM_PROCESSOR=ARM64",
    "-DCMAKE_GENERATOR_PLATFORM=ARM64",
    "-DGGML_NATIVE=OFF",
    "-DLLAMA_BUILD_SERVER=ON",
    "-DLLAMA_SERVER_VERBOSE=ON",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DLLAMA_CURL=OFF",
    "-DGGML_BLAS=OFF",
    "-DCMAKE_CXX_FLAGS=-O3",
    "-DCMAKE_C_FLAGS=-O3"
)

cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { Write-Fail "CMake 配置失败，请检查上方错误信息" }
Write-OK "CMake 配置成功"

# ── Step 6：编译 llama-server ─────────────────────────────────────────────────
Write-Step "Step 6/8 · 编译 llama-server（并行 $PARALLEL_JOBS 线程，请耐心等待）"
cmake --build . --config Release --parallel $PARALLEL_JOBS --target llama-server
if ($LASTEXITCODE -ne 0) { Write-Fail "编译失败，请检查上方错误信息" }
Write-OK "编译完成！"

# ── Step 7：收集产物 ───────────────────────────────────────────────────────────
Write-Step "Step 7/8 · 收集编译产物到 $OUT_DIR"
if (-not (Test-Path $OUT_DIR)) { New-Item -ItemType Directory -Path $OUT_DIR | Out-Null }

# llama-server 可能在 bin\ 或直接在构建目录
$serverBin = @(
    "$BUILD_DIR\bin\llama-server.exe",
    "$BUILD_DIR\llama-server.exe",
    "$BUILD_DIR\bin\Release\llama-server.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $serverBin) { Write-Fail "找不到 llama-server.exe，编译可能未生成目标文件" }

Copy-Item $serverBin -Destination "$OUT_DIR\llama-server.exe" -Force

# 复制可能需要的 ggml 相关 DLL（如有）
Get-ChildItem "$BUILD_DIR\bin\*.dll" -ErrorAction SilentlyContinue |
    Copy-Item -Destination $OUT_DIR -Force

Write-OK "产物已复制到：$OUT_DIR"

# ── Step 8：验证产物 ───────────────────────────────────────────────────────────
Write-Step "Step 8/8 · 验证 llama-server.exe"

$serverExe = "$OUT_DIR\llama-server.exe"
if (-not (Test-Path $serverExe)) { Write-Fail "产物不存在：$serverExe" }

# 检查文件架构
try {
    $bytes = [System.IO.File]::ReadAllBytes($serverExe)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $machine  = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    switch ($machine) {
        0xAA64 { Write-OK "架构验证：ARM64 ✓" }
        0x8664 { Write-Warn "架构验证：x64（非预期！应为 ARM64）" }
        default { Write-Warn "架构验证：未知（Machine=0x$('{0:X4}' -f $machine)）" }
    }
} catch {
    Write-Warn "无法读取 PE 头，跳过架构验证"
}

# 显示文件大小
$size = (Get-Item $serverExe).Length / 1MB
Write-OK ("文件大小：{0:F1} MB" -f $size)

# 打印帮助（验证可执行）
Write-Host "`n    运行 --help 验证可执行性..."
$helpOut = & $serverExe --help 2>&1 | Select-Object -First 5
$helpOut | ForEach-Object { Write-Host "    $_" }
Write-OK "llama-server.exe 可正常执行"

# ── 完成摘要 ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  构建完成！" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  产物路径  : $OUT_DIR\llama-server.exe" -ForegroundColor White
Write-Host ""
Write-Host "  启动示例  :" -ForegroundColor White
Write-Host "    $OUT_DIR\llama-server.exe \" -ForegroundColor Yellow
Write-Host "      --model  C:\models\your-model.gguf \" -ForegroundColor Yellow
Write-Host "      --host   0.0.0.0 \" -ForegroundColor Yellow
Write-Host "      --port   8080 \" -ForegroundColor Yellow
Write-Host "      --ctx-size 8192 \" -ForegroundColor Yellow
Write-Host "      --threads  12" -ForegroundColor Yellow
Write-Host ""
Write-Host "  支持的 OpenAI API 端点：" -ForegroundColor White
Write-Host "    GET  http://localhost:8080/v1/models" -ForegroundColor DarkCyan
Write-Host "    POST http://localhost:8080/v1/chat/completions" -ForegroundColor DarkCyan
Write-Host "    POST http://localhost:8080/v1/completions" -ForegroundColor DarkCyan
Write-Host "    POST http://localhost:8080/v1/responses" -ForegroundColor DarkCyan
Write-Host "    POST http://localhost:8080/v1/embeddings" -ForegroundColor DarkCyan
Write-Host "    GET  http://localhost:8080/health" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
