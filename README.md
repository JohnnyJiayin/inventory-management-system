# 库存管理系统

供一台 iPad 使用的库存管理 App：产品建档、扫码入库、订单出库、经销商与价格、保修和统计报表。
App 使用 SwiftUI，数据保存在 Supabase（PostgreSQL）。所有写操作都调用数据库业务函数，在一个事务里完成。

- 需求与设计文档：[Wiki](https://github.com/JohnnyJiayin/inventory-management-system/wiki)
  （[架构设计](https://github.com/JohnnyJiayin/inventory-management-system/wiki/%E6%9E%B6%E6%9E%84%E8%AE%BE%E8%AE%A1)、[数据结构](https://github.com/JohnnyJiayin/inventory-management-system/wiki/%E6%95%B0%E6%8D%AE%E7%BB%93%E6%9E%84)、[验收标准](https://github.com/JohnnyJiayin/inventory-management-system/wiki/%E9%AA%8C%E6%94%B6%E6%A0%87%E5%87%86)）
- 任务：[Issues](https://github.com/JohnnyJiayin/inventory-management-system/issues)

## 目录结构

```
ios/                          Xcode 项目（XcodeGen：ios/project.yml）
  InventoryApp/
    App/                      入口、登录、网络监测、导航
    Features/                 按页面分：首页、产品、入库、出库、经销商、报表、设置
    Scanner/                  扫码模块（VisionKit，不支持时自动改用 AVFoundation）
    Services/                 Supabase 调用
    Models/                   数据模型
  InventoryAppUITests/        端到端 UI 测试（模拟器 + 本地 supabase）
  Config/                     Base.xcconfig；Secrets.xcconfig 不提交
supabase/
  migrations/                 建表、约束、视图、业务函数、权限（按顺序执行）
  tests/                      pgTAP 测试 + 并发测试脚本
  seed.sql                    仅本地使用的测试账号与演示数据
ops/inventory-backup/         私有备份仓库的 workflow 模板（每日备份、保活）
docs/                         上线配置与验收清单
.github/workflows/            数据库测试 CI
```

## 本地开发

需要：Xcode 16+、[Docker Desktop](https://www.docker.com/products/docker-desktop/)、
[Supabase CLI](https://supabase.com/docs/guides/cli)、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install supabase/tap/supabase xcodegen`）。

### 数据库

```bash
supabase start            # 本地 Supabase（端口 544xx，见 supabase/config.toml）
supabase db reset         # 从头执行全部迁移 + seed.sql
supabase test db          # pgTAP 测试
PSQL="docker exec supabase_db_inventory-management-system psql" \
DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres \
  ./supabase/tests/concurrency.sh   # 并发测试（单号、重复提交）
```

本地测试账号（只存在于本地库）：`owner@example.com` / `test-pass-123`。

### iOS App

```bash
cp ios/Config/Secrets.example.xcconfig ios/Config/Secrets.xcconfig   # 填写 Supabase 地址与 anon key
cd ios && xcodegen generate && open InventoryApp.xcodeproj
```

- 连接本地库：`SUPABASE_URL = http:/$()/127.0.0.1:54421`，`SUPABASE_ANON_KEY` 用 `supabase status` 显示的 Publishable key（仅模拟器）。
- 真机：填线上项目地址和 anon key，并在 `Secrets.xcconfig` 中设置 `DEVELOPMENT_TEAM`。
- UI 测试：`supabase db reset` 后在 Xcode 中运行 `InventoryAppUITests`（Cmd+U）。

## 上线配置

见 [docs/supabase-setup.md](docs/supabase-setup.md)：创建 Supabase 项目、执行迁移、关闭注册、创建账号、配置备份与保活。

## 安全

仓库是公开的。Supabase 项目地址和 anon key 可以公开（所有表开启 RLS，未登录读不到任何数据）；
**service_role 密钥、数据库密码、备份文件绝不能提交**（`.gitignore` 已排除 `Secrets.xcconfig`、`.env`、备份文件）。
