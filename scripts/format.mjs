import { execFileSync } from 'node:child_process'
import { existsSync, globSync } from 'node:fs'
import { readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { createSpacer } from 'gpu-code-spacer'

const args = process.argv.slice(2)
const check_only = args.includes('--check')
const rx_only = args.includes('--rx')
const requested_files = args.filter(arg => arg !== '--check' && arg !== '--rx')

const zig_patterns = [
    'build.zig',
    'build.zig.zon',
    'packages/*/build.zig',
    'packages/*/build.zig.zon',
    'packages/*/src/**/*.zig',
    'packages/*/examples/**/*.zig',
    'packages/*/tests/**/*.zig',
    'legacy/build.zig',
    'legacy/build.zig.zon',
    'legacy/src/**/*.zig',
    'legacy/tests/**/*.zig'
]

function rxFiles(pattern) {
    return execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', pattern], {
        encoding: 'utf8',
        maxBuffer: Infinity
    })
        .split('\0')
        .filter(file => file && existsSync(file))
}

const files =
    requested_files.length > 0 ? requested_files : [...(rx_only ? [] : globSync(zig_patterns)), ...rxFiles('*.rx')]
const rx_fixtures = new Set(rxFiles(':(attr:-zxc-format)*.rx').map(file => resolve(file)))
const local_zxc = resolve('zig-out', 'bin', process.platform === 'win32' ? 'zxc.exe' : 'zxc')
const zxc = process.env.ZXC || (existsSync(local_zxc) ? local_zxc : 'zxc')
let spacer

try {
    for (const file of files) {
        if (file.endsWith('.zx')) continue
        if (file.endsWith('.rx') && rx_fixtures.has(resolve(file))) continue

        const source = await readFile(file, 'utf8')
        let text

        if (file.endsWith('.rx')) {
            text = execFileSync(zxc, ['fmt', file], {
                encoding: 'utf8',
                maxBuffer: Infinity,
                stdio: ['ignore', 'pipe', 'inherit']
            })
        } else {
            spacer ??= await createSpacer()
            text = (await spacer.format(source)).text
        }

        if (text === source) continue

        console.log(file)

        if (check_only) {
            process.exitCode = 1
        } else {
            await writeFile(file, text)
        }
    }
} finally {
    await spacer?.destroy()
}
