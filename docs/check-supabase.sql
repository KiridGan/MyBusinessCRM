-- Только чтение. Запустите в Supabase SQL Editor; этот файл ничего не меняет.
-- Сверьте результат с docs/SUPABASE.md. Не добавляйте сюда ключи и пароли.
select column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'orders'
order by ordinal_position;

select c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'orders';

select policyname, permissive, roles, cmd, qual as using_expression, with_check
from pg_policies where schemaname = 'public' and tablename = 'orders';

select conname, pg_get_constraintdef(oid) as definition
from pg_constraint where conrelid = 'public.orders'::regclass;

select grantee, privilege_type from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'orders'
order by grantee, privilege_type;
