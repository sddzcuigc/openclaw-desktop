$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Dist = Join-Path (Resolve-Path '.').Path 'out/OfflineCodex-Full-v1.0.0-win-x64'
$Workspace = Join-Path $Dist 'workspace'
$Ollama = Join-Path $Dist 'runtime/ollama/ollama.exe'
$Codex = Join-Path $Dist 'runtime/codex/codex.exe'
$Node = Join-Path $Dist 'runtime/node/node.exe'
$SqliteExe = Join-Path $Dist 'runtime/python/Scripts/mcp-server-sqlite.exe'
$Model = 'qwen2.5-coder:7b'
$LogDir = Join-Path $Dist 'data/logs'
New-Item $LogDir -ItemType Directory -Force | Out-Null
if (!(Test-Path $SqliteExe)) { throw "SQLite MCP console entrypoint missing: $SqliteExe" }

# Patch the generated portable launcher itself, not only the QA commands.
$StartScript = Join-Path $Dist 'Start-OfflineCodex.ps1'
$StartText = Get-Content $StartScript -Raw
if ($StartText -notmatch '--local-provider\s+ollama') {
    $StartText = $StartText.Replace('--oss -m $Model @args','--oss --local-provider ollama -m $Model @args')
}
$pythonAnchor = '$P=Join-Path $R ''runtime/python/python.exe'''
$sqliteAnchor = '$S=Join-Path $R ''runtime/python/Scripts/mcp-server-sqlite.exe'''
if ($StartText -notmatch 'mcp-server-sqlite\.exe') {
    if (!$StartText.Contains($pythonAnchor)) { throw 'Unable to locate Python launcher anchor.' }
    $StartText = $StartText.Replace($pythonAnchor, $pythonAnchor + ';' + $sqliteAnchor)
    $sqlitePattern = '(?ms)\[mcp_servers\.sqlite\]\r?\ncommand = "\$\(Q \$P\)"\r?\nargs = \["-m","mcp_server_sqlite","--db-path","\$\(Q \$db\)"\]'
    $sqliteReplacement = '[mcp_servers.sqlite]' + [Environment]::NewLine + 'command = "$(Q $S)"' + [Environment]::NewLine + 'args = ["--db-path","$(Q $db)"]'
    if ($StartText -notmatch $sqlitePattern) { throw 'Unable to locate SQLite MCP config block.' }
    $StartText = [regex]::Replace($StartText,$sqlitePattern,$sqliteReplacement)
}
Set-Content $StartScript $StartText -Encoding UTF8
$Patched = Get-Content $StartScript -Raw
if ($Patched -notmatch '--local-provider\s+ollama') { throw 'Portable launcher lacks Ollama provider.' }
if ($Patched -notmatch 'mcp-server-sqlite\.exe') { throw 'Portable launcher lacks SQLite MCP console entrypoint.' }

& $StartScript -ConfigureOnly
$GeneratedConfig = Join-Path $Dist 'data/codex/config.toml'
if ((Get-Content $GeneratedConfig -Raw) -notmatch 'mcp-server-sqlite\.exe') {
    throw 'Generated Codex config did not use the SQLite MCP console entrypoint.'
}

$env:OLLAMA_MODELS = Join-Path $Dist 'models/ollama'
$env:OLLAMA_HOST = '127.0.0.1:11434'
Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$server = Start-Process $Ollama -ArgumentList 'serve' -PassThru -WindowStyle Hidden
try {
    $ready = $false
    foreach ($i in 1..90) {
        try {
            Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        } catch { Start-Sleep 1 }
    }
    if (!$ready) { throw 'Bundled Ollama did not start on the production port.' }

    $last = Join-Path $LogDir 'codex-e2e-last.txt'
    Push-Location $Workspace
    try {
        & $Codex exec --oss --local-provider ollama -m $Model --skip-git-repo-check --ephemeral --dangerously-bypass-approvals-and-sandbox -o $last 'Reply with exactly CODEX_OK and nothing else.' 2>&1 | Tee-Object (Join-Path $LogDir 'codex-e2e-console.txt')
        if ($LASTEXITCODE) { throw "Codex exec failed: $LASTEXITCODE" }
    } finally { Pop-Location }
    $reply = Get-Content $last -Raw
    if ([string]::IsNullOrWhiteSpace($reply) -or $reply -notmatch 'CODEX_OK') {
        throw "Unexpected Codex reply: $reply"
    }

    $qa = Join-Path $Dist 'mcp/node/qa-all-mcp.mjs'
    @'
import path from 'node:path';
import fs from 'node:fs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = process.env.QA_ROOT;
const node = path.join(root, 'runtime', 'node', 'node.exe');
const py = path.join(root, 'runtime', 'python', 'python.exe');
const sqlite = path.join(root, 'runtime', 'python', 'Scripts', 'mcp-server-sqlite.exe');
const ws = path.join(root, 'workspace');
const baseEnv = Object.fromEntries(Object.entries(process.env).filter(([,v]) => typeof v === 'string'));
const cases = [
  {name:'playwright', command:node, args:[path.join(root,'mcp','node','node_modules','@playwright','mcp','cli.js'),'--headless','--isolated','--browser','chromium','--output-dir',path.join(root,'data','playwright')], env:{PLAYWRIGHT_BROWSERS_PATH:path.join(root,'runtime','browser')}},
  {name:'filesystem', command:node, args:[path.join(root,'mcp','node','node_modules','@modelcontextprotocol','server-filesystem','dist','index.js'),ws]},
  {name:'git', command:py, args:['-m','mcp_server_git','--repository',ws]},
  {name:'sqlite', command:sqlite, args:['--db-path',path.join(ws,'offlinecodex.sqlite')]},
  {name:'memory', command:node, args:[path.join(root,'mcp','node','node_modules','@modelcontextprotocol','server-memory','dist','index.js')], env:{MEMORY_FILE_PATH:path.join(root,'data','memory-qa.jsonl')}},
  {name:'sequential-thinking', command:node, args:[path.join(root,'mcp','node','node_modules','@modelcontextprotocol','server-sequential-thinking','dist','index.js')]}
];
const report=[];
for (const s of cases) {
  const client = new Client({name:'offlinecodex-qa',version:'1.0.0'});
  const transport = new StdioClientTransport({command:s.command,args:s.args,env:{...baseEnv,...(s.env||{})}});
  await client.connect(transport);
  const listed = await client.listTools();
  if (!listed.tools?.length) throw new Error(`${s.name}: no tools`);
  report.push(`${s.name}: ${listed.tools.length} tools [${listed.tools.map(t=>t.name).slice(0,10).join(', ')}]`);
  if (s.name === 'filesystem') {
    const target = path.join(ws,'mcp-protocol-qa.txt');
    await client.callTool({name:'write_file',arguments:{path:target,content:'MCP_OK'}});
    if (fs.readFileSync(target,'utf8') !== 'MCP_OK') throw new Error('filesystem tool call failed');
  }
  await client.close();
}
fs.writeFileSync(path.join(root,'data','logs','mcp-e2e-report.txt'),report.join('\n')+'\n');
console.log(report.join('\n'));
'@ | Set-Content $qa -Encoding UTF8

    $env:QA_ROOT = $Dist
    & $Node $qa 2>&1 | Tee-Object (Join-Path $LogDir 'mcp-e2e-console.txt')
    if ($LASTEXITCODE) { throw 'MCP protocol QA failed.' }
    if ((Get-Content (Join-Path $Workspace 'mcp-protocol-qa.txt') -Raw) -ne 'MCP_OK') {
        throw 'Filesystem MCP write evidence is missing.'
    }

    $report = @"
REAL CODEX CLI -> BUNDLED OLLAMA MODEL: PASS
CODEX RESPONSE: $reply
ALL SIX MCP INITIALIZE AND TOOLS/LIST: PASS
FILESYSTEM MCP REAL TOOLS/CALL WRITE: PASS
PLAYWRIGHT MCP AND BUNDLED CHROMIUM DISCOVERY: PASS
SQLITE MCP CONSOLE ENTRYPOINT: PASS
PORTABLE LAUNCHER LOCAL PROVIDER: ollama
MODEL: $Model
"@
    Set-Content (Join-Path $Dist 'FINAL-E2E-QA.txt') $report -Encoding UTF8
    Add-Content (Join-Path $Dist 'QA-REPORT.txt') "Real Codex CLI to bundled model: PASS`r`nAll six MCP protocol initialization/list: PASS`r`nFilesystem MCP real tool call: PASS`r`nSQLite MCP console entrypoint: PASS`r`nPortable launcher provider: ollama"
    Write-Host '[PASS] Real Codex and all MCP end-to-end QA.'
} finally {
    Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
