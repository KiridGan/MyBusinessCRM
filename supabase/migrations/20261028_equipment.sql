-- Additive migration: no orders columns/data/policies are removed or rewritten.
-- Run once in Supabase SQL Editor as project owner. Entire script is atomic.
begin;
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
-- One machine per order. Existing orders.equipment (free text) is preserved.
create table public.equipment_order_links (
 order_id uuid primary key,
 user_id uuid not null default auth.uid() references auth.users(id),
 equipment_id uuid not null,
 created_at timestamptz not null default now(),
 foreign key(order_id,user_id) references public.orders(id,user_id) on delete restrict,
 foreign key(equipment_id,user_id) references public.equipment(id,user_id) on delete restrict,
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
revoke all on public.equipment,public.equipment_expenses,public.equipment_order_links from anon;
grant select,insert,update,delete on public.equipment,public.equipment_expenses,public.equipment_order_links to authenticated;

-- In-order journal rows are details of the existing orders.expenses, never extra costs.
create function public.crm_equipment_check_expense() returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
declare budget numeric; allocated numeric;
begin
 if new.accounting_mode='in_order' then
  select expenses into budget from public.orders where id=new.order_id and user_id=new.user_id for update;
  if not found then raise exception 'Order is unavailable' using errcode='42501'; end if;
  select coalesce(sum(amount),0) into allocated from public.equipment_expenses where order_id=new.order_id and id<>new.id and accounting_mode='in_order';
  if allocated+new.amount>coalesce(budget,0) then
   raise exception 'Journal details exceed orders.expenses' using errcode='23514';
  end if;
 end if;
 return new;
end $$;
create trigger equipment_expenses_budget before insert or update on public.equipment_expenses for each row execute function public.crm_equipment_check_expense();
create function public.crm_equipment_check_order_budget() returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if coalesce(new.expenses,0)<(select coalesce(sum(amount),0) from public.equipment_expenses where order_id=new.id and accounting_mode='in_order') then
  raise exception 'Expenses cannot be lower than linked journal details' using errcode='23514';
 end if;
 return new;
end $$;
create trigger equipment_order_budget before update of expenses on public.orders for each row execute function public.crm_equipment_check_order_budget();
-- Prevent interpreting old hour readings as kilometres (or vice versa).
create function public.crm_equipment_check_meter_kind() returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
 if new.meter_kind<>old.meter_kind and exists(select 1 from public.equipment_expenses where equipment_id=old.id) then
  raise exception 'Meter unit cannot change with existing history' using errcode='23514';
 end if;
 return new;
end $$;
create trigger equipment_meter_kind before update of meter_kind on public.equipment for each row execute function public.crm_equipment_check_meter_kind();
revoke all on function public.crm_equipment_check_meter_kind() from public;
revoke all on function public.crm_equipment_check_expense(),public.crm_equipment_check_order_budget() from public;
commit;
