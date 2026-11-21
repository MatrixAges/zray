import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [base_path, fixtures_path, output_path] = process.argv.slice(2)
const manifest = JSON.parse(readFileSync(base_path, 'utf8')) as {
    roots: Array<{ path: string; prefix?: string }>
    entries: Array<{ path: string; name: string }>
}

for (const directory of ['expression_preparation', 'type_parser']) {
    manifest.roots.push({ path: join(fixtures_path, directory), prefix: `fixtures/${directory}/` })
}

manifest.entries = [
    { path: 'zx/frontend/parser/templates/prepare.rx', name: 'template_direct' },
    { path: 'zx/frontend/lexical.rx', name: 'template_module' },
    { path: 'fixtures/expression_preparation/source.rx', name: 'expression_direct' },
    { path: 'zx/frontend/parser/prepare.rx', name: 'expression_module' },
    { path: 'fixtures/type_parser/source.rx', name: 'type_plain' },
    { path: 'zx/frontend/parser/type.rx', name: 'type_template' }
]

writeFileSync(output_path, JSON.stringify(manifest))
