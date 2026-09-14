/**
 * 测试宿主与 guard.ps1 的集成点：用与 lib/index.js 完全相同的参数拼接 spawn 一次，
 * 确认能拿到合法 JSON。
 *
 * 为什么单独测这一步：宿主不解析 stdout（日志噪音会毁掉 JSON），而是让脚本把结果
 * 写进临时文件再读 —— 参数拼接错一个字母就会静默失败。
 *
 * 注意 stdio 用 'ignore'：受限环境下 Node 用默认的 'pipe' 抓子进程输出会 EPERM，
 * 'ignore' / 'inherit' 不受影响（这是本机实测过的沙箱特性）。
 */
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// 路径从本文件位置推导（tools/ 的上一级就是插件根）：
// 这样换台机器也能跑，而且不会把作者的绝对路径写进公开仓库（公开前审计抓到过）。
const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const GUARD_PS1 = join(PLUGIN_ROOT, 'lib', 'guard.ps1')
const TEST_HOME = join(PLUGIN_ROOT, '_testhome')
const action = process.argv[2] || 'status'

const workDir = mkdtempSync(join(tmpdir(), 'dsh-guard-test-'))
const outFile = join(workDir, 'result.json')

const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', GUARD_PS1,
    '-Action', action, '-Out', outFile,
    '-Profile', 'web', '-WebPort', '3080',
    '-GuardHomeDir', TEST_HOME]
if (process.argv[3]) { args.push('-Id', process.argv[3]) }

console.log('spawn: powershell.exe ' + args.join(' '))

const child = spawn('powershell.exe', args, { windowsHide: true, stdio: 'ignore' })
child.on('error', (e) => { console.log('❌ spawn 失败: ' + e.message); process.exit(1) })
child.on('close', (code) => {
    console.log('退出码: ' + code)
    try {
        const body = JSON.parse(readFileSync(outFile, 'utf8'))
        console.log('✓ 拿到合法 JSON：')
        console.log('  ok=' + body.ok + '  action=' + body.action)
        if (body.profile) console.log('  profile=' + body.profile + '  guardHome=' + body.guardHome)
        if (body.watchdog) console.log('  看门狗在跑=' + body.watchdog.running)
        if (body.snapshots) console.log('  快照数=' + body.snapshots.length)
        if (body.error) console.log('  error=' + body.error)
        console.log('  （完整结果 ' + JSON.stringify(body).length + ' 字节）')
    } catch (e) {
        console.log('❌ 读不到/解析不了结果 JSON: ' + e.message)
    }
    try { rmSync(workDir, { recursive: true, force: true }) } catch { }
})
