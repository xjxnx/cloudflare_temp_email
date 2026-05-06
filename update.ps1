<#
.SYNOPSIS
    一键同步上游 + 部署到 Cloudflare 的更新脚本。

.DESCRIPTION
    工作流:
      1. 检查工作目录是否干净
      2. 拉取 upstream/main 最新代码
      3. 合并到本地 main (有冲突会停下来等你解决)
      4. 推送到 GitHub Fork (origin/main)
      5. 检测 db/ 下是否有新的 SQL 迁移文件并提醒
      6. cd worker  -> pnpm install + pnpm run deploy
      7. cd frontend -> pnpm install + pnpm run deploy
      8. 通过 curl 验证 mail.524028.xyz 是否切换到最新版本

    所有 pnpm 调用都通过 corepack 完成,无需全局安装 pnpm。

.PARAMETER SkipMerge
    跳过 git fetch/merge/push, 直接进入部署步骤。
    适合已经手动 push 完代码、只想重新部署的场景。

.PARAMETER SkipBackend
    跳过后端 (worker) 部署。

.PARAMETER SkipFrontend
    跳过前端 (frontend) 部署。

.EXAMPLE
    .\update.ps1
    完整一键更新 (拉取上游 + 部署前后端)。

.EXAMPLE
    .\update.ps1 -SkipMerge
    跳过同步上游,只重新部署前后端。
#>
[CmdletBinding()]
param(
    [switch]$SkipMerge,
    [switch]$SkipBackend,
    [switch]$SkipFrontend
)

$ErrorActionPreference = 'Stop'
chcp 65001 | Out-Null

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrontendDir = Join-Path $ProjectRoot 'frontend'
$WorkerDir = Join-Path $ProjectRoot 'worker'
$DbDir = Join-Path $ProjectRoot 'db'
$ProductionUrl = 'https://mail.524028.xyz/'

function Write-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[X] $Message" -ForegroundColor Red
}

function Stop-IfFailed {
    param([string]$Description)
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Description 失败 (exit code: $LASTEXITCODE)"
        exit 1
    }
}

Write-Host @"

==============================================================
   MiaoMail - 一键更新脚本（基于 Cloudflare）
==============================================================
   项目目录: $ProjectRoot
   生产域名: $ProductionUrl

"@ -ForegroundColor Magenta

Push-Location $ProjectRoot
try {
    if (-not $SkipMerge) {
        Write-Step "1. 检查工作目录是否干净"
        $gitStatus = git status --porcelain
        if ($gitStatus) {
            Write-Err "工作目录有未提交的修改:"
            git status --short
            Write-Host "`n请先提交或 stash 后再运行此脚本。" -ForegroundColor Yellow
            exit 1
        }
        Write-Ok "工作目录干净"

        Write-Step "2. 拉取上游 (upstream/main) 最新代码"
        git fetch upstream
        Stop-IfFailed "git fetch upstream"

        $behind = (git log --oneline HEAD..upstream/main | Measure-Object -Line).Lines
        $ahead = (git log --oneline upstream/main..HEAD | Measure-Object -Line).Lines
        Write-Host "  本地落后 upstream/main: $behind 个提交"
        Write-Host "  本地领先 upstream/main: $ahead 个提交 (你的自定义提交)"
        if ($behind -eq 0) {
            Write-Ok "已经是最新版本,无需合并"
        } else {
            Write-Step "3. 合并上游到本地 main"
            $mergeOutput = git merge upstream/main 2>&1
            $mergeExit = $LASTEXITCODE
            $mergeOutput | ForEach-Object { Write-Host "  $_" }
            if ($mergeExit -ne 0) {
                Write-Err "合并冲突! 请手动解决:"
                git status --short | Where-Object { $_ -match '^(UU|AA|DD)' }
                Write-Host "`n解决冲突后,执行:" -ForegroundColor Yellow
                Write-Host "  git add <冲突文件>"
                Write-Host "  git commit"
                Write-Host "  .\update.ps1 -SkipMerge   # 跳过合并步骤继续部署"
                exit 1
            }
            Write-Ok "合并完成"

            Write-Step "4. 推送到 GitHub Fork (origin/main)"
            git push origin main
            Stop-IfFailed "git push origin main"
            Write-Ok "Push 成功"
        }

        Write-Step "5. 检查是否有新的数据库迁移文件"
        $newSqls = git diff --name-only --diff-filter=A "HEAD@{1}..HEAD" -- db/ 2>$null
        if ($newSqls) {
            Write-Warn "本次合并引入了新的 SQL 迁移文件:"
            $newSqls | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
            Write-Host @"

请前往 Cloudflare Dashboard 手动执行这些 SQL:
  1. https://dash.cloudflare.com/
  2. Workers and Pages -> D1 -> cloudflare_temp_email -> Console
  3. 粘贴上面文件中的 SQL 内容并执行

"@ -ForegroundColor Yellow
            $confirm = Read-Host "迁移完成后按回车继续部署 (输入 q 退出)"
            if ($confirm -eq 'q') {
                Write-Host "已退出。完成迁移后重新运行: .\update.ps1 -SkipMerge" -ForegroundColor Yellow
                exit 0
            }
        } else {
            Write-Ok "无需数据库迁移"
        }
    } else {
        Write-Warn "已跳过 git 同步步骤 (-SkipMerge)"
    }

    if (-not $SkipBackend) {
        Write-Step "6. 部署后端 Worker"
        Push-Location $WorkerDir
        try {
            Write-Host "  -> pnpm install" -ForegroundColor DarkGray
            corepack pnpm install --silent 2>&1 | Out-Null
            Stop-IfFailed "worker pnpm install"
            Write-Host "  -> pnpm run deploy" -ForegroundColor DarkGray
            corepack pnpm run deploy 2>&1 | Tee-Object -Variable workerOut | Out-Null
            Stop-IfFailed "worker pnpm run deploy"
            $workerUrl = ($workerOut | Where-Object { $_ -match 'https://[\w.-]+\.workers\.dev' } | Select-Object -First 1)
            Write-Ok "Worker 部署完成 $workerUrl"
        } finally {
            Pop-Location
        }
    } else {
        Write-Warn "已跳过后端部署 (-SkipBackend)"
    }

    if (-not $SkipFrontend) {
        Write-Step "7. 部署前端 Pages (使用 prod 模式 = .env.prod)"
        Push-Location $FrontendDir
        try {
            Write-Host "  -> pnpm install" -ForegroundColor DarkGray
            corepack pnpm install --silent 2>&1 | Out-Null
            Stop-IfFailed "frontend pnpm install"
            Write-Host "  -> pnpm run deploy (npm run build + wrangler pages deploy)" -ForegroundColor DarkGray
            corepack pnpm run deploy 2>&1 | Tee-Object -Variable frontendOut | Out-Null
            Stop-IfFailed "frontend pnpm run deploy"
            $deployId = ($frontendOut | Where-Object { $_ -match 'https://(\w+)\.cloudflare-temp-email-frontend' } | Select-Object -First 1)
            Write-Ok "Frontend 部署完成 $deployId"
        } finally {
            Pop-Location
        }
    } else {
        Write-Warn "已跳过前端部署 (-SkipFrontend)"
    }

    Write-Step "8. 验证 $ProductionUrl"
    try {
        $resp = Invoke-WebRequest -Uri "$ProductionUrl`?cb=$(Get-Random)" -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' }
        $jsRef = [regex]::Match($resp.Content, 'assets/index-([^"]+)\.js').Groups[1].Value
        if ($jsRef) {
            Write-Ok "生产环境引用的 JS hash: $jsRef"
            Write-Host "  (每次发布都会变, 只要不是 'bVF4r0wh' 那种旧的 build:pages 错误版本就 OK)" -ForegroundColor DarkGray
        }
        if ($resp.Content -match 'Cloudflare Access') {
            Write-Warn "生产域名被 Cloudflare Access 拦截!"
        }
    } catch {
        Write-Warn "无法验证: $($_.Exception.Message)"
    }

    Write-Host @"

==============================================================
   全部完成!
==============================================================
   下一步:
   1. 用无痕窗口打开 $ProductionUrl 验证新版本生效
      (普通浏览器有 PWA 缓存, 需要 F12 -> Application -> Storage -> Clear site data)
   2. 测试核心功能: 收发邮件 / Admin 后台

"@ -ForegroundColor Magenta
} finally {
    Pop-Location
}
