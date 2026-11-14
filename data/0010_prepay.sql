-- 0010 · Pago por adelantado (con pago simulado hasta integrar Mercado Pago)
--
-- Flujo: el lanchero acepta (o el pasajero acepta su oferta) → el viaje queda 'assigned' con
-- payment_status 'pending' y pay_deadline. El pasajero paga antes del vencimiento → 'paid' y el
-- lanchero puede salir. Si vence sin pago, el viaje se cancela solo (cancel_reason 'payment_timeout').
--
-- Cancelación del pasajero después de pagar: devolución total dentro de free_cancel_window_sec;
-- pasado ese plazo se retiene una multa = comisión × cancel_penalty_mult, que queda para la plataforma.
-- Si cancela el lanchero u operaciones, devolución total.
--
-- El recargo por espera y la propina no pasan por la app: el pasajero se los paga directo al lanchero.
-- Con prepay_required no hay efectivo. Para un despliegue sin prepago: update pricing_params set prepay_required = false.

alter table pricing_params
  add column if not exists prepay_required boolean not null default true,
  add column if not exists payment_simulated boolean not null default true,   -- apagar al conectar el cobro real
  add column if not exists pay_window_sec int not null default 180,           -- viajes "ahora"
  add column if not exists pay_window_scheduled_min int not null default 30,  -- reservas programadas
  add column if not exists free_cancel_window_sec int not null default 120,
  add column if not exists cancel_penalty_mult numeric(4,2) not null default 2;

alter table trips
  add column if not exists pay_deadline timestamptz,
  add column if not exists paid_at timestamptz,
  add column if not exists paid_amount int,
  add column if not exists refund_amount int,
  add column if not exists cancel_penalty int;

-- ---------------------------------------------------------------- Auxiliares

-- Hasta cuándo puede pagar el pasajero un viaje que se acaba de asignar. Null = sin prepago.
create or replace function trip_pay_deadline(p_scheduled timestamptz) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case
    when not pp.prepay_required then null
    when p_scheduled is not null and p_scheduled > now() + make_interval(mins => pp.pay_window_scheduled_min)
      then now() + make_interval(mins => pp.pay_window_scheduled_min)
    else now() + make_interval(secs => pp.pay_window_sec)
  end
  from pricing_params pp where pp.id = 1;
$$;

-- Cuánto se devuelve y cuánto se retiene si el pasajero cancela ahora un viaje pagado.
create or replace function trip_cancel_amounts(p_paid int, p_paid_at timestamptz, p_commission_pct numeric)
returns table (refund int, penalty int)
language sql stable security definer set search_path = public as $$
  select p_paid - x.penalty, x.penalty
  from pricing_params pp,
  lateral (select case
      when p_paid is null then 0
      when now() <= p_paid_at + make_interval(secs => pp.free_cancel_window_sec) then 0
      else least(p_paid, round(p_paid * coalesce(p_commission_pct, pp.commission_pct) / 100.0 * pp.cancel_penalty_mult)::int)
    end as penalty) x
  where pp.id = 1;
$$;

-- Marca un viaje como pagado. Interna: la llaman el pago simulado y, más adelante, el aviso de Mercado Pago.
create or replace function trip_mark_paid(p_trip uuid, p_amount int, p_ref text) returns trips
language plpgsql security definer set search_path = public as $$
declare t trips;
begin
  update trips set payment_status = 'paid', paid_at = now(), paid_amount = p_amount, mp_payment_id = p_ref
   where id = p_trip and status = 'assigned' and payment_status = 'pending'
   returning * into t;
  if not found then raise exception 'cannot_pay'; end if;
  insert into trip_events (trip_id, actor_id, type, payload)
  values (p_trip, auth.uid(), 'paid', jsonb_build_object('amount', p_amount, 'ref', p_ref));
  return t;
end $$;
revoke execute on function trip_mark_paid(uuid, int, text) from public, anon, authenticated;

-- Cancela los viajes asignados cuyo plazo de pago venció. Devuelve cuántos canceló.
create or replace function expire_unpaid_trips(p_trip uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with x as (
    update trips set status = 'cancelled_passenger', cancelled_at = now(), cancel_reason = 'payment_timeout'
     where status = 'assigned' and payment_status = 'pending'
       and pay_deadline is not null and pay_deadline < now()
       and (p_trip is null or id = p_trip)
     returning id)
  insert into trip_events (trip_id, type) select id, 'payment_timeout' from x;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function expire_unpaid_trips(uuid) to authenticated;

-- ---------------------------------------------------------------- Pago simulado

create or replace function pay_trip_simulated(p_trip uuid) returns trips
language plpgsql security definer set search_path = public as $$
declare t trips;
begin
  if not (select payment_simulated from pricing_params where id = 1) then raise exception 'simulated_payment_disabled'; end if;
  select * into t from trips where id = p_trip and passenger_id = auth.uid();
  if not found then raise exception 'not_your_trip'; end if;
  if t.status <> 'assigned' or t.payment_status <> 'pending' or t.pay_deadline is null then raise exception 'cannot_pay'; end if;
  if t.pay_deadline < now() then raise exception 'payment_expired'; end if;
  return trip_mark_paid(p_trip, t.price_quoted, 'SIM-' || replace(gen_random_uuid()::text, '-', ''));
end $$;
grant execute on function pay_trip_simulated(uuid) to authenticated;

-- Lo que vería el pasajero si cancela ahora (para mostrarlo antes de confirmar).
create or replace function passenger_cancel_quote(p_trip uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'paid', case when t.payment_status = 'paid' then t.paid_amount else 0 end,
    'refund', case when t.payment_status = 'paid' then a.refund else 0 end,
    'penalty', case when t.payment_status = 'paid' then a.penalty else 0 end)
  from trips t, lateral trip_cancel_amounts(t.paid_amount, t.paid_at, t.commission_pct) a
  where t.id = p_trip and t.passenger_id = auth.uid();
$$;
grant execute on function passenger_cancel_quote(uuid) to authenticated;

-- ---------------------------------------------------------------- Asignación: arranca el plazo de pago

create or replace function accept_trip(p_trip uuid, p_boat uuid default null, p_price int default null)
returns trips language plpgsql security definer set search_path = public as $$
declare
  t trips; pp pricing_params%rowtype; b uuid;
begin
  if not is_active_driver() then raise exception 'driver_not_active'; end if;
  select * into pp from pricing_params where id = 1;
  b := coalesce(p_boat, (select id from boats where driver_id = auth.uid() and is_active order by created_at limit 1));

  update trips
     set driver_id = auth.uid(), boat_id = b, status = 'assigned', assigned_at = now(),
         price_quoted = coalesce(price_quoted, price_reference),
         commission_pct = pp.commission_pct,
         pay_deadline = trip_pay_deadline(scheduled_at)
   where id = p_trip and status in ('requested','quoting') and driver_id is null
   returning * into t;
  if not found then raise exception 'trip_already_taken'; end if;

  update trip_offers set status = 'rejected' where trip_id = p_trip and status = 'pending';
  update trip_dispatches set responded_at = now(), accepted = true where trip_id = p_trip and driver_id = auth.uid();
  insert into trip_events (trip_id, actor_id, type) values (p_trip, auth.uid(), 'assigned');
  return t;
end $$;

create or replace function accept_offer(p_offer uuid) returns trips
language plpgsql security definer set search_path = public as $$
declare o trip_offers; t trips; pp pricing_params%rowtype; b uuid;
begin
  select * into o from trip_offers where id = p_offer and status = 'pending' and (expires_at is null or expires_at > now());
  if not found then raise exception 'offer_not_available'; end if;
  select * into t from trips where id = o.trip_id and passenger_id = auth.uid() and status in ('quoting','requested') and driver_id is null;
  if not found then raise exception 'trip_not_available'; end if;
  select * into pp from pricing_params where id = 1;
  b := (select id from boats where driver_id = o.driver_id and is_active order by created_at limit 1);

  update trips set driver_id = o.driver_id, boat_id = b, status = 'assigned', assigned_at = now(),
                   price_quoted = o.price, commission_pct = pp.commission_pct,
                   pay_deadline = trip_pay_deadline(scheduled_at)
   where id = t.id returning * into t;
  update trip_offers set status = 'accepted' where id = p_offer;
  update trip_offers set status = 'rejected' where trip_id = t.id and id <> p_offer and status = 'pending';
  update trip_dispatches set responded_at = now(), accepted = true where trip_id = t.id and driver_id = o.driver_id;
  insert into trip_events (trip_id, actor_id, type, payload) values (t.id, auth.uid(), 'offer_accepted', jsonb_build_object('offer', p_offer));
  return t;
end $$;

create or replace function admin_assign_trip(p_trip uuid, p_driver uuid)
returns trips language plpgsql security definer set search_path = public as $$
declare t trips; pp pricing_params%rowtype; b uuid;
begin
  perform assert_admin();
  if not exists (select 1 from driver_profiles where user_id = p_driver and status = 'active') then raise exception 'driver_not_active'; end if;
  select * into pp from pricing_params where id = 1;
  b := (select id from boats where driver_id = p_driver and is_active order by created_at limit 1);
  update trips
     set driver_id = p_driver, boat_id = b, status = 'assigned', assigned_at = now(),
         price_quoted = coalesce(price_quoted, price_reference), commission_pct = pp.commission_pct,
         pay_deadline = trip_pay_deadline(scheduled_at)
   where id = p_trip and status in ('requested','quoting') and driver_id is null
   returning * into t;
  if not found then raise exception 'trip_not_available'; end if;
  update trip_offers set status = 'rejected' where trip_id = p_trip and status = 'pending';
  insert into trip_events (trip_id, actor_id, type, payload) values (p_trip, auth.uid(), 'assigned_ops', jsonb_build_object('driver', p_driver));
  perform audit_write('trip.assign', 'trips', p_trip::text, t.origin_name || ' → ' || t.dest_name, null,
    jsonb_build_object('driver', (select full_name from profiles where id = p_driver)));
  return t;
end $$;

-- ---------------------------------------------------------------- Avance del viaje por el lanchero

create or replace function driver_set_trip_status(p_trip uuid, p_status trip_status) returns trips
language plpgsql security definer set search_path = public as $$
declare t trips; pp pricing_params%rowtype; waited int; fee int := 0; prepaid boolean; refund int;
begin
  select * into t from trips where id = p_trip and driver_id = auth.uid();
  if not found then raise exception 'not_your_trip'; end if;
  select * into pp from pricing_params where id = 1;
  prepaid := t.paid_amount is not null and t.payment_status = 'paid';

  -- Con prepago el lanchero no sale hasta que el pago esté acreditado
  if t.pay_deadline is not null and t.payment_status = 'pending' and p_status <> 'cancelled_driver' then
    raise exception 'payment_pending';
  end if;

  if p_status = 'arriving' and t.status = 'assigned' then
    update trips set status = 'arriving' where id = p_trip returning * into t;
  elsif p_status = 'waiting' and t.status in ('assigned','arriving') then
    update trips set status = 'waiting', arrived_at = now() where id = p_trip returning * into t;
  elsif p_status = 'onboard' and t.status in ('waiting','arriving','assigned') then
    if t.arrived_at is not null then
      waited := greatest(0, extract(epoch from now() - t.arrived_at)::int / 60 - pp.free_wait_min);
      fee := ceil(waited / 5.0)::int * pp.wait_fee_per_5min;
    end if;
    update trips set status = 'onboard', onboard_at = now(), wait_fee = fee where id = p_trip returning * into t;
  elsif p_status = 'completed' and t.status = 'onboard' then
    -- Prepago: lo cobrado por la app es lo que se pagó; la espera se la paga el pasajero directo al lanchero.
    update trips set status = 'completed', completed_at = now(),
           price_final = case when prepaid then paid_amount else coalesce(price_final, price_quoted) + coalesce(wait_fee,0) end,
           driver_payout = round((case when prepaid then paid_amount else coalesce(price_quoted,0) + coalesce(wait_fee,0) end)
                                 * (1 - coalesce(commission_pct, pp.commission_pct) / 100)),
           payment_status = case when payment_method = 'cash' then 'paid' else payment_status end
     where id = p_trip returning * into t;
    update docks set trips_count = trips_count + 1 where id in (t.origin_dock_id, t.dest_dock_id);
  elsif p_status = 'no_show' and t.status = 'waiting' then
    -- El pasajero pagó y no apareció: no hay devolución y el lanchero cobra su parte.
    update trips set status = 'no_show', cancelled_at = now(),
           price_final = case when prepaid then paid_amount else price_final end,
           driver_payout = case when prepaid then round(paid_amount * (1 - coalesce(commission_pct, pp.commission_pct) / 100)) else driver_payout end
     where id = p_trip returning * into t;
  elsif p_status = 'cancelled_driver' and t.status in ('assigned','arriving','waiting') then
    refund := case when prepaid then t.paid_amount end;
    update trips set status = 'cancelled_driver', cancelled_at = now(),
           payment_status = case when prepaid then 'refunded'::payment_status else payment_status end,
           refund_amount = refund, cancel_penalty = case when prepaid then 0 end
     where id = p_trip returning * into t;
  else
    raise exception 'invalid_transition from % to %', t.status, p_status;
  end if;

  insert into trip_events (trip_id, actor_id, type, payload)
  values (p_trip, auth.uid(), p_status::text, case when refund is not null then jsonb_build_object('refund', refund) end);
  return t;
end $$;

-- ---------------------------------------------------------------- Cancelaciones

-- p_max_penalty: la multa que la app le mostró al pasajero antes de confirmar. Si mientras tanto venció la
-- ventana de devolución total y la multa real es mayor, se rechaza para que vuelva a ver el monto.
drop function if exists passenger_cancel_trip(uuid, text);
create or replace function passenger_cancel_trip(p_trip uuid, p_reason text default null, p_max_penalty int default null) returns trips
language plpgsql security definer set search_path = public as $$
declare t trips; refund int; penalty int;
begin
  select * into t from trips
   where id = p_trip and passenger_id = auth.uid() and status in ('requested','quoting','assigned','arriving','waiting')
   for update;
  if not found then raise exception 'cannot_cancel'; end if;

  if t.payment_status = 'paid' and t.paid_amount is not null then
    select a.refund, a.penalty into refund, penalty from trip_cancel_amounts(t.paid_amount, t.paid_at, t.commission_pct) a;
    if p_max_penalty is not null and penalty > p_max_penalty then raise exception 'penalty_changed'; end if;
  end if;

  update trips set status = 'cancelled_passenger', cancelled_at = now(), cancel_reason = p_reason,
         payment_status = case when refund > 0 then 'refunded'::payment_status else payment_status end,
         refund_amount = refund, cancel_penalty = penalty,
         driver_payout = case when refund is not null then 0 else driver_payout end   -- la multa queda para la plataforma
   where id = p_trip returning * into t;
  update trip_offers set status = 'rejected' where trip_id = p_trip and status = 'pending';
  insert into trip_events (trip_id, actor_id, type, payload)
  values (p_trip, auth.uid(), 'cancelled_passenger', jsonb_strip_nulls(jsonb_build_object('reason', p_reason, 'refund', refund, 'penalty', penalty)));
  return t;
end $$;
grant execute on function passenger_cancel_trip(uuid, text, int) to authenticated;

create or replace function admin_cancel_trip(p_trip uuid, p_reason text default null)
returns trips language plpgsql security definer set search_path = public as $$
declare t trips;
begin
  perform assert_admin();
  update trips set status = 'cancelled_ops', cancelled_at = now(), cancel_reason = p_reason,
         refund_amount = case when payment_status = 'paid' and paid_amount is not null then paid_amount else refund_amount end,
         cancel_penalty = case when payment_status = 'paid' and paid_amount is not null then 0 else cancel_penalty end,
         payment_status = case when payment_status = 'paid' and paid_amount is not null then 'refunded'::payment_status else payment_status end
   where id = p_trip and status in ('requested','quoting','assigned','arriving','waiting','onboard')
   returning * into t;
  if not found then raise exception 'cannot_cancel'; end if;
  update trip_offers set status = 'rejected' where trip_id = p_trip and status = 'pending';
  insert into trip_events (trip_id, actor_id, type, payload)
  values (p_trip, auth.uid(), 'cancelled_ops', jsonb_strip_nulls(jsonb_build_object('reason', p_reason, 'refund', t.refund_amount)));
  perform audit_write('trip.cancel', 'trips', p_trip::text, t.origin_name || ' → ' || t.dest_name, null, jsonb_build_object('reason', p_reason));
  return t;
end $$;

-- ---------------------------------------------------------------- Vencimientos sin depender de que alguien tenga la app abierta

-- Cada lanchero conectado reporta su ubicación seguido: se aprovecha para limpiar viajes con el pago vencido.
create or replace function update_driver_location(
  p_lat double precision, p_lng double precision, p_heading real default null, p_speed real default null
) returns void language plpgsql security definer as $$
declare
  loc geography := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  active_trip uuid;
begin
  perform expire_unpaid_trips();
  update driver_profiles
     set last_location = loc, last_heading = p_heading, last_speed_kmh = p_speed, last_seen_at = now()
   where user_id = auth.uid();
  select id into active_trip from trips
   where driver_id = auth.uid() and status in ('assigned','arriving','waiting','onboard')
   order by assigned_at desc limit 1;
  insert into driver_locations (driver_id, trip_id, location, heading, speed_kmh)
  values (auth.uid(), active_trip, loc, p_heading, p_speed);
end $$;

-- ---------------------------------------------------------------- Lo que el cliente no puede tocar

-- Al crear un viaje desde la app, el precio lo calcula la base (no se confía en el que manda el teléfono)
-- y los campos de pago arrancan limpios. Con prepago no hay efectivo.
create or replace function trips_prepare_insert() returns trigger language plpgsql as $$
declare q record;
begin
  if current_user not in ('authenticated', 'anon') or is_admin() then return new; end if;

  select * into q from quote_trip(
    new.origin_dock_id, new.dest_dock_id,
    st_y(new.origin_location::geometry), st_x(new.origin_location::geometry),
    st_y(new.dest_location::geometry), st_x(new.dest_location::geometry),
    new.boat_class, coalesce(new.cargo, '{}'), coalesce(new.scheduled_at, now()));
  new.pricing_mode := q.mode;
  new.km_water := q.km_water;
  new.price_reference := q.price;
  new.price_quoted := case when q.mode = 'quote' then null else q.price end;
  new.status := case when q.mode = 'quote' then 'quoting' else 'requested' end;

  new.price_final := null; new.commission_pct := null; new.driver_payout := null;
  new.wait_fee := 0; new.tip := 0;
  new.payment_status := 'pending'; new.mp_preference_id := null; new.mp_payment_id := null;
  new.pay_deadline := null; new.paid_at := null; new.paid_amount := null;
  new.refund_amount := null; new.cancel_penalty := null;
  if (select prepay_required from pricing_params where id = 1) then new.payment_method := 'mp'; end if;
  return new;
end $$;
drop trigger if exists trips_prepare_insert on trips;
create trigger trips_prepare_insert before insert on trips for each row execute function trips_prepare_insert();

-- Edición directa desde la app: cada parte solo puede calificar a la otra (y el pasajero dejar propina).
-- Estado, precio y pago cambian únicamente por las funciones de arriba.
create or replace function trips_guard_client_update() returns trigger language plpgsql as $$
declare keep text[];
begin
  if current_user not in ('authenticated', 'anon') or is_admin() then return new; end if;
  keep := case when auth.uid() = old.passenger_id then array['driver_rating', 'driver_comment', 'tip']
               else array['passenger_rating', 'passenger_comment'] end;
  if (to_jsonb(new) - keep) is distinct from (to_jsonb(old) - keep) then
    raise exception 'forbidden_columns';
  end if;
  return new;
end $$;
drop trigger if exists trips_guard_client_update on trips;
create trigger trips_guard_client_update before update on trips for each row execute function trips_guard_client_update();
