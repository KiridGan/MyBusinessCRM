-- Prepared read-only inspection. NOT executed against production.
-- Contains no customer row values, passwords or keys. Run only when approved.
begin transaction read only;
select to_regclass('public.order_budgets') public_budget,
 to_regclass('crm_equipment_private.order_budgets') private_budget,
 to_regclass('public.order_contractors') contractors;
select table_schema,table_name,column_name,data_type,udt_name,is_nullable,column_default
from information_schema.columns where (table_schema='public' and table_name in ('orders','equipment','equipment_expenses','equipment_order_links','order_contractors')) or (table_schema='crm_equipment_private' and table_name='order_budgets')
order by table_schema,table_name,ordinal_position;
select cl.relname,co.conname,co.contype,pg_get_constraintdef(co.oid) definition
from pg_constraint co join pg_class cl on cl.oid=co.conrelid
where co.conrelid in (to_regclass('public.orders'),to_regclass('public.equipment'),to_regclass('public.equipment_expenses'),to_regclass('public.equipment_order_links')) order by cl.relname,co.conname;
select c.relname,c.relrowsecurity,c.relforcerowsecurity from pg_class c where c.oid in (to_regclass('public.orders'),to_regclass('public.equipment'),to_regclass('public.equipment_expenses'),to_regclass('public.equipment_order_links'));
select tablename,policyname,roles,cmd,qual,with_check from pg_policies where schemaname='public' and tablename in ('orders','equipment','equipment_expenses','equipment_order_links') order by tablename,policyname;
select table_name,grantee,privilege_type from information_schema.role_table_grants where table_schema='public' and table_name in ('orders','equipment','equipment_expenses','equipment_order_links') order by table_name,grantee,privilege_type;
select t.tgname,c.relname,t.tgenabled,pg_get_triggerdef(t.oid) definition,p.proname
from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_proc p on p.oid=t.tgfoid
where not t.tgisinternal and t.tgrelid in (to_regclass('public.orders'),to_regclass('public.equipment'),to_regclass('public.equipment_expenses'),to_regclass('public.equipment_order_links')) order by c.relname,t.tgname;
select n.nspname,p.proname,pg_get_functiondef(p.oid) definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('crm_equipment_check_expense','crm_equipment_check_order_budget','crm_equipment_check_meter_kind');
-- Aggregates only: no client names, UUIDs, addresses or row values are returned.
select
 (select count(*) from public.equipment_order_links l left join public.orders o on o.id=l.order_id left join public.equipment e on e.id=l.equipment_id where o.id is null or e.id is null or l.user_id is distinct from o.user_id or l.user_id is distinct from e.user_id) invalid_owner_links,
 (select count(*) from (select order_id,equipment_id from public.equipment_order_links group by order_id,equipment_id having count(*)>1) d) duplicate_pairs,
 (select count(*) from public.orders o join (select order_id,sum(amount) allocated from public.equipment_expenses where accounting_mode='in_order' group by order_id) x on x.order_id=o.id where coalesce(o.expenses,0)<x.allocated) over_budget_orders,
 (select count(*) from public.equipment_expenses x left join public.equipment e on e.id=x.equipment_id where x.amount is null or x.amount<0 or x.accounting_mode is null or x.accounting_mode not in ('additional','in_order') or e.id is null or x.user_id is distinct from e.user_id) invalid_expenses;
rollback;
