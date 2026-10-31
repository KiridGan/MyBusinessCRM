-- Additive extension of 20261028_equipment.sql. Run once, in this order.
-- No existing orders data/columns/policies are rewritten.
begin;
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
  if tg_table_schema='public' and tg_table_name='order_contractors' then
   -- Generated columns are unavailable in BEFORE triggers. This is exactly
   -- the same positive-decimal expression as the generated amount below.
   new_amount:=case when new.pricing_mode='hourly' then round(new.hours*new.hourly_rate,2) else new.fixed_amount end;
  else
   new_amount:=new.amount;
  end if;
 end if;
 -- Lock both source/destination orders in UUID order when moving an expense.
 -- Header UPDATE holds the same parent row before it upserts the same ledger.
 for oid in select distinct v from unnest(array[old_order,new_order]) as t(v) where v is not null order by v loop
  expected_owner:=case when oid=new_order then new.user_id else old.user_id end;
  select user_id,coalesce(expenses,0) into actual_owner,actual_budget
   from public.orders where id=oid for update;
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
create trigger order_contractors_budget before insert or update or delete on public.order_contractors for each row execute function public.crm_equipment_check_expense();
revoke all on function public.crm_equipment_check_expense() from public,anon,authenticated;
commit;
