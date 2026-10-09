# inventory-backup（私有仓库模板）

本目录是 **私有** 仓库 `inventory-backup` 的全部内容模板（Issue #7、#8）。
它放在公开仓库里只是为了版本管理 workflow 文件；**备份文件绝不能提交到公开仓库**。

| 文件 | 作用 | 频率 |
|---|---|---|
| `.github/workflows/backup.yml` | `pg_dump` → gzip → 上传为本仓库的 Release 附件；自动删除 90 天前的备份 | 每天北京时间 02:00 |
| `.github/workflows/keepalive.yml` | 用 anon key 调用 `ping()`，防止免费项目被暂停 | 每 3 天 |

## 一次性设置

1. 在 GitHub（JohnnyJiayin 账号）新建 **Private** 仓库 `inventory-backup`。
2. 把本目录下的所有文件（含 `.github/`）复制到新仓库根目录并推送：

   ```bash
   git clone https://github.com/JohnnyJiayin/inventory-backup.git
   cp -R ops/inventory-backup/. inventory-backup/
   cd inventory-backup && git add -A && git commit -m "init backup workflows" && git push
   ```

3. 在新仓库 Settings → Secrets and variables → Actions 添加：

   | Secret | 取值 |
   |---|---|
   | `SUPABASE_DB_URL` | Supabase 后台 **Connect → Session pooler** 连接串，把 `[YOUR-PASSWORD]` 换成数据库密码。免费版 Direct connection 只支持 IPv6，GitHub Actions 连不上 |
   | `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
   | `SUPABASE_ANON_KEY` | anon / publishable key |

4. Settings → Actions → General → Workflow permissions 选 **Read and write permissions**（备份任务需要创建 Release）。
5. Actions 页面分别手动运行一次 “每日数据库备份” 和 “保活 ping”，确认成功：
   - 仓库 Releases 中出现 `backup-<日期>-<时间>`，附件为 `inventory-<日期>-<时间>.sql.gz`
   - Supabase 后台 Table Editor 中 `heartbeat.pinged_at` 更新为刚才的时间

失败通知：定时任务失败时 GitHub 会自动发邮件给仓库所有者（个人设置 → Notifications → Actions 保持开启）。

## 为什么用 Release 而不是提交

提交到 git 的文件即使之后 `git rm`，也会永久留在历史里，仓库只会越来越大。
每个备份存为一个 Release 附件，删除 Release 时附件被真正删除，90 天保留才有效。
私有仓库的 Release 只有有权限的人能看到。

## 备份内容

- `public` schema 的全部表结构、数据、函数、视图、RLS 策略和权限。
- `supabase_migrations`：记录已执行的迁移版本。
- 不含：登录账号（`auth`，可在新项目重新创建同一个账号）、产品照片文件（在存储桶中，按月另行导出）。

## 恢复（演练见 Issue #54）

```bash
# 1. 新建（或清空）一个 Supabase 项目，取得 Session pooler 连接串 $DB_URL
# 2. 清空 public schema 后导入备份
psql "$DB_URL" -c 'drop schema public cascade'
gh release download backup-YYYYMMDD-HHMMSS -R JohnnyJiayin/inventory-backup
gunzip -c inventory-YYYYMMDD-HHMMSS.sql.gz | psql "$DB_URL"
# 导入时出现 “permission denied to change default privileges” 可以忽略（Supabase 内部角色的默认权限）
# 3. 创建照片存储桶及其权限：执行公开仓库 supabase/migrations/20260927000500_rls_and_grants.sql 末尾 “产品照片” 一节
# 4. 在 Authentication 中重新创建登录账号，关闭公开注册
```
