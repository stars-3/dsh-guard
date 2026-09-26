/**
 * test-client-load.mjs —— 没有浏览器也能验客户端 bundle 不自爆。
 *
 * 为什么需要它：面板是用户唯一会看的界面，但它只能在浏览器里跑；改一行 JS 写错，
 * 症状是"设置页这个 Tab 直接不见了"，而且在 DSH 日志里几乎看不到线索。
 * 这里用假 window / 假 require('react') / 假 ctx 把 bundle 完整走一遍：
 *   ① bundle 结构对不对（__ModuleLoader__.load + factory(require)）
 *   ② apply(ctx) 有没有把 Tab 注册到 settings.plugins.tab
 *   ③ 组件能不能**带着真实形状的 status 数据渲染出一棵树**（含回滚按钮）
 *
 * 用法： node tools/test-client-load.mjs
 */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const code = readFileSync(join(here, '..', 'client', 'client.js'), 'utf8')
const pkgName = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8')).name

let failed = false
const fail = (m) => { console.error('✗ ' + m); failed = true }

// ---- 假 window：抓 bundle ----
let bundle = null
const fakeWindow = { __ModuleLoader__: { load(b) { bundle = b } } }

// ---- 假 react：createElement 造树；useEffect 不执行（不触发 fetch） ----
function createElement(type, props, ...children) {
    return { type, props: props || {}, children: children.flat(Infinity).filter((c) => c !== null && c !== undefined && c !== false) }
}

// 组件里第一个 useState 是 status。这里让它直接拿到一份"真实形状"的状态，
// 这样能渲染出完整面板（否则只有加载态，测不到回滚按钮）。
const FAKE_STATUS = {
    ok: true, profile: 'web', profileExists: true, profileDir: 'C:\\x\\.dsh\\profiles\\web',
    guardHome: 'C:\\x\\.dsh-guard', snapshotCount: 2,
    web: { port: 3999, portFrom: 'explicit', portSource: 'request', url: 'http://127.0.0.1:3999', listening: true },
    watchdog: { running: false, pid: 0 },
    profileIdentity: { hash: '2B02B72799FB', depCount: 3, bundles: ['dsh-guard'] },
    lastIncident: null,
    snapshots: [
        { name: '20260914-100447_live-rollback-test', reason: 'manual', createdAt: '2026-09-14 10:04:47', sizeMB: 1.92, hash: '2B02B72799FB', depCount: 3, label: 'live-rollback-test' },
        { name: '20260914-095206_pre-plugin-install', reason: 'manual', createdAt: '2026-09-14 09:52:06', sizeMB: 1.8, hash: '0A0FCE455933', depCount: 1, label: 'pre-plugin-install' },
    ],
}
let useStateSeq = 0
const react = {
    createElement,
    useState: (init) => [useStateSeq++ === 0 ? FAKE_STATUS : init, () => { }],
    useEffect: () => { },
    useCallback: (fn) => fn,
    useMemo: (fn) => fn(),
    useRef: (init) => ({ current: init }),
}
const fakeRequire = (name) => {
    if (name === 'react') return react
    throw new Error('bundle require() 了未预期的模块: ' + name)
}

// ---- 加载 bundle（client.js 是引用 window/require 的普通脚本）----
try {
    new Function('window', 'require', code)(fakeWindow, fakeRequire)
} catch (e) {
    fail('bundle 执行抛异常: ' + ((e && e.stack) || e))
}

if (!bundle) {
    fail('没有调用 window.__ModuleLoader__.load()')
} else {
    console.log('bundle id:', bundle.id)
    // 契约（账本 E80）：客户端 bundle 自报的 id 必须等于包名 —— 官方端按包名注册进客户端图，
    // 加载后断言「这个 id 注册过」，不一致就抛 loaded without registering → 面板不挂载。
    if (!bundle.id) fail('bundle 缺少 id')
    else if (bundle.id !== pkgName) fail('bundle id 必须等于包名: ' + bundle.id + ' vs ' + pkgName)
    if (typeof bundle.factory !== 'function') fail('bundle 缺少 factory')

    const mod = bundle.factory(fakeRequire)
    console.log('exports.name  :', mod.name)
    console.log('exports.inject:', JSON.stringify(mod.inject))
    if (typeof mod.apply !== 'function') fail('exports.apply 不是函数')
    // ⚠️ exports.inject 里必须是 **Cordis 服务名**，绝不能是包名 —— 这是 2026-09-14 真机白屏
    //    事故的根因：写成 ['@deepseek-ai/dsh-client-ui-settings'] 会让客户端插件去等一个
    //    永远不存在的服务，插件加载失败 → 桌面端白屏、网页端报错。
    //    包名属于 package.json 的 dsh.client.inject（下面也一并钉住）。
    //    ⚠️ 这条断言以前写的是"必须包含 @deepseek-ai/..."——那是把 bug 当成了期望值，
    //       比没有测试更坏：测试跟着 bug 走，就永远不会报错。
    if (!Array.isArray(mod.inject)) fail('exports.inject 不是数组')
    else {
        for (const s of mod.inject) {
            if (typeof s !== 'string' || s.includes('@') || s.includes('/')) {
                fail(`exports.inject 里混进了包名（这里只写服务名）: ${JSON.stringify(s)}`)
            } else {
                console.log('  ✓ inject 服务名:', s)
            }
        }
        if (!mod.inject.includes('slots')) fail('面板用了 ctx.slots，exports.inject 里必须有 "slots"')
    }

    // package.json 那一侧：包名放这里
    const pkg = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8'))
    const pkgInject = (pkg.dsh && pkg.dsh.client && pkg.dsh.client.inject) || []
    console.log('package.json dsh.client.inject:', JSON.stringify(pkgInject))
    if (!pkgInject.includes('@deepseek-ai/dsh-client-ui-settings')) {
        fail('package.json 的 dsh.client.inject 应列出 @deepseek-ai/dsh-client-ui-settings（Tab 归属的设置页插件）')
    }
    if (!pkg.dsh || !pkg.dsh.client || pkg.dsh.client.platform !== 'web') fail('package.json 的 dsh.client.platform 应为 web')
    if (!pkg.dsh || !pkg.dsh.bundle || !pkg.dsh.bundle.patch) fail('package.json 缺少 dsh.bundle.patch（宿主侧不会加载）')

    // ---- 假 ctx：抓 Tab 注册 ----
    const registered = []
    const ctx = {
        slots: {
            inject(name, run) {
                if (name !== 'settings.plugins.tab') fail('slots.inject 的名字不对: ' + name)
                run()
            },
            register(spec, component) { registered.push({ spec, component }) },
        },
    }
    try { mod.apply(ctx) } catch (e) { fail('apply(ctx) 抛异常: ' + ((e && e.message) || e)) }

    if (registered.length !== 1) fail('应该正好注册 1 个 Tab，实际 ' + registered.length)
    else {
        const { spec, component } = registered[0]
        console.log('Tab:', JSON.stringify({ id: spec.id, order: spec.order, label: spec.label(), name: spec.name }))
        if (spec.name !== 'settings.plugins.tab') fail('Tab 的 name 不是 settings.plugins.tab')
        if (!spec.id) fail('Tab 缺 id')
        if (typeof component !== 'function') fail('Tab 组件不是函数')

        // ---- 渲染成树，再把文本抠出来断言 ----
        let tree = null
        try { tree = component({}) } catch (e) { fail('组件渲染抛异常: ' + ((e && e.stack) || e)) }
        if (tree) {
            const texts = []
            const walk = (n) => {
                if (n == null || typeof n === 'boolean') return
                if (typeof n === 'string' || typeof n === 'number') { texts.push(String(n)); return }
                if (Array.isArray(n)) { n.forEach(walk); return }
                if (n.children) n.children.forEach(walk)
            }
            walk(tree)
            const all = texts.join('\n')
            const want = ['守护', 'DSH 网页端', '3999', '来自当前页面', '回滚到此快照', '＋ 打一个快照',
                '快照（2 个', '看门狗未运行', '清理旧快照', '独立窗口']
            // 反向断言：看门狗的安装/卸载**故意不在面板里**（2026-09-14 用户要求删掉：
            // 它们要注册计划任务/写启动文件夹，属于系统级改动，统一放到独立窗口做）。
            // 这里钉住这个决定，免得以后又被加回来。
            for (const gone of ['安装看门狗', '停止并卸载看门狗']) {
                if (all.indexOf(gone) >= 0) fail(`面板里不该再有「${gone}」按钮 —— 它已经搬到独立窗口了`)
            }
            for (const w of want) {
                if (all.indexOf(w) < 0) fail(`渲染结果里找不到「${w}」`)
                else console.log('  ✓ 渲染包含:', w)
            }
            if (all.indexOf('20260914-100447_live-rollback-test') < 0) fail('快照列表没渲染出快照名')
        }
    }
}

console.log(failed ? '\n结论：客户端 bundle 有问题' : '\n结论：OK —— bundle 结构、Tab 注册、组件渲染都正常')
process.exit(failed ? 1 : 0)
