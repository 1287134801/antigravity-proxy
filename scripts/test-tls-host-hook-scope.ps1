[CmdletBinding()]
param(
    [ValidateSet("Release", "Debug")]
    [string]$Config = "Release",
    [ValidateSet("x64", "x86")]
    [string]$Arch = "x64",
    [string]$BuildDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = "build-compatibility-tests-tls-$Arch"
}
$BuildPath = Join-Path $Root $BuildDir
$CMakeArch = if ($Arch -eq "x86") { "Win32" } else { "x64" }

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

Write-Host "[测试] 配置宿主 Hook 分域验证工程..."
Invoke-Checked {
    cmake -S $Root -B $BuildPath -A $CMakeArch -DBUILD_TESTS=ON
} "CMake 配置失败"

Write-Host "[测试] 编译 DLL 与进程分类测试..."
Invoke-Checked {
    cmake --build $BuildPath --config $Config --target version process_name_tests
} "DLL 或进程分类测试编译失败"

Write-Host "[测试] 运行宿主 Hook 分域回归测试..."
Invoke-Checked {
    ctest --test-dir $BuildPath -C $Config -R '^process_name_tests$' --output-on-failure --no-tests=error
} "宿主 Hook 分域回归测试失败"

Write-Host "[测试] 宿主使用注入器模式、Language Server/Node 使用全量网络 Hook 的分类验证通过。"
