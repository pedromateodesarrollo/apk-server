-- apk-server — esquema inicial.
--
-- Todo vive en el esquema `apk` para que el hub pueda compartir base de datos
-- con otra aplicación sin pisarle las tablas. Quien clone el repo levanta este
-- archivo en un Postgres vacío y ya.
--
-- Los APK NO están aquí: viven en disco, en `APK_ARCHIVOS`, con su sha256 por
-- nombre. Guardar decenas de megas por versión dentro de la base la engorda,
-- vuelve lentos los respaldos y no compra nada que un archivo no dé.
--
-- El aislamiento entre organizaciones lo aplica el código (toda consulta del
-- panel filtra por `org`). No hay RLS a propósito: el hub conecta con un solo
-- rol y una política por fila obligaría a fijar un GUC por petición sin ganar
-- nada que el filtro explícito no dé ya.

create schema if not exists apk;

-- Una organización es el inquilino. En una instalación de un solo dueño
-- habrá exactamente una y nadie la nota.
create table if not exists apk.org (
  id          bigserial primary key,
  nombre      text        not null,
  slug        text        not null unique,
  creado      timestamptz not null default now()
);

-- Una persona del panel. Entra por invitación: el administrador la da de alta
-- con su correo y le pasa un enlace de un solo uso donde ella pone su clave.
-- Hasta entonces `clave_hash` es null y no puede entrar.
create table if not exists apk.usuario (
  id                 bigserial primary key,
  org                bigint      not null references apk.org(id) on delete cascade,
  correo             text        not null unique,
  clave_hash         text,
  nombre             text        not null default '',
  rol                text        not null default 'editor' check (rol in ('admin', 'editor')),
  invitacion_hash    text,
  invitacion_vence   timestamptz,
  creado             timestamptz not null default now(),
  ultimo_acceso      timestamptz
);
create index if not exists usuario_invitacion_idx
  on apk.usuario (invitacion_hash) where invitacion_hash is not null;

-- Llave de API para los scripts que publican (`cak_<prefijo>_<secreto>`).
-- Se guarda el hash; el secreto se enseña una sola vez al crearla.
--
-- `apps` vacío = alcanza todas las apps de la organización. Con contenido, la
-- llave solo publica en esas: es la que se le da al proyecto de una sola app.
create table if not exists apk.llave (
  id          bigserial primary key,
  org         bigint      not null references apk.org(id) on delete cascade,
  nombre      text        not null,
  prefijo     text        not null,
  clave_hash  text        not null,
  permisos    text[]      not null default '{publicar}',
  apps        text[]      not null default '{}',
  creado      timestamptz not null default now(),
  ultimo_uso  timestamptz,
  revocada    timestamptz
);
create index if not exists llave_prefijo_idx on apk.llave (prefijo);

-- Una app es un `applicationId` de Android. Dos sabores con distinto
-- `applicationId` (el de una marca y el genérico) son dos apps: Android los
-- instala uno junto al otro y nunca actualiza uno con el otro.
--
-- El `slug` es global, no por organización: va en las URL públicas
-- (`/install/<slug>`, `/i/<slug>`) y en las apps compiladas, y tiene que
-- significar lo mismo para todos.
--
-- `paquete` lo fija el primer APK publicado; de ahí en adelante un APK con
-- otro `applicationId` se rechaza. `firma` igual: es el sha256 del
-- certificado, y un APK firmado con otra llave no actualiza la app instalada
-- (Android lo rechaza en el teléfono, cuando ya es tarde).
create table if not exists apk.app (
  id           bigserial primary key,
  org          bigint      not null references apk.org(id) on delete cascade,
  slug         text        not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{0,62}$'),
  nombre       text        not null,
  descripcion  text        not null default '',
  paquete      text,
  firma        text,
  icono        bytea,
  icono_tipo   text,
  creado       timestamptz not null default now()
);
create index if not exists app_org_idx on apk.app (org);

-- Una versión publicada. `build` es el versionCode: es lo que se compara,
-- crece siempre y no tiene ambigüedad. `version` es el nombre que ve la gente.
--
-- `requerido`: quien esté por debajo de esta build TIENE que instalarla,
-- aunque después salgan otras opcionales. `retirada`: deja de ofrecerse y de
-- servirse (la versión que salió mala), pero la fila se queda para la historia.
create table if not exists apk.version (
  id             bigserial primary key,
  app            bigint      not null references apk.app(id) on delete cascade,
  build          integer     not null check (build > 0),
  version        text        not null,
  requerido      boolean     not null default false,
  notas          text        not null default '',
  sha256         text        not null,
  bytes          bigint      not null,
  paquete        text        not null,
  firma          text,
  min_sdk        integer,
  target_sdk     integer,
  descargas      integer     not null default 0,
  publicado      timestamptz not null default now(),
  publicado_por  text        not null default '',
  retirada       timestamptz,
  unique (app, build)
);
create index if not exists version_sha_idx on apk.version (sha256);

-- Cada instalación que pregunta por versión nueva. Es lo que contesta «¿quién
-- sigue en la vieja?» y, con el WebSocket, «¿cuándo se vio por última vez
-- ese equipo?».
--
-- `clave` la genera la app la primera vez que corre y la guarda; `huella` es
-- el ANDROID_ID, que sobrevive a desinstalar y reinstalar (cambia con la llave
-- de firma y con un reseteo de fábrica). `contexto` es lo que la app quiera
-- contar de sí misma (empresa, usuario con sesión…): la app decide, el hub
-- solo lo guarda y lo enseña.
create table if not exists apk.instalacion (
  id            bigserial primary key,
  app           bigint      not null references apk.app(id) on delete cascade,
  clave         text        not null,
  huella        text,
  build         integer,
  version       text,
  modelo        text        not null default '',
  fabricante    text        not null default '',
  android       integer,
  contexto      jsonb       not null default '{}'::jsonb,
  ip            text        not null default '',
  nombre        text        not null default '',
  conectado     boolean     not null default false,
  primera_vez   timestamptz not null default now(),
  ultima_vez    timestamptz not null default now(),
  unique (app, clave)
);
create index if not exists instalacion_app_vez_idx on apk.instalacion (app, ultima_vez desc);
create index if not exists instalacion_huella_idx on apk.instalacion (huella) where huella is not null;
