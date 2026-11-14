-- 0011 · Cobro real con Mercado Pago (Checkout Pro vía Orders API)
--
-- La app llama a la función Edge `mp-order`, que crea la order en Mercado Pago y devuelve `checkout_url`;
-- el pasajero paga ahí. Mercado Pago avisa a `mp-webhook` (tipo "order"), que relee la order con el
-- access token y marca el viaje pagado con trip_mark_paid. Las devoluciones (cancelaciones) las hace
-- `mp-refund` leyendo refund_amount, que ya calculan las funciones de la migración 0010.
--
-- Secretos de las funciones (Edge Functions → Secrets): MP_ACCESS_TOKEN, MP_WEBHOOK_SECRET, APP_URL.
-- Mientras payment_simulated sea true, `mp-order` sigue pagando en simulado (no llama a Mercado Pago).

alter table trips
  add column if not exists mp_checkout_url text,   -- adónde mandar al pasajero a pagar (vale mientras la order esté abierta)
  add column if not exists mp_refund_id text,      -- devolución hecha en Mercado Pago (null = pendiente o sin devolución)
  add column if not exists mp_refund_error text;   -- último error al intentar devolver

-- mp_preference_id guarda el id de la order (ORD...); mp_payment_id, el id de la order pagada.
comment on column trips.mp_preference_id is 'Id de la order de Mercado Pago (Orders API)';
comment on column trips.mp_payment_id is 'Id de la order pagada en Mercado Pago (o SIM-... si fue simulado)';

-- Las funciones Edge trabajan con la clave de servicio.
grant execute on function trip_mark_paid(uuid, int, text) to service_role;

-- Pasa a cobro real. (Para volver al simulado: update pricing_params set payment_simulated = true.)
update pricing_params set payment_simulated = false where id = 1;

-- Las funciones creadas por 0010 después del endurecimiento quedan con search_path fijo y sin acceso anónimo.
do $$
declare f record;
begin
  for f in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and coalesce(array_to_string(p.proconfig, ','), '') not like '%search_path=%'
  loop
    execute format('alter function public.%I(%s) set search_path = public', f.proname, f.args);
    execute format('revoke execute on function public.%I(%s) from public, anon', f.proname, f.args);
  end loop;
end $$;
