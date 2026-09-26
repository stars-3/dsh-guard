/**
 * test-packaging.mjs —— 包名契约自检（把账本 E80 那两处钉在仓库里）
 *
 * 改包名时要一起改的两处，漏一处就是「服务端全绿、界面全坏」：
 *   ① cordis.patch.yml 里 insert 的 `name`（**模块说明符**）= 包名
 *      → 漏了：DSH 只按包名把 bundle 链进模块回退目录，插件加载不了（路由 404、面板不挂载）；
 *        旧目录还在的机器上更阴——它会**静默加载旧代码**。
 *   ② client/*.js 里 `window.__ModuleLoader__.load({ id })` = 包名
 *      → 漏了：官方端按包名注册并断言，抛 `loaded without registering "<pkg>"`，
 *        面板不挂载、客户端 CSS 注入失效（服务端却一切正常）。
 *
 * 用法： node tools\test-packaging.mjs
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')

let fails = 0
const results = []
function check(what, ok, detail) {
    results.push((ok ? '  OK   ' : '  FAIL ') + what + (detail ? '  → ' + detail : ''))
    if (!ok) fails++
}

const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
const pkgName = pkg.name

// ① bundle patch
const patchRel = pkg.dsh && pkg.dsh.bundle && pkg.dsh.bundle.patch
check('package.json 声明 dsh.bundle.patch', !!patchRel, patchRel || '(missing)')
if (patchRel) {
    const lines = readFileSync(join(root, patchRel), 'utf8').split(/\r?\n/)
    const names = []
    for (let i = 0; i < lines.length; i++) {
        if (!/^\s*-\s*id:/.test(lines[i])) continue
        for (let j = i + 1; j < Math.min(i + 4, lines.length); j++) {
            const m = /^\s*name:\s*['"]?([^'"\s]+)['"]?\s*$/.exec(lines[j])
            if (m) { names.push(m[1]); break }
        }
    }
    check('patch 至少 insert 一个条目', names.length > 0, names.join(', '))
    for (const n of names) {
        const isPath = /^(\.{1,2}[\\/]|[A-Za-z]:[\\/]|\/)/.test(n)
        check('insert.name == 包名', isPath || n === pkgName, isPath ? (n + '（路径写法，按 patch 位置锚定）') : (n === pkgName ? n : (n + ' vs 包名 ' + pkgName)))
    }
}

// ② client bundle 自报 id
const exp = pkg.exports && pkg.exports['./client']
const clientRel = typeof exp === 'string' ? exp : (exp && exp.default)
if (!clientRel) {
    check('exports["./client"] 存在', true, '（服务端插件可以没有，跳过）')
} else {
    const text = readFileSync(join(root, clientRel), 'utf8')
    const m = /__ModuleLoader__\.load\(\s*\{\s*(?:(?:\/\/|#)[^\n]*\n\s*)*id:\s*['"]([^'"]+)['"]/.exec(text)
    check('存在 __ModuleLoader__.load({ id })', !!m, m ? m[1] : '(not found)')
    check('client bundle id == 包名', !!m && m[1] === pkgName, m ? (m[1] === pkgName ? m[1] : (m[1] + ' vs 包名 ' + pkgName)) : '')
}

console.log('=== test-packaging (' + pkgName + '@' + pkg.version + ') ===')
for (const r of results) console.log(r)
console.log('')
console.log('结论：' + (fails ? ('有 ' + fails + ' 项失败') : ('全部通过（' + results.length + ' 项）')))
process.exit(fails ? 1 : 0)
