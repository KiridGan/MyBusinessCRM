-- TARGETED BRIDGE for existing equipment/expenses/links WITHOUT private ledger
-- and WITHOUT order_contractors. Replaces neither orders nor existing rows.
-- Run this single script INSTEAD OF replaying 20261028 + 20261031.
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

-- This bridge refuses already upgraded/unknown installations. No IF NOT EXISTS
-- is used to hide incompatible financial objects.
do $shape$
declare t text; c record; expected text; pk record; id_att smallint;
begin
 if to_regclass('crm_equipment_private.order_budgets') is not null or to_regclass('public.order_budgets') is not null or to_regnamespace('crm_equipment_private') is not null or to_regclass('public.order_contractors') is not null then
  raise exception 'Ledger/schema or contractors already exist. STOP: compare installed versions; do not replay this bridge' using errcode='55000';
 end if;
 foreach t in array array['equipment','equipment_expenses','equipment_order_links'] loop
  if not exists(select 1 from pg_class where oid=to_regclass('public.'||t) and relkind='r' and relrowsecurity) then
   raise exception 'Missing ordinary RLS-enabled table: %',t using errcode='55000';
  end if;
 end loop;
 for c in select * from (values
 ('equipment','id','uuid'),('equipment','user_id','uuid'),('equipment','status','text'),
 ('equipment_expenses','id','uuid'),('equipment_expenses','user_id','uuid'),('equipment_expenses','equipment_id','uuid'),('equipment_expenses','order_id','uuid'),('equipment_expenses','amount','numeric'),
 ('equipment_order_links','order_id','uuid'),('equipment_order_links','equipment_id','uuid'),('equipment_order_links','user_id','uuid')
 ) x(tbl,col,typ) loop
  if not exists(select 1 from pg_attribute where attrelid=to_regclass('public.'||c.tbl) and attname=c.col and atttypid=to_regtype(c.typ) and not attisdropped) then
   raise exception 'Unsupported type/missing %.%; no automatic conversions',c.tbl,c.col using errcode='42804';
  end if;
 end loop;
 foreach t in array array['equipment','equipment_expenses'] loop
  select attnum into id_att from pg_attribute where attrelid=to_regclass('public.'||t) and attname='id' and not attisdropped;
  if not exists(select 1 from pg_index where indrelid=to_regclass('public.'||t) and indisunique and indisvalid and indimmediate and indnkeyatts=1 and indkey[0]=id_att and indpred is null and indexprs is null) then
   raise exception 'Missing unique id on %; separate schema review required',t using errcode='55000';
  end if;
 end loop;
 if exists(select 1 from information_schema.columns where table_schema='public' and ((table_name='equipment' and column_name in ('brand','registration_number','purchase_cost','hourly_rate')) or (table_name='equipment_order_links' and column_name in ('work_hours','hourly_rate')))) then
  raise exception 'PR3 columns already partly installed: separate version review required' using errcode='55000';
 end if;
 -- Only the old single-order PK and the audited composite PK are supported.
 select co.oid,co.conname,co.conindid,array(select a.attname::text from unnest(co.conkey) with ordinality k(n,pos) join pg_attribute a on a.attrelid=co.conrelid and a.attnum=k.n order by k.pos) cols
 into pk from pg_constraint co where co.conrelid='public.equipment_order_links'::regclass and co.contype='p';
 if not found or pk.cols not in (array['order_id'],array['order_id','equipment_id']) then
  raise exception 'Unsupported equipment_order_links primary key' using errcode='55000';
 end if;
 if pk.cols=array['order_id'] and exists(select 1 from pg_constraint where contype='f' and confrelid='public.equipment_order_links'::regclass and conindid=pk.conindid) then
  raise exception 'An FK depends on the old single-order PK; do not drop it automatically' using errcode='55000';
 end if;
 if exists(select 1 from pg_constraint where contype='f' and conrelid in ('public.equipment_expenses'::regclass,'public.equipment_order_links'::regclass) and confdeltype not in ('a','r')) then
  raise exception 'Unexpected cascading/set-null history FK; separate review required' using errcode='55000';
 end if;
 -- Do not replace unrelated trigger implementations with matching names.
 for c in select cl.relname,tg.tgname,p.proname,n.nspname from pg_trigger tg join pg_class cl on cl.oid=tg.tgrelid join pg_proc p on p.oid=tg.tgfoid join pg_namespace n on n.oid=p.pronamespace
  where not tg.tgisinternal and tg.tgrelid in ('public.orders'::regclass,'public.equipment'::regclass,'public.equipment_expenses'::regclass,'public.equipment_order_links'::regclass) loop
  expected:=case c.tgname when 'equipment_expenses_budget' then 'crm_equipment_check_expense' when 'equipment_order_budget' then 'crm_equipment_check_order_budget' when 'equipment_meter_kind' then 'crm_equipment_check_meter_kind' else null end;
  if (expected is not null and (c.nspname<>'public' or c.proname<>expected)) or (expected is null and c.relname<>'orders') then
   raise exception 'Unknown trigger %.% must be reviewed first',c.relname,c.tgname using errcode='55000';
  end if;
 end loop;
end $shape$;
lock table public.orders,public.equipment,public.equipment_expenses,public.equipment_order_links in share row exclusive mode;
-- Recognise only common owner-only policies. Unknown policy logic is NOT
-- overwritten or assumed safe. All existing policies remain unchanged.
do $policies$
declare t text; p record; q text; w text; command "char";
begin
 foreach t in array array['orders','equipment','equipment_expenses','equipment_order_links'] loop
  if has_table_privilege('authenticated','public.'||t,'TRUNCATE') or has_table_privilege('anon','public.'||t,'TRUNCATE') then
   raise exception 'Client TRUNCATE privilege on % requires separate permission review',t using errcode='55000';
  end if;
  for p in select * from pg_policy where polrelid=to_regclass('public.'||t) loop
   q:=lower(regexp_replace(coalesce(pg_get_expr(p.polqual,p.polrelid),''),'[[:space:]()]','','g'));
   w:=lower(regexp_replace(coalesce(pg_get_expr(coalesce(p.polwithcheck,p.polqual),p.polrelid),''),'[[:space:]()]','','g'));
   if (p.polcmd in ('*','r','w','d') and q not in ('auth.uid=user_id','user_id=auth.uid','selectauth.uidasuid=user_id','user_id=selectauth.uidasuid','selectauth.uid=user_id','user_id=selectauth.uid'))
   or (p.polcmd in ('*','a','w') and w not in ('auth.uid=user_id','user_id=auth.uid','selectauth.uidasuid=user_id','user_id=selectauth.uidasuid','selectauth.uid=user_id','user_id=selectauth.uid')) then
    raise exception 'Unrecognised RLS policy %.%; review without automatic replacement',t,p.polname using errcode='55000';
   end if;
  end loop;
  foreach command in array array['r','a','w','d']::"char"[] loop
   if not exists(select 1 from pg_policy where polrelid=to_regclass('public.'||t) and polpermissive and polcmd in ('*',command) and (0=any(polroles) or (select oid from pg_roles where rolname='authenticated')=any(polroles))) then
    raise exception 'Missing authenticated owner policy for % command %',t,command using errcode='55000';
   end if;
  end loop;
 end loop;
end $policies$;
do $data$
begin
 if exists(select 1 from public.equipment e left join auth.users u on u.id=e.user_id where e.id is null or u.id is null)
 or exists(select 1 from public.equipment_order_links l left join public.orders o on o.id=l.order_id left join public.equipment e on e.id=l.equipment_id where l.user_id is null or o.id is null or e.id is null or l.user_id is distinct from o.user_id or l.user_id is distinct from e.user_id)
 or exists(select 1 from public.equipment_expenses x left join public.equipment e on e.id=x.equipment_id left join public.orders o on o.id=x.order_id left join public.equipment_order_links l on l.order_id=x.order_id and l.equipment_id=x.equipment_id and l.user_id=x.user_id where x.id is null or x.expense_date is null or x.user_id is null or e.id is null or x.user_id is distinct from e.user_id or x.amount is null or x.amount<0 or x.amount::text in ('NaN','Infinity','-Infinity') or x.accounting_mode not in ('additional','in_order') or x.accounting_mode is null or (x.accounting_mode='additional' and x.order_id is not null) or (x.accounting_mode='in_order' and (o.id is null or l.order_id is null or x.user_id is distinct from o.user_id))) then
  raise exception 'Owner/orphan/amount/accounting source validation failed; no rows are repaired or removed' using errcode='23514';
 end if;
 if exists(select 1 from public.equipment_order_links group by order_id,equipment_id having count(*)>1) then
  raise exception 'Duplicate machine/order pairs; manual review required' using errcode='23514';
 end if;
 if exists(select 1 from public.orders o where exists(select 1 from public.equipment_order_links l where l.order_id=o.id) and (coalesce(o.expenses,0)<0 or o.expenses::text in ('NaN','Infinity','-Infinity'))) then
  raise exception 'Referenced orders have invalid budgets; no automatic changes' using errcode='23514';
 end if;
 if exists(select 1 from public.orders o join (select order_id,sum(amount) allocated from public.equipment_expenses where accounting_mode='in_order' group by order_id) x on x.order_id=o.id where coalesce(o.expenses,0)<x.allocated or o.expenses::text in ('NaN','Infinity','-Infinity')) then
  raise exception 'Existing in_order details exceed orders.expenses; nothing is increased, reduced or deleted automatically' using errcode='23514';
 end if;
end $data$;
-- Add owner keys only when an equivalent immediate unique index is absent.
do $keys$
declare t text; names text[]; a smallint; b smallint; c smallint; pk record;
begin
 foreach t in array array['orders','equipment'] loop
  select attnum into a from pg_attribute where attrelid=to_regclass('public.'||t) and attname='id';
  select attnum into b from pg_attribute where attrelid=to_regclass('public.'||t) and attname='user_id';
  if not exists(select 1 from pg_index where indrelid=to_regclass('public.'||t) and indisunique and indisvalid and indimmediate and indpred is null and indexprs is null and indnkeyatts=2 and indkey[0]=a and indkey[1]=b) then
   execute format('create unique index %I on public.%I(id,user_id)','crm_bridge_'||t||'_owner_idx',t);
  end if;
 end loop;
 select co.conname,array(select attname::text from unnest(co.conkey) with ordinality k(n,pos) join pg_attribute at on at.attrelid=co.conrelid and at.attnum=k.n order by k.pos) cols into pk from pg_constraint co where co.conrelid='public.equipment_order_links'::regclass and contype='p';
 if pk.cols=array['order_id'] then
  execute format('alter table public.equipment_order_links drop constraint %I',pk.conname);
  alter table public.equipment_order_links add primary key(order_id,equipment_id);
 end if;
 select attnum into a from pg_attribute where attrelid='public.equipment_order_links'::regclass and attname='order_id';
 select attnum into b from pg_attribute where attrelid='public.equipment_order_links'::regclass and attname='equipment_id';
 select attnum into c from pg_attribute where attrelid='public.equipment_order_links'::regclass and attname='user_id';
 if not exists(select 1 from pg_index where indrelid='public.equipment_order_links'::regclass and indisunique and indisvalid and indimmediate and indpred is null and indexprs is null and indnkeyatts=3 and indkey[0]=a and indkey[1]=b and indkey[2]=c) then
  create unique index crm_bridge_links_owner_idx on public.equipment_order_links(order_id,equipment_id,user_id);
 end if;
end $keys$;
-- These additive FKs validate all existing rows without changing any values.
alter table public.equipment_order_links add constraint crm_bridge_link_order_owner foreign key(order_id,user_id) references public.orders(id,user_id) on delete restrict;
alter table public.equipment_order_links add constraint crm_bridge_link_machine_owner foreign key(equipment_id,user_id) references public.equipment(id,user_id) on delete restrict;
alter table public.equipment_expenses add constraint crm_bridge_expense_machine_owner foreign key(equipment_id,user_id) references public.equipment(id,user_id) on delete restrict;
alter table public.equipment_expenses add constraint crm_bridge_expense_order_machine_owner foreign key(order_id,equipment_id,user_id) references public.equipment_order_links(order_id,equipment_id,user_id) on delete restrict;

create schema crm_equipment_private;
revoke all on schema crm_equipment_private from public,anon,authenticated;
create table crm_equipment_private.order_budgets (
 order_id uuid primary key,
 user_id uuid not null,
 budget numeric not null check(budget>=0),
 allocated numeric not null default 0 check(allocated>=0 and allocated<=budget),
 foreign key(order_id,user_id) references public.orders(id,user_id) on delete cascade
);
alter table crm_equipment_private.order_budgets enable row level security;
revoke all on crm_equipment_private.order_budgets from public,anon,authenticated;


-- Seed only new bookkeeping rows. Existing orders/journal/links are untouched.
insert into crm_equipment_private.order_budgets(order_id,user_id,budget,allocated)
select o.id,o.user_id,coalesce(o.expenses,0),coalesce(x.allocated,0)
from public.orders o
join (select order_id from public.equipment_order_links union select order_id from public.equipment_expenses where accounting_mode='in_order') r on r.order_id=o.id
left join (select order_id,sum(amount) allocated from public.equipment_expenses where accounting_mode='in_order' group by order_id) x on x.order_id=o.id;
-- Prevent interpreting old hour readings as kilometres (or vice versa).
create or replace function public.crm_equipment_check_meter_kind() returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if new.meter_kind<>old.meter_kind and exists(select 1 from public.equipment_expenses where equipment_id=old.id) then
  raise exception 'Meter unit cannot change with existing history' using errcode='23514';
 end if;
 return new;
end $$;
drop trigger if exists equipment_meter_kind on public.equipment;
create trigger equipment_meter_kind before update of meter_kind on public.equipment for each row execute function public.crm_equipment_check_meter_kind();
revoke all on function public.crm_equipment_check_meter_kind() from public,anon,authenticated;

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
drop trigger if exists equipment_expenses_budget on public.equipment_expenses;
create trigger equipment_expenses_budget after insert or update or delete on public.equipment_expenses for each row execute function public.crm_equipment_check_expense();
drop trigger if exists equipment_order_budget on public.orders;
create trigger equipment_order_budget after update on public.orders for each row when (old.expenses is distinct from new.expenses) execute function public.crm_equipment_check_order_budget();
create trigger order_contractors_budget after insert or update or delete on public.order_contractors for each row execute function public.crm_equipment_check_expense();
revoke all on function public.crm_equipment_check_expense(),public.crm_equipment_check_order_budget() from public,anon,authenticated;
commit;
