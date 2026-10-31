-- Reconstructed TEST contract from CRM mappings and the user's field list.
-- NOT a schema-only export of the production Supabase database.
-- Only id/user_id UUID were explicitly confirmed by the user. Nullability,
-- defaults, policy names and other types must be compared with real DDL later.
create table public.orders (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id),
 created_at timestamptz not null default now(),
 client_name text, phone text, order_date date, address text,
 work_type text, equipment text, amount numeric, expenses numeric,
 status text, comment text
);
alter table public.orders enable row level security;
create policy orders_test_select on public.orders for select to authenticated using(auth.uid()=user_id);
create policy orders_test_insert on public.orders for insert to authenticated with check(auth.uid()=user_id);
create policy orders_test_update on public.orders for update to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
create policy orders_test_delete on public.orders for delete to authenticated using(auth.uid()=user_id);
-- Give anon ordinary SQL privileges to prove that RLS, not just missing grants,
-- prevents cross-account access. Never grant TRUNCATE to a client role.
grant select,insert,update,delete on public.orders to authenticated,anon;
