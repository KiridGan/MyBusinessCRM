-- Additive migration: no orders columns/data/policies are removed or rewritten.
-- Run once in Supabase SQL Editor as project owner. Entire script is atomic.
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
create unique index orders_equipment_owner_uidx on public.orders(id,user_id);
create table public.equipment (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id),
 created_at timestamptz not null default now(),
 name text not null check(length(btrim(name)) between 1 and 200),
 model text not null default '',
 manufacture_year integer check(manufacture_year between 1900 and 2200),
 equipment_type text not null default '',
 inventory_number text not null default '',
 meter_kind text not null default 'hours' check(meter_kind in ('hours','km')),
 meter_value numeric(14,2) not null default 0 check(meter_value>=0),
 status text not null default 'Свободна' check(status in ('Свободна','В работе','На ТО','В ремонте')),
 notes text not null default '',
 next_service_date date,
 next_service_meter numeric(14,2) check(next_service_meter>=0),
 archived_at timestamptz,
 unique(id,user_id)
);
create unique index equipment_inventory_uidx on public.equipment(user_id,lower(btrim(inventory_number))) where btrim(inventory_number)<>'';
-- Many machines per order. Existing orders.equipment (free text) is preserved.
create table public.equipment_order_links (
 order_id uuid not null,
 user_id uuid not null default auth.uid() references auth.users(id),
 equipment_id uuid not null,
 created_at timestamptz not null default now(),
 foreign key(order_id,user_id) references public.orders(id,user_id) on delete restrict,
 foreign key(equipment_id,user_id) references public.equipment(id,user_id) on delete restrict,
 primary key(order_id,equipment_id),
 unique(order_id,equipment_id,user_id)
);
create table public.equipment_expenses (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id),
 equipment_id uuid not null,
 created_at timestamptz not null default now(),
 expense_date date not null,
 category text not null check(category in ('ТО','Ремонт','Заправка','Прочее')),
 amount numeric(14,2) not null check(amount>=0),
 meter_value numeric(14,2) check(meter_value>=0),
 description text not null default '',
 accounting_mode text not null default 'additional' check(accounting_mode in ('additional','in_order')),
 order_id uuid,
 check((accounting_mode='additional' and order_id is null) or (accounting_mode='in_order' and order_id is not null)),
 foreign key(equipment_id,user_id) references public.equipment(id,user_id) on delete restrict,
 foreign key(order_id,equipment_id,user_id) references public.equipment_order_links(order_id,equipment_id,user_id) on delete restrict
);
create index equipment_owner_idx on public.equipment(user_id);
create index equipment_expenses_owner_date_idx on public.equipment_expenses(user_id,equipment_id,expense_date);
create index equipment_links_owner_idx on public.equipment_order_links(user_id,equipment_id);

alter table public.equipment enable row level security;
alter table public.equipment_expenses enable row level security;
alter table public.equipment_order_links enable row level security;
-- Both USING and WITH CHECK prevent changing ownership on update.
create policy equipment_owner on public.equipment for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
create policy equipment_expenses_owner on public.equipment_expenses for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
create policy equipment_links_owner on public.equipment_order_links for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
revoke all on public.equipment,public.equipment_expenses,public.equipment_order_links from public,anon,authenticated;
grant select,insert,update,delete on public.equipment,public.equipment_expenses,public.equipment_order_links to authenticated;

-- A private, write-serialized budget ledger. Never expose it through PostgREST.
-- No existing orders or policies are updated; rows are created lazily by triggers.
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

-- SECURITY DEFINER is limited to trigger entry points, fixed object names and a
-- trusted search_path. No RPC/arguments can write the private ledger. The outer
-- statements still use the unchanged RLS policies, and cross-owner FKs remain.
create function public.crm_equipment_check_expense() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
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
  new_order:=new.order_id; new_amount:=new.amount;
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
create trigger equipment_expenses_budget after insert or update or delete on public.equipment_expenses for each row execute function public.crm_equipment_check_expense();
create function public.crm_equipment_check_order_budget() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
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
create trigger equipment_order_budget after update on public.orders for each row when (old.expenses is distinct from new.expenses) execute function public.crm_equipment_check_order_budget();
-- Prevent interpreting old hour readings as kilometres (or vice versa).
create function public.crm_equipment_check_meter_kind() returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if new.meter_kind<>old.meter_kind and exists(select 1 from public.equipment_expenses where equipment_id=old.id) then
  raise exception 'Meter unit cannot change with existing history' using errcode='23514';
 end if;
 return new;
end $$;
create trigger equipment_meter_kind before update of meter_kind on public.equipment for each row execute function public.crm_equipment_check_meter_kind();
revoke all on function public.crm_equipment_check_meter_kind() from public,anon,authenticated;
revoke all on function public.crm_equipment_check_expense(),public.crm_equipment_check_order_budget() from public,anon,authenticated;
commit;
