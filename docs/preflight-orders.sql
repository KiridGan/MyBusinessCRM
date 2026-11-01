-- METADATA ONLY. Prepared for a separate, explicitly approved read-only check.
-- This file has NOT been executed against the user's Supabase.
-- No client rows, auth.users, keys, passwords or tokens are selected.
begin transaction read only;
select current_database() database_name,current_user inspected_as,version() postgres_version;
select rolname,rolsuper,rolbypassrls,rolinherit from pg_roles where rolname in ('anon','authenticated');
select member.rolname member_role,granted.rolname granted_role from pg_auth_members m join pg_roles member on member.oid=m.member join pg_roles granted on granted.oid=m.roleid where member.rolname in ('anon','authenticated');
select column_name,data_type,udt_name,is_nullable,column_default,is_generated,generation_expression
from information_schema.columns where table_schema='public' and table_name='orders' order by ordinal_position;
select c.relkind,c.relrowsecurity,c.relforcerowsecurity
from pg_class c where c.oid=to_regclass('public.orders');
select conname,contype,condeferrable,pg_get_constraintdef(oid) definition
from pg_constraint where conrelid=to_regclass('public.orders') order by conname;
select indexname,indexdef from pg_indexes where schemaname='public' and tablename='orders' order by indexname;
select policyname,permissive,roles,cmd,qual,with_check
from pg_policies where schemaname='public' and tablename='orders' order by policyname;
select grantee,privilege_type from information_schema.role_table_grants
where table_schema='public' and table_name='orders' order by grantee,privilege_type;
select r.role_name,has_table_privilege(r.role_name,'public.orders','TRUNCATE') can_truncate,
 has_table_privilege(r.role_name,'public.orders','TRIGGER') can_create_trigger
from (values('anon'),('authenticated')) r(role_name);
select t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) trigger_definition,
 n.nspname function_schema,p.proname function_name,p.prosecdef security_definer,p.proconfig function_settings
from pg_trigger t join pg_proc p on p.oid=t.tgfoid join pg_namespace n on n.oid=p.pronamespace
where t.tgrelid=to_regclass('public.orders') and not t.tgisinternal order by t.tgname;
select to_regclass('public.equipment') equipment,to_regclass('public.equipment_order_links') equipment_links,
 to_regclass('public.order_contractors') contractors,to_regclass('crm_equipment_private.order_budgets') ledger;
select c.relname,t.tgname,(t.tgtype&2)<>0 is_before,pg_get_triggerdef(t.oid) definition
from pg_trigger t join pg_class c on c.oid=t.tgrelid
where c.relnamespace='public'::regnamespace and c.relname in ('orders','equipment_expenses','order_contractors')
 and not t.tgisinternal order by c.relname,t.tgname;
rollback;
