/// Cliente del API. Guarda el token en localStorage y convierte los errores del
/// hub en excepciones con el mensaje que ya viene escrito para la gente.

const CLAVE_TOKEN = 'apk-server-token'

export const sesion = {
  get token() {
    try { return localStorage.getItem(CLAVE_TOKEN) || '' } catch { return '' }
  },
  set token(v) {
    try {
      if (v) localStorage.setItem(CLAVE_TOKEN, v)
      else localStorage.removeItem(CLAVE_TOKEN)
    } catch { /* navegación privada: la sesión dura lo que la pestaña */ }
  },
}

function falla(status, d) {
  // 401 con sesión guardada = el token caducó o el hub rotó su secreto.
  if (status === 401 && sesion.token) sesion.token = ''
  const e = new Error(d.mensaje || d.error || `Error ${status}`)
  e.codigo = d.error
  e.status = status
  return e
}

async function pide(metodo, ruta, cuerpo) {
  const r = await fetch(ruta, {
    method: metodo,
    headers: {
      'content-type': 'application/json',
      ...(sesion.token ? { authorization: `Bearer ${sesion.token}` } : {}),
    },
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  })
  if (r.status === 204) return null
  const d = await r.json().catch(() => ({}))
  if (!r.ok) throw falla(r.status, d)
  return d
}

/// Sube un archivo tal cual (el APK, el icono) con progreso. Va por XHR porque
/// `fetch` todavía no cuenta lo que lleva subido.
function sube(metodo, ruta, archivo, alProgreso) {
  return new Promise((resolver, rechazar) => {
    const x = new XMLHttpRequest()
    x.open(metodo, ruta)
    if (sesion.token) x.setRequestHeader('authorization', `Bearer ${sesion.token}`)
    x.upload.onprogress = (e) => e.lengthComputable && alProgreso?.(e.loaded / e.total)
    x.onload = () => {
      let d = {}
      try { d = JSON.parse(x.responseText || '{}') } catch { /* cuerpo vacío */ }
      if (x.status >= 200 && x.status < 300) resolver(d)
      else rechazar(falla(x.status, d))
    }
    x.onerror = () => rechazar(new Error('Se cortó la conexión'))
    x.send(archivo)
  })
}

export const api = {
  get: (r) => pide('GET', r),
  post: (r, c) => pide('POST', r, c),
  put: (r, c) => pide('PUT', r, c),
  patch: (r, c) => pide('PATCH', r, c),
  del: (r) => pide('DELETE', r),
  sube,
}

// ---------------------------------------------------------------- formatos

export function bytes(n) {
  if (n == null) return ''
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

/// «hace 5 min», «ayer», o la fecha si es de hace más de una semana.
export function hace(s) {
  if (!s) return 'nunca'
  const t = new Date(s)
  const seg = (Date.now() - t.getTime()) / 1000
  if (seg < 60) return 'ahora'
  if (seg < 3600) return `hace ${Math.floor(seg / 60)} min`
  if (seg < 86400) return `hace ${Math.floor(seg / 3600)} h`
  if (seg < 172800) return 'ayer'
  if (seg < 604800) return `hace ${Math.floor(seg / 86400)} días`
  return t.toLocaleDateString()
}

export const fecha = (s) => (s ? new Date(s).toLocaleString() : '')

export const inicial = (nombre = '?') => nombre.trim().charAt(0).toUpperCase() || '?'
