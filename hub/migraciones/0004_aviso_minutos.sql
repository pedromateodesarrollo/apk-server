-- Actualización con aviso (0.5.0). Por app: cuántos minutos se avisa en el
-- equipo, con cuenta regresiva, antes de instalar una versión ya descargada.
-- 0 = como siempre (la app decide cuándo instalar). Lo lee la consulta
-- (`aviso_minutos`) y lo cambia el panel (PATCH /v1/apps/:app).
alter table apk.app add column if not exists aviso_minutos integer not null default 0
  check (aviso_minutos between 0 and 240);
