-- =============================================================================
-- request_keys 定期清理
-- 请求编号只用于短时间内的重试（秒到分钟级），每次调用顺带删除 30 天前的记录，
-- 避免表和每日备份无限增长。删除走 created_at 索引，正常情况下只删很少几行。
-- =============================================================================

create index if not exists request_keys_created_idx on public.request_keys (created_at);

create or replace function public._claim_request(p_request_id uuid, p_function text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_fn     text;
begin
  if p_request_id is null then
    return null;
  end if;

  delete from public.request_keys where created_at < now() - interval '30 days';

  insert into public.request_keys (request_id, function_name)
  values (p_request_id, p_function)
  on conflict (request_id) do nothing;

  if found then
    return null;
  end if;

  select function_name, result into v_fn, v_result
  from public.request_keys where request_id = p_request_id;

  if v_fn <> p_function then
    raise exception '请求编号已被其他操作使用' using hint = 'REQUEST_ID_CONFLICT';
  end if;
  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('duplicate', true);
end;
$$;

revoke execute on function public._claim_request(uuid, text) from anon, authenticated, public;
