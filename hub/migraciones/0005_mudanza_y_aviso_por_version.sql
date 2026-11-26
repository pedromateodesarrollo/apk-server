-- Por versión (0.6.0):
--  * aviso_minutos: pisa el de la app solo para esa versión (null = el de la app). Sirve para sacar un arreglo
--    urgente sin la cuenta regresiva de la app, o para darle más aviso a una versión grande.
--  * mudanza: la versión puente de una app que se muda a otro hub. Es un APK que ya pregunta al hub nuevo
--    (apkServerHub) y que este hub reparte una última vez; desde que se instala, el equipo le pregunta al otro.
--    Solo lo publica un administrador y solo si el hub nuevo ya tiene ese mismo APK (mismo sha256).
alter table apk.version add column if not exists aviso_minutos integer
  check (aviso_minutos between 0 and 240);
alter table apk.version add column if not exists mudanza text;
