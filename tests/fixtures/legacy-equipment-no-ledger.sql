-- Synthetic column-compatible legacy schema. NOT an export of production.
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

