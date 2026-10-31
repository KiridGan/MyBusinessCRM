-- Additive extension of 20261028_equipment.sql. Run once, in this order.
-- No existing orders data/columns/policies are rewritten.
begin;
set local lock_timeout='5s';
set local statement_timeout='120s';
-- Inspect metadata only; never change orders or its policies automatically.
do $preflight$
declare id_att smallint;
begin
 if to_regclass('public.orders') is null then
  raise exception 'Missing public.orders; compare the schema-only export before migrating' using errcode='42P01';
 end if;
 if not exists(select 1 from pg_class where oid='public.orders'::regclass and relkind='r' and relrowsecurity) then
  raise exception 'orders must be an ordinary table with RLS enabled; no automatic policy changes are made' using errcode='55000';
 end if;
 if not exists(select 1 from pg_attribute where attrelid='public.orders'::regclass and attname='id' and atttypid='uuid'::regtype and not attisdropped)
 or not exists(select 1 from pg_attribute where attrelid='public.orders'::regclass and attname='user_id' and atttypid='uuid'::regtype and not attisdropped)
 or not exists(select 1 from pg_attribute where attrelid='public.orders'::regclass and attname='expenses' and atttypid='numeric'::regtype and attgenerated='' and not attisdropped) then
  raise exception 'orders requires id/user_id uuid and writable numeric expenses; do not auto-convert existing data' using errcode='42804';
 end if;
 select attnum into id_att from pg_attribute where attrelid='public.orders'::regclass and attname='id' and not attisdropped;
 if not exists(select 1 from pg_index where indrelid='public.orders'::regclass and indisunique and indisvalid and indimmediate and indnkeyatts=1 and indkey[0]=id_att and indpred is null and indexprs is null) then
  raise exception 'orders.id must have a non-deferrable unique key' using errcode='55000';
 end if;
 if exists(select 1 from pg_roles where rolname in ('anon','authenticated') and (rolsuper or rolbypassrls)) then
  raise exception 'Client roles must not be SUPERUSER or BYPASSRLS; review authorization separately' using errcode='55000';
 end if;
 if to_regprocedure('auth.uid()') is null then
  raise exception 'Missing Supabase auth.uid(); stop rather than replacing authentication' using errcode='42883';
 end if;
end $preflight$;
do $base_shape$
begin
 if to_regclass('public.order_contractors') is not null then
  raise exception 'order_contractors already exists: do not rerun this migration; compare installed versions first' using errcode='55000';
 end if;
 if not exists(select 1 from pg_constraint where conrelid=to_regclass('public.equipment_order_links') and contype='p' and conkey=array[
  (select attnum from pg_attribute where attrelid=to_regclass('public.equipment_order_links') and attname='order_id' and not attisdropped),
  (select attnum from pg_attribute where attrelid=to_regclass('public.equipment_order_links') and attname='equipment_id' and not attisdropped)
 ]::smallint[]) then
  raise exception 'Unsupported base equipment_order_links: expected composite primary key; a separate upgrade is required' using errcode='55000';
 end if;
end $base_shape$;
-- Freeze budget writers while checking a previously installed base. Stop on
-- mismatch instead of rewriting existing journal, orders or financial totals.
lock table public.orders,public.equipment_expenses,crm_equipment_private.order_budgets in share row exclusive mode;
do $ledger_check$
begin
 if exists(
  select 1 from public.orders o
  left join crm_equipment_private.order_budgets b on b.order_id=o.id
  left join (select order_id,sum(amount) actual from public.equipment_expenses where accounting_mode='in_order' group by order_id) d on d.order_id=o.id
  where coalesce(b.allocated,0)<>coalesce(d.actual,0)
   or (b.order_id is not null and (b.user_id is distinct from o.user_id or b.budget<>coalesce(o.expenses,0)))
 ) then
  raise exception 'Existing budget ledger differs from orders/journal. STOP: review separately; no automatic repair is allowed' using errcode='23514';
 end if;
end $ledger_check$;
alter table public.equipment
 add column brand text not null default '',
 add column registration_number text not null default '',
 add column purchase_cost numeric(14,2) not null default 0 check(purchase_cost>=0),
 add column hourly_rate numeric(14,2) not null default 0 check(hourly_rate>=0);
alter table public.equipment drop constraint equipment_status_check;
alter table public.equipment add constraint equipment_status_check check(status in ('Свободна','В работе','На ТО','В ремонте','Неактивна'));
-- History is retained through archive, not physical deletion by an API user.
revoke delete on public.equipment from authenticated;
alter table public.equipment_order_links
 add column work_hours numeric(10,2) not null default 0 check(work_hours>=0),
 add column hourly_rate numeric(14,2) not null default 0 check(hourly_rate>=0);

create table public.order_contractors (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id),
 order_id uuid not null,
 created_at timestamptz not null default now(),
 equipment_type text not null default '',
 equipment_name text not null check(length(btrim(equipment_name)) between 1 and 200),
 contractor_name text not null check(length(btrim(contractor_name)) between 1 and 200),
 phone text not null default '',
 pricing_mode text not null default 'hourly' check(pricing_mode in ('hourly','fixed')),
 hours numeric(10,2) not null default 0 check(hours>=0),
 hourly_rate numeric(14,2) not null default 0 check(hourly_rate>=0),
 fixed_amount numeric(14,2) not null default 0 check(fixed_amount>=0),
 amount numeric(14,2) generated always as (case when pricing_mode='hourly' then round(hours*hourly_rate,2) else fixed_amount end) stored,
 accounting_mode text not null default 'additional' check(accounting_mode in ('additional','in_order')),
 comment text not null default '',
 foreign key(order_id,user_id) references public.orders(id,user_id) on delete restrict
);
create index order_contractors_owner_idx on public.order_contractors(user_id,order_id,id);
alter table public.order_contractors enable row level security;
create policy order_contractors_owner on public.order_contractors for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
revoke all on public.order_contractors from public,anon,authenticated;
grant select,insert,update,delete on public.order_contractors to authenticated;

-- Retain the same protected counter and lock order for both kinds of detail.
-- Existing ledger allocations are unchanged, and the new table starts empty.
create or replace function public.crm_equipment_check_expense() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare
 old_order uuid; new_order uuid; old_amount numeric:=0; new_amount numeric:=0;
 oid uuid; expected_owner uuid; actual_owner uuid; actual_budget numeric;
begin
 if current_setting('role',true) not in ('none','postgres','supabase_admin','service_role')
  and auth.uid() is distinct from (case when tg_op='DELETE' then old.user_id else new.user_id end) then
  raise exception 'Expense owner is unavailable' using errcode='42501';
 end if;
 if tg_op='UPDATE' and new.user_id is distinct from old.user_id then
  raise exception 'Expense owner is immutable' using errcode='42501';
 end if;
 if tg_op<>'INSERT' and old.accounting_mode='in_order' then
  old_order:=old.order_id; old_amount:=old.amount;
 end if;
 if tg_op<>'DELETE' and new.accounting_mode='in_order' then
  new_order:=new.order_id;
  -- AFTER triggers see the actual generated amount and fire only for rows
  -- that were inserted/updated (not conflict-skipped candidates).
  new_amount:=new.amount;
 end if;
 -- Lock both source/destination orders in UUID order when moving an expense.
 -- Header UPDATE holds the same parent row before it upserts the same ledger.
 for oid in select distinct v from unnest(array[old_order,new_order]) as t(v) where v is not null order by v loop
  expected_owner:=case when oid=new_order then new.user_id else old.user_id end;
  select user_id,coalesce(expenses,0) into actual_owner,actual_budget
   from public.orders where id=oid for no key update;
  if not found or actual_owner is distinct from expected_owner then
   raise exception 'Order is unavailable' using errcode='42501';
  end if;
  -- UPSERT, not SUM(snapshot), is the serialization point. At READ COMMITTED
  -- it uses the latest locked version; at RR/SERIALIZABLE a stale writer fails
  -- with 40001 instead of validating against an old snapshot or missing row.
  insert into crm_equipment_private.order_budgets as b(order_id,user_id,budget,allocated)
   values(oid,actual_owner,actual_budget,case when oid=new_order then new_amount else 0 end)
   on conflict(order_id) do update set
    budget=excluded.budget,
    allocated=b.allocated
     +case when oid=new_order then new_amount else 0 end
     -case when oid=old_order then old_amount else 0 end;
 end loop;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create or replace function public.crm_equipment_check_order_budget() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare final_owner uuid; final_budget numeric;
begin
 if current_setting('role',true) not in ('none','postgres','supabase_admin','service_role') and auth.uid() is distinct from new.user_id then
  raise exception 'Order owner is unavailable' using errcode='42501';
 end if;
 -- Read the stored value after all BEFORE triggers and any earlier nested
 -- AFTER updates, not an obsolete NEW value from an outer trigger event.
 select user_id,coalesce(expenses,0) into final_owner,final_budget
  from public.orders where id=new.id for no key update;
 if not found then return new; end if;
 insert into crm_equipment_private.order_budgets as b(order_id,user_id,budget,allocated)
  values(new.id,final_owner,final_budget,0)
  on conflict(order_id) do update set budget=excluded.budget;
 return new;
end $$;
-- Upgrade the base trigger timing too; do not change any stored amounts.
drop trigger equipment_expenses_budget on public.equipment_expenses;
create trigger equipment_expenses_budget after insert or update or delete on public.equipment_expenses for each row execute function public.crm_equipment_check_expense();
drop trigger equipment_order_budget on public.orders;
create trigger equipment_order_budget after update on public.orders for each row when (old.expenses is distinct from new.expenses) execute function public.crm_equipment_check_order_budget();
create trigger order_contractors_budget after insert or update or delete on public.order_contractors for each row execute function public.crm_equipment_check_expense();
revoke all on function public.crm_equipment_check_expense(),public.crm_equipment_check_order_budget() from public,anon,authenticated;
commit;
