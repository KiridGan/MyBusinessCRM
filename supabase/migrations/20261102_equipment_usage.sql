-- Existing PR3-compatible production schema only. No historic work is charged.
-- This script never UPDATEs orders/equipment/financial rows. Run once when approved.
begin;
set local lock_timeout='5s';
set local statement_timeout='120s';
do $check$
declare r record;
begin
 if to_regclass('public.equipment_meter_accounts') is not null or to_regnamespace('crm_meter_private') is not null then raise exception 'Meter feature already/partly installed; inspect version, do not replay' using errcode='55000'; end if;
 for r in select * from (values ('orders','id','uuid'),('orders','user_id','uuid'),('orders','status','text'),('equipment','id','uuid'),('equipment','user_id','uuid'),('equipment','meter_value','numeric'),('equipment','meter_kind','text'),('equipment_order_links','order_id','uuid'),('equipment_order_links','equipment_id','uuid'),('equipment_order_links','user_id','uuid'),('equipment_order_links','work_hours','numeric')) x(t,c,typ) loop
  if not exists(select 1 from pg_attribute where attrelid=to_regclass('public.'||r.t) and attname=r.c and atttypid=to_regtype(r.typ) and not attisdropped) then raise exception 'Unsupported/missing %.% (% required). Complete schema review first',r.t,r.c,r.typ using errcode='42804'; end if;
 end loop;
 if to_regclass('public.order_contractors') is null then raise exception 'Complete PR3 schema first; do not guess installed migrations' using errcode='55000'; end if;
 if exists(select 1 from pg_class where oid in ('public.orders'::regclass,'public.equipment'::regclass,'public.equipment_order_links'::regclass) and not relrowsecurity) then raise exception 'Existing owner RLS must be enabled' using errcode='55000'; end if;
 if exists(select 1 from pg_roles where rolname in ('anon','authenticated') and (rolsuper or rolbypassrls)) then raise exception 'Unsafe client role' using errcode='55000'; end if;
 if exists(select 1 from public.equipment where meter_value is null or meter_value<0 or meter_value::text in ('NaN','Infinity','-Infinity') or meter_kind is null or meter_kind not in ('hours','km')) then raise exception 'Invalid legacy meter data; review without automatic repair' using errcode='23514';end if;
 if exists(select 1 from public.equipment_order_links l left join public.orders o on o.id=l.order_id left join public.equipment e on e.id=l.equipment_id where l.user_id is null or o.id is null or e.id is null or l.user_id is distinct from o.user_id or l.user_id is distinct from e.user_id or l.work_hours is null or l.work_hours<0 or l.work_hours::text in ('NaN','Infinity','-Infinity')) then raise exception 'Invalid ownership/work hours in existing links; no automatic repair' using errcode='23514';end if;
 if not exists(select 1 from pg_constraint where conrelid='public.equipment_order_links'::regclass and contype='p' and array(select a.attname::text from unnest(conkey) with ordinality k(n,pos) join pg_attribute a on a.attrelid=conrelid and a.attnum=k.n order by k.pos)=array['order_id','equipment_id']) then raise exception 'Composite machine/order key required; finish previous upgrade first' using errcode='55000';end if;
 if exists(select 1 from information_schema.columns where table_schema='public' and ((table_name='equipment_order_links' and column_name='work_distance') or (table_name='equipment' and column_name='service_warning_threshold'))) then raise exception 'Conflicting meter columns: inspect definitions' using errcode='55000'; end if;
end $check$;
lock table public.orders,public.equipment,public.equipment_order_links in share row exclusive mode;
do $rls$
declare t text; p record; q text; w text;
begin
 foreach t in array array['orders','equipment','equipment_order_links'] loop
  for p in select * from pg_policy where polrelid=to_regclass('public.'||t) loop
   q:=lower(regexp_replace(coalesce(pg_get_expr(p.polqual,p.polrelid),''),'[[:space:]()]','','g'));
   w:=lower(regexp_replace(coalesce(pg_get_expr(coalesce(p.polwithcheck,p.polqual),p.polrelid),''),'[[:space:]()]','','g'));
   if (p.polcmd in ('*','r','w','d') and q not in ('auth.uid=user_id','user_id=auth.uid','selectauth.uidasuid=user_id','user_id=selectauth.uidasuid','selectauth.uid=user_id','user_id=selectauth.uid')) or (p.polcmd in ('*','a','w') and w not in ('auth.uid=user_id','user_id=auth.uid','selectauth.uidasuid=user_id','user_id=selectauth.uidasuid','selectauth.uid=user_id','user_id=selectauth.uid')) then
    raise exception 'Unrecognised existing policy %.%; review RPC authorization before migration',t,p.polname using errcode='55000';
   end if;
  end loop;
  if not exists(select 1 from pg_policy where polrelid=to_regclass('public.'||t) and polpermissive and polcmd in ('*','r') and (0=any(polroles) or (select oid from pg_roles where rolname='authenticated')=any(polroles))) then raise exception 'Missing authenticated owner SELECT policy on %',t using errcode='55000';end if;
 end loop;
 -- Confirmation RPC must not grant writes to an otherwise read-only owner.
 if not has_table_privilege('authenticated','public.equipment','UPDATE') or not exists(select 1 from pg_policy where polrelid='public.equipment'::regclass and polpermissive and polcmd in ('*','w') and (0=any(polroles) or (select oid from pg_roles where rolname='authenticated')=any(polroles))) then raise exception 'Authenticated owner UPDATE access on equipment required; review before enabling correction RPC' using errcode='55000';end if;
end $rls$;

alter table public.equipment add constraint crm_meter_legacy_finite check(meter_value>=0 and meter_value::text not in ('NaN','Infinity','-Infinity'));
alter table public.equipment_order_links add constraint crm_meter_hours_finite check(work_hours>=0 and work_hours::text not in ('NaN','Infinity','-Infinity'));
alter table public.equipment_order_links add column work_distance numeric(14,2) not null default 0 check(work_distance>=0 and work_distance::text not in ('NaN','Infinity','-Infinity'));
alter table public.equipment add column service_warning_threshold numeric(14,2) check(service_warning_threshold>=0 and service_warning_threshold::text not in ('NaN','Infinity','-Infinity'));
create schema crm_meter_private;
revoke all on schema crm_meter_private from public,anon,authenticated;
create table crm_meter_private.guards(equipment_id uuid primary key references public.equipment(id) on delete restrict,version bigint not null default 0);
alter table crm_meter_private.guards enable row level security;
revoke all on crm_meter_private.guards from public,anon,authenticated;
create table public.equipment_meter_accounts(
 equipment_id uuid primary key references public.equipment(id) on delete restrict,
 user_id uuid not null references auth.users(id),
 meter_kind text not null check(meter_kind in ('hours','km')),
 enabled boolean not null default false,
 base_value numeric(16,2) not null check(base_value>=0 and base_value::text not in ('NaN','Infinity','-Infinity')),
 base_sum numeric(18,2) not null default 0,
 version bigint not null default 1,
 activated_at timestamptz
);
create table public.equipment_meter_entries(
 order_id uuid not null, -- Tombstone survives order deletion; not a financial FK.
 equipment_id uuid not null references public.equipment_meter_accounts(equipment_id) on delete restrict,
 user_id uuid not null references auth.users(id),
 historical_excluded boolean not null default false,
 linked boolean not null default true,
 contribution numeric(16,2) not null default 0 check(contribution>=0 and contribution::text not in ('NaN','Infinity','-Infinity')),
 updated_at timestamptz not null default now(),
 primary key(order_id,equipment_id)
);
create table public.equipment_meter_events(
 id uuid primary key default gen_random_uuid(),
 sequence bigint generated always as identity unique,
 equipment_id uuid not null references public.equipment_meter_accounts(equipment_id) on delete restrict,
 user_id uuid not null references auth.users(id),
 actor_id uuid, actor_role text not null,
 created_at timestamptz not null default clock_timestamp(),
 event_type text not null check(event_type in ('activation','order','correction')),
 details jsonb not null default '{}'::jsonb,
 order_id uuid,
 previous_value numeric(16,2) not null,
 new_value numeric(16,2) not null,
 delta numeric(16,2) not null,
 reason text not null,
 request_id uuid,
 request_payload jsonb,
 unique(user_id,request_id)
);
create index equipment_meter_events_owner_idx on public.equipment_meter_events(user_id,equipment_id,sequence desc);
create index equipment_meter_entries_owner_idx on public.equipment_meter_entries(user_id,order_id);
alter table public.equipment_meter_accounts enable row level security;
alter table public.equipment_meter_entries enable row level security;
alter table public.equipment_meter_events enable row level security;
create policy meter_accounts_read on public.equipment_meter_accounts for select to authenticated using(auth.uid()=user_id);
create policy meter_entries_read on public.equipment_meter_entries for select to authenticated using(auth.uid()=user_id);
create policy meter_events_read on public.equipment_meter_events for select to authenticated using(auth.uid()=user_id);
revoke all on public.equipment_meter_accounts,public.equipment_meter_entries,public.equipment_meter_events from public,anon,authenticated;
grant select on public.equipment_meter_accounts,public.equipment_meter_entries,public.equipment_meter_events to authenticated;

-- Trigger helper is not an RPC. Parent order -> equipment -> durable guard.
-- Guard writes force stale RR/SERIALIZABLE writers to abort even before activation.
create function public.crm_meter_sync_pair(p_order uuid,p_machine uuid,p_owner uuid) returns void language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare e record; a record; entry record; units numeric:=0; before_value numeric; after_value numeric; old_units numeric:=0; is_linked boolean:=false; was_excluded boolean:=false; state text; owner uuid;
begin
 select user_id,status into owner,state from public.orders where id=p_order for no key update;
 if found and owner is distinct from p_owner then raise exception 'Wrong order owner' using errcode='42501'; end if;
 select * into e from public.equipment where id=p_machine and user_id=p_owner for no key update;
 if not found then raise exception 'Machine unavailable' using errcode='42501'; end if;
 insert into crm_meter_private.guards as g(equipment_id,version) values(p_machine,1) on conflict(equipment_id) do update set version=g.version+1;
 select * into a from public.equipment_meter_accounts where equipment_id=p_machine;
 if not found or not a.enabled then return; end if;
 select * into entry from public.equipment_meter_entries where order_id=p_order and equipment_id=p_machine;
 if found then old_units:=entry.contribution;was_excluded:=entry.historical_excluded;end if;
 select case when a.meter_kind='km' then work_distance else work_hours end into units from public.equipment_order_links where order_id=p_order and equipment_id=p_machine and user_id=p_owner;
 is_linked:=found;
 units:=case when is_linked and state='Выполнен' and not was_excluded then coalesce(units,0) else 0 end;
 before_value:=a.base_value+coalesce((select sum(contribution) from public.equipment_meter_entries where equipment_id=p_machine),0)-a.base_sum;
 after_value:=before_value+units-old_units;
 if after_value<0 then raise exception 'Meter would be negative; review actual reading before this change' using errcode='23514';end if;
 insert into public.equipment_meter_entries(order_id,equipment_id,user_id,historical_excluded,linked,contribution) values(p_order,p_machine,p_owner,was_excluded,is_linked,units)
 on conflict(order_id,equipment_id) do update set linked=excluded.linked,contribution=excluded.contribution,updated_at=now();
 if units<>old_units then
  update public.equipment_meter_accounts set version=version+1 where equipment_id=p_machine;
  insert into public.equipment_meter_events(equipment_id,user_id,actor_id,actor_role,event_type,order_id,previous_value,new_value,delta,reason)
  values(p_machine,p_owner,auth.uid(),current_setting('role',true),'order',p_order,before_value,after_value,units-old_units,'Пересчёт вклада выполненного заказа');
 end if;
end $$;
create function public.crm_meter_link_changed() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare r record;
begin
 for r in select distinct x.o,x.m,x.u from (values
 (case when tg_op<>'INSERT' then old.order_id end,case when tg_op<>'INSERT' then old.equipment_id end,case when tg_op<>'INSERT' then old.user_id end),
 (case when tg_op<>'DELETE' then new.order_id end,case when tg_op<>'DELETE' then new.equipment_id end,case when tg_op<>'DELETE' then new.user_id end)) x(o,m,u) where x.o is not null order by x.o,x.m loop
  perform public.crm_meter_sync_pair(r.o,r.m,r.u);
 end loop;
 return null;
end $$;
create trigger crm_meter_link_changed after insert or update or delete on public.equipment_order_links for each row execute function public.crm_meter_link_changed();
create function public.crm_meter_order_changed() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare r record;
begin
 for r in select equipment_id from public.equipment_order_links where order_id=old.id and user_id=old.user_id union select equipment_id from public.equipment_meter_entries where order_id=old.id and user_id=old.user_id order by equipment_id loop
  perform public.crm_meter_sync_pair(old.id,r.equipment_id,old.user_id);
 end loop;return null;
end $$;
create trigger crm_meter_order_status after update on public.orders for each row when(old.status is distinct from new.status) execute function public.crm_meter_order_changed();
create trigger crm_meter_order_deleted after delete on public.orders for each row execute function public.crm_meter_order_changed();
create function public.crm_meter_protect_base() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if new.meter_value is distinct from old.meter_value or new.meter_kind is distinct from old.meter_kind then
  if current_setting('role',true) not in ('none','postgres','supabase_admin','service_role') and auth.uid() is distinct from old.user_id then raise exception 'Machine unavailable' using errcode='42501';end if;
  insert into crm_meter_private.guards as g(equipment_id,version) values(old.id,1) on conflict(equipment_id) do update set version=g.version+1;
  if exists(select 1 from public.equipment_meter_accounts where equipment_id=old.id) then
   raise exception 'Use the actual-reading correction; meter unit is fixed after history begins' using errcode='23514';
  end if;
 end if;return new;
end $$;
create trigger crm_meter_protect_base before update on public.equipment for each row execute function public.crm_meter_protect_base();

-- Owner-filtered, single-statement snapshot, no cross-request arithmetic.
create function public.crm_meter_snapshot() returns jsonb language sql stable security definer set search_path=pg_catalog,pg_temp as $$
 select jsonb_build_object('machines',coalesce((select jsonb_agg(jsonb_build_object('equipment_id',e.id,'enabled',coalesce(a.enabled,false),'has_account',a.equipment_id is not null,'meter_kind',e.meter_kind,'current_value',coalesce(a.base_value+s.total-a.base_sum,e.meter_value),'version',coalesce(a.version,0),'activated_at',a.activated_at)) from public.equipment e left join public.equipment_meter_accounts a on a.equipment_id=e.id left join lateral(select coalesce(sum(contribution),0) total from public.equipment_meter_entries where equipment_id=e.id) s on true where e.user_id=auth.uid()),'[]'::jsonb),'entries',coalesce((select jsonb_agg(to_jsonb(t)) from public.equipment_meter_entries t where t.user_id=auth.uid()),'[]'::jsonb))
$$;
-- Common explicit user operation: activation or actual-reading correction.
create function public.crm_meter_confirm(p_equipment_id uuid,p_action text,p_value numeric,p_expected_version bigint,p_reason text,p_request_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare uid uuid:=auth.uid(); e record; a record; prior record; previous numeric; total numeric; payload jsonb; v bigint; reset_entries jsonb:='[]'::jsonb;
begin
 if uid is null then raise exception 'Sign in required' using errcode='42501';end if;
 if p_action is null or p_action not in ('activation','correction','replacement') or p_value is null or p_value<0 or p_value::text in ('NaN','Infinity','-Infinity') or p_value<>round(p_value,2) or p_request_id is null or p_reason is null or length(btrim(p_reason)) not between 1 and 2000 then raise exception 'Invalid meter confirmation' using errcode='22023';end if;
 select * into e from public.equipment where id=p_equipment_id and user_id=uid for no key update;
 if not found then raise exception 'Machine unavailable' using errcode='42501';end if;
 insert into crm_meter_private.guards as g(equipment_id,version) values(p_equipment_id,1) on conflict(equipment_id) do update set version=g.version+1;
 payload:=jsonb_build_object('machine',p_equipment_id,'action',p_action,'value',p_value,'version',p_expected_version,'reason',p_reason);
 select * into prior from public.equipment_meter_events where user_id=uid and request_id=p_request_id;
 if found then
  if prior.request_payload is distinct from payload then raise exception 'Request ID already used with different values; reload' using errcode='22023';end if;
  return public.crm_meter_snapshot();
 end if;
 select * into a from public.equipment_meter_accounts where equipment_id=p_equipment_id;
 total:=coalesce((select sum(contribution) from public.equipment_meter_entries where equipment_id=p_equipment_id),0);
 previous:=case when a.equipment_id is null then e.meter_value else a.base_value+total-a.base_sum end;
 v:=coalesce(a.version,0);
 if p_expected_version is distinct from v then raise exception 'Reading changed; reload before confirming' using errcode='40001';end if;
 if p_action='activation' then
  if coalesce(a.enabled,false) then raise exception 'Already active' using errcode='23505';end if;
  if p_value is distinct from previous then raise exception 'Confirm current value or correct it first' using errcode='40001';end if;
  insert into public.equipment_meter_accounts(equipment_id,user_id,meter_kind,enabled,base_value,base_sum,version,activated_at) values(e.id,uid,e.meter_kind,true,previous,0,v+1,clock_timestamp()) on conflict(equipment_id) do update set enabled=true,base_value=excluded.base_value,base_sum=0,version=excluded.version,activated_at=excluded.activated_at;
  insert into public.equipment_meter_entries(order_id,equipment_id,user_id,historical_excluded,linked,contribution)
  select l.order_id,l.equipment_id,uid,coalesce(o.status='Выполнен',false),true,0 from public.equipment_order_links l join public.orders o on o.id=l.order_id where l.equipment_id=e.id and l.user_id=uid;
 else
  if p_action='replacement' then
   select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) into reset_entries from public.equipment_meter_entries t where equipment_id=e.id;
   update public.equipment_meter_entries set historical_excluded=true,contribution=0,updated_at=now() where equipment_id=e.id;
   total:=0;
  end if;
  insert into public.equipment_meter_accounts(equipment_id,user_id,meter_kind,base_value,base_sum,version) values(e.id,uid,e.meter_kind,p_value,total,v+1)
  on conflict(equipment_id) do update set base_value=excluded.base_value,base_sum=excluded.base_sum,version=excluded.version;
 end if;
 insert into public.equipment_meter_events(equipment_id,user_id,actor_id,actor_role,event_type,previous_value,new_value,delta,reason,request_id,request_payload,details)
 values(e.id,uid,uid,current_setting('role',true),case when p_action='activation' then 'activation' else 'correction' end,previous,case when p_action='activation' then previous else p_value end,case when p_action='activation' then 0 else p_value-previous end,p_reason,p_request_id,payload,jsonb_build_object('replacement',p_action='replacement','excluded_entries',reset_entries));
 return public.crm_meter_snapshot();
end $$;
-- Existing restrictive financial FKs remain authoritative. Any failure rolls
-- back unlinking, meter events and order deletion together; no expenses removed.
create function public.crm_delete_order_with_meter(p_order_id uuid) returns uuid language plpgsql security invoker set search_path=pg_catalog,pg_temp as $$
declare uid uuid:=auth.uid(); deleted_id uuid;
begin
 if uid is null or not exists(select 1 from public.orders where id=p_order_id and user_id=uid for update) then raise exception 'Order unavailable' using errcode='42501';end if;
 delete from public.equipment_order_links where order_id=p_order_id and user_id=uid;
 delete from public.orders where id=p_order_id and user_id=uid returning id into deleted_id;
 if not found then raise exception 'Order deletion denied by policy' using errcode='42501';end if;
 return deleted_id;
end $$;
revoke all on function public.crm_meter_sync_pair(uuid,uuid,uuid),public.crm_meter_link_changed(),public.crm_meter_order_changed(),public.crm_meter_protect_base(),public.crm_meter_snapshot(),public.crm_meter_confirm(uuid,text,numeric,bigint,text,uuid),public.crm_delete_order_with_meter(uuid) from public,anon,authenticated;
grant execute on function public.crm_meter_snapshot(),public.crm_meter_confirm(uuid,text,numeric,bigint,text,uuid),public.crm_delete_order_with_meter(uuid) to authenticated;
commit;
