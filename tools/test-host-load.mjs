/**
 * test-host-load.mjs —— 不启动 DSH，直接验证 lib/index.js 能不能加载、挂路由、按端口解析。
 *
 * 为什么需要它：`node --check` 只看语法，看不出运行期错误；而在 DSH 里插件加载失败的表现
 * 是"页面起不来/白屏"，node 的日志又常被管道缓冲吞掉，很难定位。这里用假 ctx + 假请求
 * 把宿主逻辑跑一遍，几秒钟给出确定答案。
 *
 * 覆盖两件事：
 *   ① apply() 不抛异常，7 条路由都以 {kind:'exact', path, handler} 注册成功
 *   ② handler 真被调用时，端口取的是**请求 Host 头**（而不是环境里可能属于别的实例的
 *      DSH_WEB_URL）—— 这是 2026-09-14 真启动实测发现的 bug，必须钉住
 *
 * 用法（建议指向影子环境，不要碰真 profile）：
 *   $env:DSH_HOME='...\_shadow\.dsh'; $env:DSHGUARD_HOME='...\_shadow\guardhome'
 *   node tools/test-host-load.mjs
 */
import { apply, name } from '../lib/index.js'

const routes = []
const effects = []

const fakeHost = {
    webServer: {
        register(route) { routes.push(route); return () => { } },
    },
    effect(fn, label) { effects.push(label ?? '(no label)'); fn(); return () => { } },
}

const ctx = {
    inject(services, run) {
        if (!services.includes('webServer')) throw new Error('测试桩只提供 webServer')
        run(fakeHost)
    },
    get: () => undefined,
    on: () => { },
}

let failed = false
const fail = (msg) => { console.error('✗ ' + msg); failed = true }

try {
    apply(ctx, { profile: 'web' })
} catch (e) {
    failed = true
    console.error('✗ apply() 抛异常：', (e && e.stack) || e)
}

console.log('插件名:', name)

const expected = ['/dsh-guard/status', '/dsh-guard/list', '/dsh-guard/incidents',
    '/dsh-guard/snapshot', '/dsh-guard/rollback',
    '/dsh-guard/watchdog/install', '/dsh-guard/watchdog/uninstall']
const got = routes.map((r) => r.path)

// ① 形状与齐全性
//    ⚠️ register() 收到的是 { kind, path, handler } —— 不是路由表里那个 { path, method, run }。
//       第一版测试就是在这里断言错了形状，白报一堆"缺少 run()"（假失败）。
for (const r of routes) {
    if (r.kind !== 'exact') fail(`kind 不是 exact: ${r.path}`)
    if (typeof r.handler !== 'function') fail(`handler 不是函数: ${r.path}`)
    else if (r.handler.length < 2) fail(`handler(request, response) 形参不足: ${r.path}`)
}
const missing = expected.filter((p) => !got.includes(p))
if (missing.length) fail('少挂了路由: ' + missing.join(', '))
console.log(`路由 ${routes.length} 条：`, got.join(', '))
console.log('effect:', effects)

// ② 端口解析：拿 status 的 handler 真跑一次，Host 头写成一个**不同于环境变量**的端口。
//    环境里 DSH_WEB_URL 若存在（通常是 3101），解析结果仍必须是 Host 头里那个。
const statusRoute = routes.find((r) => r.path === '/dsh-guard/status')
if (statusRoute) {
    const WANT = 3999
    const response = {
        code: 0, body: '',
        writeHead(code) { this.code = code },
        end(text) { this.body = text },
    }
    const request = { method: 'GET', headers: { host: `127.0.0.1:${WANT}` }, on: () => { } }
    await statusRoute.handler(request, response)
    let json = null
    try { json = JSON.parse(response.body) } catch { fail('status 没返回合法 JSON: ' + response.body.slice(0, 200)) }
    if (json) {
        console.log(`\nstatus（Host: 127.0.0.1:${WANT}）:`, JSON.stringify({
            ok: json.ok, error: json.error,
            web: json.web, guardHome: json.guardHome,
            profileDir: json.profileDir, snapshotCount: json.snapshotCount,
        }, null, 2))
        if (json.ok !== true) fail('status 里 ok 不是 true：' + (json.error || ''))
        if (json.web && json.web.port !== WANT) fail(`端口解析错了：期望 ${WANT}，实际 ${json.web && json.web.port}（环境里 DSH_WEB_URL=${process.env.DSH_WEB_URL || '(空)'}）`)
        if (json.web && json.web.portSource !== 'request') fail(`portSource 应为 request，实际 ${json.web && json.web.portSource}`)
        const arr = Array.isArray(json.snapshots)
        console.log('snapshots 是数组吗:', arr)
        if (!arr) fail('snapshots 不是数组（面板会显示 0 个快照）')
    }
}

if (failed) { console.error('\n结论：有问题'); process.exit(1) }
console.log('\n结论：OK —— 加载、路由、端口解析、JSON 形状全部符合预期')
