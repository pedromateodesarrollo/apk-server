// Genera `docs/api.md` desde `src/docs.js`.
//
// La documentación se escribe una vez y sale en los dos sitios donde la gente
// la busca: la página y el repositorio.
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { intro, autenticacion, clientes, puntos, errores, grupos } from '../src/docs.js'

const aqui = dirname(fileURLToPath(import.meta.url))
const salida = join(aqui, '..', '..', 'docs', 'api.md')

const l = []
l.push(`# ${intro.titulo}`, '', intro.texto, '')
l.push('> Generado desde `manager/src/docs.js` con `npm run docs`. No lo edites a mano.', '')

l.push('## Autenticación', '')
for (const a of autenticacion) {
  l.push(`### ${a.titulo}`, '', a.texto, '')
  if (a.ejemplo) l.push('```bash', a.ejemplo, '```', '')
}

l.push('## Clientes Dart y Flutter', '')
for (const c of clientes) {
  l.push(`### ${c.titulo}`, '', c.texto, '')
  if (c.ejemplo) l.push('```dart', c.ejemplo, '```', '')
}

for (const g of grupos) {
  l.push(`## ${g}`, '')
  for (const p of puntos.filter((x) => x.grupo === g)) {
    l.push(`### \`${p.metodo} ${p.ruta}\``, '', `*Acceso: ${p.acceso}*`, '', p.resumen, '')
    if (p.cuerpo) {
      l.push('| Campo | Tipo | Obligatorio | |', '|---|---|---|---|')
      for (const c of p.cuerpo) l.push(`| \`${c[0]}\` | ${c[1]} | ${c[2]} | ${c[3]} |`)
      l.push('')
    }
    if (p.consulta) {
      l.push('| Parámetro | Tipo | | |', '|---|---|---|---|')
      for (const c of p.consulta) l.push(`| \`${c[0]}\` | ${c[1]} | ${c[2]} | ${c[3]} |`)
      l.push('')
    }
    if (p.nota) l.push(p.nota, '')
    if (p.respuesta) l.push('```json', p.respuesta, '```', '')
    if (p.ejemplo) l.push('```bash', p.ejemplo, '```', '')
  }
}

l.push('## Errores', '')
l.push('| HTTP | Código | Cuándo |', '|---|---|---|')
for (const e of errores) l.push(`| ${e[0]} | ${e[1]} | ${e[2]} |`)
l.push('')

writeFileSync(salida, l.join('\n'))
console.log(`docs/api.md — ${l.length} líneas`)
