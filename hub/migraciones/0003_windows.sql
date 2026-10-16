-- Instaladores de Windows (MSI) además de APK (0.3.0). Una app es de una sola
-- plataforma: `android` (lo de siempre: el hub lee paquete, build y firma del
-- APK) o `windows` (un MSI: la build y la versión las dice quien publica, porque
-- el hub no abre el MSI; solo comprueba que lo sea).
--
-- `firma_publicador`: lo que firma quien publica (por ejemplo, ECDSA sobre
-- «app:build:sha256») para que el programa instalado compruebe, con la llave
-- pública que lleva dentro, que el instalador es de su autor antes de correrlo.
-- En Android eso lo hace el sistema con la firma del APK; un MSI sin firma de
-- código no tiene quién. El hub no la interpreta: la guarda y la reparte.

alter table apk.app add column if not exists plataforma text not null default 'android'
  check (plataforma in ('android', 'windows'));
alter table apk.version add column if not exists formato text not null default 'apk'
  check (formato in ('apk', 'msi'));
alter table apk.version add column if not exists firma_publicador text;
