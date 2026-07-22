$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Dist = Join-Path (Resolve-Path '.').Path 'out/OfflineCodex-Full-v1.0.0-win-x64'
$Model = 'qwen2.5-coder:7b'
$ModelRoot = Join-Path $Dist 'models/ollama'
$Ollama = Join-Path $Dist 'runtime/ollama/ollama.exe'
$Codex = Join-Path $Dist 'runtime/codex/codex.exe'

if (!(Test-Path $Ollama)) { throw 'Bundled Ollama is missing.' }
Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item $ModelRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item $ModelRoot -ItemType Directory -Force | Out-Null

$env:OLLAMA_MODELS = $ModelRoot
$env:OLLAMA_HOST = '127.0.0.1:11435'
$proc = Start-Process $Ollama -ArgumentList 'serve' -PassThru -WindowStyle Hidden
try {
    $ready = $false
    foreach ($i in 1..90) {
        try {
            Invoke-RestMethod 'http://127.0.0.1:11435/api/tags' -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        } catch { Start-Sleep 1 }
    }
    if (!$ready) { throw 'Bundled Ollama server did not start.' }

    & $Ollama pull $Model
    if ($LASTEXITCODE) { throw "Unable to pull $Model into the portable model store." }

    $tags = Invoke-RestMethod 'http://127.0.0.1:11435/api/tags' -TimeoutSec 15
    if (!($tags.models.name -contains $Model)) { throw "Portable model store does not expose $Model." }

    $request = @{
        model = $Model
        prompt = 'Reply with the single word OK.'
        stream = $false
        keep_alive = 0
        options = @{ num_predict = 8; temperature = 0 }
    } | ConvertTo-Json -Depth 4
    $answer = Invoke-RestMethod 'http://127.0.0.1:11435/api/generate' -Method Post -ContentType 'application/json' -Body $request -TimeoutSec 900
    if ([string]::IsNullOrWhiteSpace([string]$answer.response)) { throw 'Bundled model generation test returned no text.' }
} finally {
    Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue
}

$modelFiles = @(Get-ChildItem $ModelRoot -File -Recurse)
$modelBytes = ($modelFiles | Measure-Object Length -Sum).Sum
if ($modelFiles.Count -lt 2 -or $modelBytes -lt 3GB) {
    throw "Model was not embedded correctly: $($modelFiles.Count) files, $modelBytes bytes."
}

# The target machine is a 16 GB CPU-oriented Windows workstation. Remove optional
# NVIDIA CUDA payloads while retaining CPU and Vulkan backends.
Remove-Item (Join-Path $Dist 'runtime/ollama/lib/ollama/cuda_v12') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $Dist 'runtime/ollama/lib/ollama/cuda_v13') -Recurse -Force -ErrorAction SilentlyContinue

$readme = @"
# OfflineCodex Full v1.0.0

这是完整便携式离线 Codex 工具链，而不是自制聊天壳。

内置组件：
- OpenAI Codex CLI 0.144.6，以及 Windows command-runner 和 sandbox-setup 辅助程序
- Ollama 0.32.0 与已落盘的 qwen2.5-coder:7b 模型
- Microsoft Playwright MCP 0.0.78 与 Chromium
- Filesystem、Git、SQLite、Memory、Sequential Thinking MCP
- Node.js、Python、MinGit、ripgrep
- 13 个开发、调试、测试、审查、浏览器验证、数据分析、Office 和离线打包 Skills

使用：
1. 双击 SelfTest.cmd。
2. 测试通过后双击 Start-OfflineCodex.cmd。
3. 项目放入 workspace 目录。
4. 在 Codex 中输入 /mcp 查看六个 MCP 服务。

边界：工具链和模型均可断网运行，但 7B 本地模型的推理质量不等于云端 GPT-5.6。此 CPU/Vulkan 便携版主动删除了约 1.8 GB 的 NVIDIA CUDA 动态库；需要 NVIDIA CUDA 加速时应制作 GPU 专版。Gmail、Figma、Canva、Vercel 等云服务在彻底断网时不能工作，因此没有伪装为离线插件。
"@
Set-Content (Join-Path $Dist 'README_中文.md') $readme -Encoding UTF8

$selfTest = @'
$ErrorActionPreference='Stop'
$R=$PSScriptRoot
& (Join-Path $R 'Start-OfflineCodex.ps1') -ConfigureOnly
$tests=@(
 @('Codex','runtime/codex/codex.exe','--version'),
 @('Node','runtime/node/node.exe','--version'),
 @('Python','runtime/python/python.exe','--version'),
 @('Git','runtime/git/cmd/git.exe','--version'),
 @('ripgrep','runtime/rg/rg.exe','--version'),
 @('Ollama','runtime/ollama/ollama.exe','--version')
)
$tests|%{$o=&(Join-Path $R $_[1]) $_[2] 2>&1;if($LASTEXITCODE){throw "$($_[0]) failed"};Write-Host "[OK] $($_[0]) $($o|select -First 1)"}
$required='mcp/node/node_modules/@playwright/mcp/cli.js','mcp/node/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js','mcp/node/node_modules/@modelcontextprotocol/server-memory/dist/index.js','mcp/node/node_modules/@modelcontextprotocol/server-sequential-thinking/dist/index.js','runtime/browser','runtime/codex/codex-command-runner.exe','runtime/codex/codex-windows-sandbox-setup.exe'
$required|%{if(!(Test-Path (Join-Path $R $_))){throw "Missing $_"};Write-Host "[OK] $_"}
$modelFiles=@(Get-ChildItem (Join-Path $R 'models/ollama') -File -Recurse)
$modelBytes=($modelFiles|Measure-Object Length -Sum).Sum
if($modelBytes-lt 3GB){throw "Bundled model is incomplete: $modelBytes bytes"}
Write-Host "[OK] Bundled model $([math]::Round($modelBytes/1GB,2)) GiB"
& (Join-Path $R 'runtime/codex/codex.exe') mcp list
if($LASTEXITCODE){throw 'Codex MCP config failed'}
Write-Host '[PASS] OfflineCodex bundle self-test'
'@
Set-Content (Join-Path $Dist 'SelfTest.ps1') $selfTest -Encoding UTF8

$lock = [ordered]@{
    package = 'OfflineCodex Full'
    version = '1.0.0'
    codex = '0.144.6'
    ollama = '0.32.0'
    model = $Model
    model_bytes = $modelBytes
    playwright_mcp = '0.0.78'
    mcp = @('playwright','filesystem','git','sqlite','memory','sequential-thinking')
    skills = @('project-bootstrap','debug-and-fix','test-repair-loop','code-review','security-review','web-app-delivery','browser-qa-playwright','data-analysis','office-documents','local-research','git-workflow','offline-packaging','architecture-review')
    build_target = 'Windows x64 CPU/Vulkan portable'
    built_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$lock | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Dist 'COMPONENTS-LOCK.json') -Encoding UTF8

& (Join-Path $Dist 'SelfTest.ps1')
if ($LASTEXITCODE) { throw 'Final portable self-test failed.' }

$allBytes = (Get-ChildItem $Dist -File -Recurse | Measure-Object Length -Sum).Sum
@"
Self-test: PASS
Windows builder: GitHub Actions windows-latest
Codex: 0.144.6
MCP servers: 6
Skills: 13
Model: $Model
Model bytes: $modelBytes
End-to-end model generation: PASS
Total size GiB: $([math]::Round($allBytes/1GB,2))
"@ | Set-Content (Join-Path $Dist 'QA-REPORT.txt') -Encoding UTF8

$hashes = Get-ChildItem $Dist -File -Recurse | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object FullName | ForEach-Object {
    $stream = [IO.File]::Open($_.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    $hex = [Convert]::ToHexString($digest).ToLowerInvariant()
    "$hex  $([IO.Path]::GetRelativePath($Dist,$_.FullName).Replace('\','/'))"
}
Set-Content (Join-Path $Dist 'SHA256SUMS.txt') $hashes -Encoding ASCII
Write-Host "[PASS] Embedded model and final QA: $([math]::Round($allBytes/1GB,2)) GiB"
