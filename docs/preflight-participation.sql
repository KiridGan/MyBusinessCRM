-- READ-ONLY METADATA CHECK, prepared but NOT executed against production.
-- Run only after agreeing to inspect the target project. No customer/auth rows.
begin transaction read only;
select x.object_name,to_regclass(x.object_name) present
from (values('public.orders'),('public.equipment'),('public.equipment_expenses'),('public.equipment_order_links'),('public.order_contractors'),('crm_equipment_private.order_budgets')) x(object_name);
select table_schema,table_name,column_name,data_type,is_nullable,is_generated,generation_expression
from information_schema.columns
where (table_schema='public' and table_name in ('equipment','equipment_expenses','equipment_order_links','order_contractors'))
 or (table_schema='crm_equipment_private' and table_name='order_budgets')
order by table_schema,table_name,ordinal_position;
select n.nspname schema_name,c.relname table_name,c.relrowsecurity,c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('orders','equipment','equipment_expenses','equipment_order_links','order_contractors');
select tablename,policyname,roles,cmd,qual,with_check from pg_policies
where schemaname='public' and tablename in ('orders','equipment','equipment_expenses','equipment_order_links','order_contractors') order by tablename,policyname;
select table_name,grantee,privilege_type from information_schema.role_table_grants
where table_schema='public' and table_name in ('equipment','equipment_expenses','equipment_order_links','order_contractors') order by table_name,grantee,privilege_type;
select c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) definition
from pg_trigger t join pg_class c on c.oid=t.tgrelid
where c.relnamespace='public'::regnamespace and c.relname in ('orders','equipment_expenses','order_contractors') and not t.tgisinternal
order by c.relname,t.tgname;
rollback;
