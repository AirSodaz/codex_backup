# Codex R2 Backup 中文说明

`codex-backup` 是一个跨平台 Rust 命令行工具，用于把本机 Codex 的历史记录、记忆文件和 SQLite 状态备份到 Cloudflare R2。底层备份与恢复由 Restic 负责，R2 通过 Restic 的 S3 后端接入。

这个项目的重点是安全地备份 `~/.codex` 中真正需要保留的工作上下文，同时避开认证信息、沙箱密钥、缓存和临时文件。

## 备份内容

默认从 `~/.codex` 采集以下内容：

- `sessions`
- `archived_sessions`
- `session_index.jsonl`
- `history.jsonl`
- `memories`
- 根目录下的 `logs_*.sqlite` 和 `state_*.sqlite`

SQLite 文件不会直接复制。工具会先用 SQLite online backup API 生成一致性快照，再把快照放入临时 staging 目录。

以下内容会被刻意排除：

- `auth.json`
- `.sandbox-secrets`
- `cache`
- `tmp`
- `.tmp`
- `.sandbox`
- `.sandbox-bin`
- `plugins/cache`
- `vendor_imports`
- `worktrees`

## 准备工作

先准备一个 Cloudflare R2 bucket，然后在仓库根目录运行一键安装脚本。

Windows：

```powershell
.\scripts\install.ps1
```

macOS / Linux：

```sh
chmod +x scripts/install.sh
./scripts/install.sh
```

安装脚本会检查或安装 Rust、Restic 和 `codex-backup` CLI，然后交互式询问 R2
或 `RESTIC_REPOSITORY` 配置，把私有 `.env` 写到平台应用数据目录，并通过
`codex-backup init --set-password` 把 Restic 仓库密码保存到系统凭据管理器、
初始化仓库。

已有 `.env` 默认不会被覆盖；Windows 传 `-ForceEnv`、macOS/Linux 传
`--force-env` 才会重写。只想安装依赖和 CLI、不做交互初始化时，可以传
`-SkipInit` 或 `--skip-init`。

如需安装每天 03:00 自动备份计划，需要显式开启：

```powershell
.\scripts\install.ps1 -InstallSchedule -ScheduleTime 03:00
```

```sh
./scripts/install.sh --install-schedule --schedule-time 03:00
```

手动开发或排障时，也可以自己安装 Rust 和 Restic，然后安装 CLI：

```powershell
cargo install --path . --locked --force --bin codex-backup
Copy-Item .env.example .env
codex-backup doctor --env-file .env
codex-backup init --set-password --env-file .env
```

`.env` 中的 R2 信息格式如下：

```dotenv
R2_ACCOUNT_ID=your-cloudflare-account-id
R2_BUCKET=your-r2-bucket-name
R2_PREFIX=codex/history

R2_ACCESS_KEY_ID=your-r2-access-key-id
R2_SECRET_ACCESS_KEY=your-r2-secret-access-key
R2_REGION=auto
```

如果你已经有完整的 Restic 仓库地址，也可以直接设置：

```dotenv
RESTIC_REPOSITORY=s3:https://your-account-id.r2.cloudflarestorage.com/your-r2-bucket-name/codex/history
```

默认情况下，工具会优先读取当前目录的 `.env`；如果不存在，则读取平台应用数据目录中的 `.env`。

## 检查环境

运行：

```powershell
codex-backup doctor
```

它会检查：

- `restic` 是否可用
- `.env` 是否存在
- Codex 目录是否存在
- 系统 keyring 是否可用
- 当前平台是否支持计划任务

## 初始化仓库

建议把 Restic 仓库密码保存到系统凭据管理器：

```powershell
codex-backup init --set-password
```

工具默认使用各平台的系统凭据存储：

- Windows Credential Manager
- macOS Keychain
- Linux Secret Service

在 CI、服务器或无桌面环境中，也可以改用环境变量或密码文件：

```powershell
$env:RESTIC_PASSWORD="your-restic-password"
codex-backup backup
```

或者：

```powershell
codex-backup backup --password-file C:\path\to\restic-password.txt
```

## 执行备份

普通备份：

```powershell
codex-backup backup
```

备份流程会先创建 staging 目录，再调用 Restic 上传到 R2。成功上传后，默认会清理 staging 目录。

只做本地 staging，不上传到 Restic：

```powershell
codex-backup backup --skip-restic --keep-staging
```

使用非默认 Codex 目录进行测试：

```powershell
codex-backup backup --skip-restic --keep-staging --codex-dir C:\path\to\.codex
```

Restic snapshot 会带上两个标签：

- `codex`
- 当前平台标签：`windows`、`macos` 或 `linux`

每次成功上传后会执行保留策略：

- 保留 7 个每日快照
- 保留 4 个每周快照
- 保留 6 个每月快照

## 计划任务

安装每天 03:00 自动备份：

```powershell
codex-backup schedule install --time 03:00
```

移除计划任务：

```powershell
codex-backup schedule remove
```

各平台使用原生计划任务能力：

- Windows：Task Scheduler，通过 `schtasks.exe`
- macOS：用户级 LaunchAgent
- Linux：systemd user service 和 timer

Windows 默认任务名是 `Codex R2 History Backup`。其他平台默认任务名是 `codex-backup`。

## 检查远端仓库

查看快照、检查仓库，并执行保留策略清理：

```powershell
codex-backup check
```

只做只读检查，不执行 prune：

```powershell
codex-backup check --skip-prune
```

## 恢复备份

先把最新快照恢复到临时目录，不覆盖当前 `~/.codex`：

```powershell
codex-backup restore
```

指定快照：

```powershell
codex-backup restore --snapshot <snapshot-id>
```

确认恢复内容无误，并关闭 Codex 后，再应用到 `~/.codex`：

```powershell
codex-backup restore --apply
```

应用恢复时，工具会先把当前受管理的文件移动到平台应用数据目录下的 rollback 目录，再复制恢复出来的内容。认证文件和沙箱密钥不会被恢复。

恢复前请注意：

- 应用恢复前必须关闭 Codex。
- `auth.json` 和 `.sandbox-secrets` 不属于备份范围。
- SQLite 的 `-wal` 和 `-shm` 文件会在恢复时被移动到 rollback 目录，避免和恢复后的数据库状态冲突。

## 常用参数

多数命令都支持这些参数：

- `--env-file <path>`：指定 `.env` 文件路径
- `--password-file <path>`：指定 Restic 密码文件
- `--codex-dir <path>`：指定要备份或恢复的 Codex 目录

`backup` 额外支持：

- `--work-root <path>`：指定 staging 根目录
- `--skip-restic`：只创建 staging，不上传
- `--keep-staging`：备份后保留 staging 目录

`restore` 额外支持：

- `--snapshot <id>`：恢复指定快照，默认是 `latest`
- `--target-root <path>`：指定 Restic 恢复目标根目录
- `--rollback-root <path>`：指定当前文件的回滚保存目录
- `--apply`：把恢复结果应用到 Codex 目录

## 安全边界

这个工具只备份 Codex 的历史上下文和本地状态，不备份登录凭据或沙箱密钥。R2 访问密钥应只放在本机 `.env` 或安全的运行环境中，不要提交到 Git。

Restic 仓库密码独立于 R2 密钥。丢失 Restic 密码会导致已有备份无法解密，建议使用系统 keyring 或安全的密码管理器保存。

## 发布

GitHub Actions 会在每次 push 时为 Windows x64、Windows ARM64、Linux x64、Linux ARM64、macOS Intel 和 macOS Apple Silicon 构建 CLI。普通分支 push 只会在对应
workflow run 中保留构建 artifacts。

推送 `v0.1.0` 这类版本 tag 时，workflow 会自动创建或更新 GitHub Release。发布产物命名为 Windows 上的
`codex-backup-<version>-<platform>.zip`，以及 Linux / macOS 上的
`codex-backup-<version>-<platform>.tar.gz`。每个 release 还会附带
`SHA256SUMS.txt`。

## 开发与验证

运行测试：

```powershell
cargo test
```

运行完整本地检查：

```powershell
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```
