# 线上 Supabase 配置（Issue #1、#7、#8）

以下步骤需要在网页后台手动完成，只做一次。

## 1. 创建项目（#1）

1. 在 <https://supabase.com> 用免费版创建项目，Region 选 **Southeast Asia (Singapore)** 或 **Northeast Asia (Tokyo)**。
2. 数据库密码保存到密码管理器（**不要**写进仓库）。
3. 记录 Project Settings → API 中的：
   - Project URL（`https://<project-ref>.supabase.co`）——可以公开
   - anon / publishable key ——可以公开
   - service_role / secret key ——**只**保存在密码管理器，绝不放进 App 或仓库

## 2. 执行数据库迁移（#3–#6、#14、#15、#23、#27–#29、#37）

```bash
supabase login
supabase link --project-ref <project-ref>     # 需要输入数据库密码
supabase db push                              # 按顺序执行 supabase/migrations/*.sql
```

迁移会自动完成：建表与约束、时区设为 Asia/Shanghai、库存视图、单号生成、操作记录触发器、
业务函数（产品、入库、经销商、出库订单、撤销）、订单与保修查询视图、RLS 与权限、私有存储桶 `product-photos`。`seed.sql` 只用于本地，不会推送到线上。

## 3. 登录设置（#1）

1. Authentication → Sign In / Providers：
   - **Allow new users to sign up：关闭**（关闭公开注册）
   - Email provider 保持启用；Confirm email 可以关闭
2. Authentication → Users → Add user → Create new user：填写唯一的登录邮箱和密码，勾选 Auto Confirm。

## 4. 验收检查

```bash
URL=https://<project-ref>.supabase.co; KEY=<anon key>
# 公开注册已关闭：返回 signup_disabled
curl -s -X POST "$URL/auth/v1/signup" -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d '{"email":"someone@example.com","password":"whatever123"}'
# 未登录读不到业务数据：返回 permission denied
curl -s "$URL/rest/v1/product_models?select=*" -H "apikey: $KEY"
# 保活函数可以调用：返回 204
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/rpc/ping" -H "apikey: $KEY" \
  -H "Content-Type: application/json" -d '{}'
```

- SQL Editor 中执行下面的查询，结果只有 `ping`（未登录只能调用保活函数）：

  ```sql
  select proname from pg_proc
  where pronamespace = 'public'::regnamespace and has_function_privilege('anon', oid, 'execute');
  ```

- Storage → `product-photos` 显示为 Private。
- 用创建的账号在 iPad App 登录成功。

## 5. 备份与保活（#7、#8）

按 [ops/inventory-backup/README.md](../ops/inventory-backup/README.md) 新建 **私有** 仓库 `inventory-backup`，
配置 Secrets 后手动运行一次两个 workflow。
