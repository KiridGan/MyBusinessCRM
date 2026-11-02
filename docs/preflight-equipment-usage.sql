-- READ ONLY. Inspect results; never repair production automatically.
select table_schema,table_name,column_name,data_type,udt_name,is_nullable
from information_schema.columns
where table_schema in ('public','crm_equipment_private','crm_meter_private')
and table_name in ('orders','equipment','equipment_order_links','equipment_expenses','order_contractors','order_budgets','equipment_meter_accounts','equipment_meter_entries','equipment_meter_events','guards')
order by table_schema,table_name,ordinal_position;
select n.nspname,c.relname,c.relrowsecurity,c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','crm_equipment_private') and c.relname in ('orders','equipment','equipment_order_links','equipment_expenses','order_contractors','order_budgets');
select schemaname,tablename,policyname,roles,cmd,qual,with_check from pg_policies
where schemaname='public' and tablename in ('orders','equipment','equipment_order_links','equipment_expenses','order_contractors') order by tablename,policyname;
select conrelid::regclass as relation,conname,pg_get_constraintdef(oid) as definition from pg_constraint
where conrelid in (to_regclass('public.orders'),to_regclass('public.equipment'),to_regclass('public.equipment_order_links'),to_regclass('public.equipment_expenses'),to_regclass('public.order_contractors')) order by relation,conname;
select tgrelid::regclass as relation,tgname,pg_get_triggerdef(oid) as definition
from pg_trigger where not tgisinternal and tgrelid in (to_regclass('public.orders'),to_regclass('public.equipment'),to_regclass('public.equipment_order_links'),to_regclass('public.equipment_expenses'),to_regclass('public.order_contractors')) order by relation,tgname;
select n.nspname,p.proname,p.prosecdef,pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','crm_equipment_private') and (p.proname like 'crm_%' or p.proname like 'equipment_%') order by n.nspname,p.proname;
-- Aggregate counts only, no customer data.
select count(*) as invalid_equipment from public.equipment where meter_value is null or meter_value<0 or meter_value::text in ('NaN','Infinity','-Infinity') or meter_kind is null or meter_kind not in ('hours','km');
select count(*) as invalid_links from public.equipment_order_links l left join public.orders o on o.id=l.order_id left join public.equipment e on e.id=l.equipment_id where o.id is null or e.id is null or l.user_id is distinct from o.user_id or l.user_id is distinct from e.user_id or l.work_hours is null or l.work_hours<0 or l.work_hours::text in ('NaN','Infinity','-Infinity');
