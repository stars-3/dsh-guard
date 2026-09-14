/**
 * dsh-guard —— 宿主侧入口。
 *
 * 职责很薄：往 DSH 的 web 服务上挂 5 条**同源路由**，供设置页的「守护」面板调用。
 * 真正干活的是 lib/guard.ps1（spawn 一个 PowerShell，结果用临时 JSON 文件回传，
 * 不解析 stdout —— 那样会被日志噪音干扰）。
 *
 * 为什么状态要写文件而不是走 stdout：guard-core.ps1 里的 Write-GuardLog 会往日志
 * 和控制台写东西，把它混进 stdout 会让 JSON 解析变得脆弱。
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-guard'

const HERE = dirname(fileURLToPath(import.meta.url))
const GUARD_PS1 = join(HERE, 'guard.ps1')
const BASE = '/dsh-guard'
const PS_TIMEOUT_MS = 180000

function log(...args) {
    try { console.log('[dsh-guard]', ...args) } catch { }
}

function sendJson(response, code, body) {
    let text
    try { text = JSON.stringify(body) } catch (e) { text = JSON.stringify({ ok: false, error: '结果无法序列化: ' + e.message }) }
    try {
        response.writeHead(code, {
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': 'no-store',
        })
        response.end(text)
    } catch (e) { /* 连接已断，忽略 */ }
}

/** 写操作要求同源：面板是同源 fetch，但别的页面不该能驱动回滚。 */
function isSameOrigin(request) {
    const origin = request.headers && request.headers.origin
    if (!origin) return true                       // 同源 GET 可能不带 Origin
    try {
        return new URL(origin).host === (request.headers.host || '')
    } catch { return false }
}

function powershellExe() {
    // 默认 5.1（Windows 一定有）；装了 pwsh 想用 7 可以设 DSH_GUARD_POWERSHELL=pwsh.exe
    return process.env.DSH_GUARD_POWERSHELL || 'powershell.exe'
}

/** 面板请求的 Host 头里的端口 —— 这就是"用户此刻正看着的那一端"。 */
function portFromHostHeader(request) {
    const host = (request && request.headers && request.headers.host) || ''
    const m = /:(\d+)\s*$/.exec(host)
    return m ? Number(m[1]) : 0
}

/** DSH 会把自己的端口导出成 DSH_WEB_URL —— 但它会**泄漏给子实例**，所以只当兜底。 */
function portFromEnv() {
    const m = /:(\d+)/.exec(process.env.DSH_WEB_URL || '')
    return m ? Number(m[1]) : 0
}

/**
 * 跑一次 guard.ps1，返回它写出的 JSON 对象。
 * @param {'status'|'list'|'snapshot'|'rollback'|'incidents'} action
 */
function runGuard(action, opts = {}) {
    const { profile = 'web', id = '', reason = '', guardHome = '', webPort = 3080 } = opts
    return new Promise((resolve) => {
        if (!existsSync(GUARD_PS1)) {
            resolve({ ok: false, error: `找不到 ${GUARD_PS1}` })
            return
        }
        let tmpDir
        try { tmpDir = mkdtempSync(join(tmpdir(), 'dsh-guard-')) }
        catch (e) { resolve({ ok: false, error: '建临时目录失败: ' + e.message }); return }
        const outFile = join(tmpDir, 'result.json')

        const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', GUARD_PS1,
            '-Action', action, '-Out', outFile,
            '-Profile', profile, '-WebPort', String(webPort)]
        if (id) args.push('-Id', id)
        if (reason) args.push('-Reason', reason)
        if (guardHome) args.push('-GuardHomeDir', guardHome)

        let child
        try {
            child = spawn(powershellExe(), args, { windowsHide: true, stdio: 'ignore' })
        } catch (e) {
            resolve({ ok: false, error: '启动 PowerShell 失败: ' + e.message })
            return
        }

        let settled = false
        const finish = (body) => {
            if (settled) return
            settled = true
            clearTimeout(timer)
            try { rmSync(tmpDir, { recursive: true, force: true }) } catch { }
            resolve(body)
        }
        const timer = setTimeout(() => {
            try { child.kill() } catch { }
            finish({ ok: false, error: `guard.ps1 ${action} 超时（${PS_TIMEOUT_MS / 1000}s）` })
        }, PS_TIMEOUT_MS)

        child.on('error', (e) => finish({ ok: false, error: '启动 PowerShell 失败: ' + e.message }))
        child.on('close', () => {
            let body
            try { body = JSON.parse(readFileSync(outFile, 'utf8')) }
            catch (e) {
                body = { ok: false, error: '读不到结果 JSON —— 脚本可能崩了，看 ~/.dsh-guard/logs/guard.log' }
            }
            finish(body)
        })
    })
}

/**
 * 跑一个"改动系统"的脚本（装 / 卸看门狗）。**等它结束，并回报真实结果**。
 *
 * 为什么改名后还叫 runDetached：它的子进程确实不再挂在 DSH 的请求上（看门狗要活得比 DSH 久），
 * 但**调用方必须拿到真实成败** —— 失败必须能看见，这是 2026-09-14 那次的教训。
 *
 * 装计划任务需要管理员权限（会弹 UAC）；脚本被拒时用退出码 3 表示，
 * 调用方据此改用启动文件夹方式（见下面的路由）。
 *
 * ⚠️ 参数集必须和 install-watchdog.ps1 / uninstall-watchdog.ps1 的 param 块**保持一致**：
 *    少一个参数，PowerShell 会在参数绑定阶段直接退出 1，脚本一行都不执行。
 */
function runDetached(scriptName, opts = {}) {
    const { profile = 'web', guardHome = '', webPort = 3080, workDir = '', extra = [] } = opts
    const target = join(HERE, scriptName)
    if (!existsSync(target)) return Promise.resolve({ ok: false, error: `找不到 ${target}` })
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', target,
        '-Profile', profile, '-WebPort', String(webPort), ...extra]
    if (guardHome) args.push('-GuardHomeDir', guardHome)
    if (workDir) args.push('-WorkDir', workDir)

    // ⚠️ 必须**等它结束并回报真实退出码**，不能"起了就不管 + 无条件 ok:true"。
    //    2026-09-14 实测踩到：uninstall-watchdog.ps1 少一个 -WebPort 参数，PowerShell 在
    //    **参数绑定阶段**就退出 1、脚本一行都没执行，而这里照样返回 ok:true ——
    //    界面上显示"已启动"，用户点了没反应，谁也查不出原因。
    //    现在把 stdout/stderr 一起带回去，失败时给出可操作的提示。
    return new Promise((resolve) => {
        let child
        try {
            child = spawn(powershellExe(), args, { windowsHide: true })
        } catch (e) {
            resolve({ ok: false, error: '启动失败: ' + e.message })
            return
        }
        let out = ''
        let errOut = ''
        let done = false
        const finish = (r) => { if (!done) { done = true; resolve(r) } }
        const timer = setTimeout(() => {
            try { child.kill() } catch { }
            finish({ ok: false, error: `超时（120s）—— 若弹了 UAC，可能是没人点它` })
        }, 120000)

        if (child.stdout) child.stdout.on('data', (d) => { out += d })
        if (child.stderr) child.stderr.on('data', (d) => { errOut += d })
        child.on('error', (e) => { clearTimeout(timer); finish({ ok: false, error: '启动失败: ' + e.message }) })
        child.on('close', (code) => {
            clearTimeout(timer)
            const text = (out + (errOut ? '\n[stderr]\n' + errOut : '')).trim()
            log(`${scriptName} 结束，退出码 ${code}`)
            finish({
                ok: code === 0,
                code,
                output: text.slice(-4000),
                error: code === 0 ? undefined : `退出码 ${code}`,
                // 3 = 计划任务需要管理员权限（脚本自己约定的退出码）
                hint: code === 3 ? '计划任务需要管理员权限。可以改用启动文件夹方式（不需要管理员）：本按钮会自动重试一次。' : undefined,
            })
        })
    })
}

export function apply(ctx, config = {}) {
    const profile = config.profile ?? 'web'
    const guardHome = config.guardHome ?? ''
    const cfgPort = Number(config.webPort ?? 0) || 0     // 显式配置 = 用户意图，最优先
    const workDir = config.workDir ?? ''

    /**
     * 这次调用该盯哪个端口。
     *
     * 优先级：配置里写死的 > **这个请求的 Host 头** > 环境变量 DSH_WEB_URL > 3080。
     *
     * 为什么 Host 头比环境变量可靠（2026-09-14 真启动实测踩到）：
     *  DSH 会把 DSH_WEB_URL 导出给**自己整个进程树**，于是第二个实例会继承第一个实例
     *  的端口 —— 实测实例起在 3999，status 却报 3101 而且 listening=true（探的是别人，
     *  纯假阳性；看门狗照着这个走会以为 DSH 死了，反复重启甚至回滚）。
     *  而 Host 头是"用户此刻正看着的那一端"，永远是对的。
     */
    const portFor = (request) => {
        if (cfgPort) return { port: cfgPort, from: 'config' }
        const fromHost = portFromHostHeader(request)
        if (fromHost) return { port: fromHost, from: 'request' }
        const fromEnv = portFromEnv()
        if (fromEnv) return { port: fromEnv, from: 'env' }
        return { port: 3080, from: 'default' }
    }
    const commonFor = (request) => ({ profile, guardHome, webPort: portFor(request).port })
    const commonAllFor = (request) => ({ ...commonFor(request), workDir })

    ctx.inject(['webServer'], (host) => {
        const routes = [
            {
                path: BASE + '/status', method: 'GET',
                run: async (_body, request) => {
                    const result = await runGuard('status', commonFor(request))
                    // 把"宿主认为端口是哪来的"一并带出去，面板上看得见（PS 那边只有 explicit/env/default）
                    if (result && result.web) result.web.portSource = portFor(request).from
                    return result
                },
            },
            {
                path: BASE + '/list', method: 'GET',
                run: (_body, request) => runGuard('list', commonFor(request)),
            },
            {
                path: BASE + '/incidents', method: 'GET',
                run: (_body, request) => runGuard('incidents', commonFor(request)),
            },
            {
                path: BASE + '/prune', method: 'POST',
                run: (_body, request) => runGuard('prune', commonFor(request)),
            },
            {
                path: BASE + '/snapshot', method: 'POST',
                run: (body, request) => runGuard('snapshot', { ...commonFor(request), reason: (body && body.reason) || 'manual' }),
            },
            {
                path: BASE + '/rollback', method: 'POST',
                run: (body, request) => runGuard('rollback', { ...commonFor(request), id: (body && body.id) || '' }),
            },
            {
                path: BASE + '/watchdog/install', method: 'POST',
                run: async (_body, request) => {
                    // 看门狗是计划任务/启动项，登录时启动，那时环境里没有 DSH_WEB_URL，
                    // 端口只能烘死 —— 所以必须把"用户正看着的那一端"的端口传下去。
                    const opts = commonAllFor(request)
                    log(`安装看门狗：端口 ${opts.webPort}（来源 ${portFor(request).from}）`)
                    let r = await runDetached('install-watchdog.ps1', opts)
                    // 计划任务需要管理员权限；被拒（退出码 3）就**自动**改用启动文件夹方式，
                    // 别让用户卡在 UAC 上 —— 那正是"点了没反应"的来源之一。
                    if (!r.ok && r.code === 3) {
                        log('计划任务被拒 → 自动改用启动文件夹方式重试')
                        const r2 = await runDetached('install-watchdog.ps1', { ...opts, extra: ['-UseStartup'] })
                        r = Object.assign({}, r2, { triedStartup: true, firstOutput: r.output })
                    }
                    return r
                },
            },
            {
                path: BASE + '/watchdog/uninstall', method: 'POST',
                run: (_body, request) => runDetached('uninstall-watchdog.ps1', commonAllFor(request)),
            },
        ]

        const readBody = (request) => new Promise((resolve) => {
            let raw = ''
            request.on('data', (chunk) => {
                raw += chunk
                if (raw.length > 64 * 1024) { raw = ''; request.destroy() }   // 我们只需要 id/reason
            })
            request.on('end', () => {
                if (!raw) { resolve({}); return }
                try { resolve(JSON.parse(raw)) } catch { resolve({}) }
            })
            request.on('error', () => resolve({}))
        })

        const disposers = routes.map((route) => host.webServer.register({
            kind: 'exact',
            path: route.path,
            handler: async (request, response) => {
                if (request.method !== route.method) {
                    sendJson(response, 405, { ok: false, error: `本路由只接受 ${route.method}` })
                    return
                }
                if (route.method === 'POST' && !isSameOrigin(request)) {
                    sendJson(response, 403, { ok: false, error: '只接受同源请求' })
                    return
                }
                const body = route.method === 'POST' ? await readBody(request) : {}
                let result
                try { result = await route.run(body, request) }
                catch (e) { result = { ok: false, error: String(e && e.message || e) } }
                sendJson(response, 200, result)
            },
        }))

        host.effect(() => () => {
            for (const d of disposers) { try { if (typeof d === 'function') d() } catch { } }
        }, 'dsh-guard: http routes')
    })

    log(`已挂载 ${BASE}/*（profile=${profile}，端口按「配置 > 请求 Host 头 > DSH_WEB_URL > 3080」解析）`)
}
