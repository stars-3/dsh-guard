/**
 * dsh-guard —— 客户端（设置页里的「守护」面板）
 *
 * 加载形状照抄 dsh-plugin-group-tools（已验证可用）：
 *   window.__ModuleLoader__.load({ id, factory: (require) => { ...; return module.exports } })
 * 工厂里自己造 module/exports，最后把 apply / inject / name 挂在 exports 上。
 *
 * 面板做的事：
 *   读  GET  /dsh-guard/status    -> 守护状态 / profile 指纹 / 快照列表 / 最近事故
 *   写  POST /dsh-guard/snapshot  -> 手动打一个快照
 *   写  POST /dsh-guard/rollback  -> 【回滚到此快照】（两步确认，防误点）
 *
 * 为什么回滚要两步确认：它会覆盖 profile 的 package.json / 锁文件 / cordis.patch.yml，
 * 并需要重启 DSH 才生效 —— 不可轻点。
 */
window.__ModuleLoader__.load({
  // ⚠️ 必须等于**包名**（dsh-guard-desktop）：官方端按包名把这一行注册进客户端图，
  //    加载后还会断言「这个 id 注册过」——不一致就抛
  //    `loaded without registering "<pkg>" via __ModuleLoader__.load`，
  //    结果是面板不挂载（2026-09-26 真机报错，账本 E80）。
  id: 'dsh-guard-desktop',

  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    var NS = 'dsh-guard'
    var name = NS
    // ⚠️ exports.inject 里列的是 **Cordis 服务名**，不是包名！
    //
    //  2026-09-14 真机事故：这里原来写的是 ['@deepseek-ai/dsh-client-ui-settings']（包名），
    //  于是客户端插件去等一个**永远不存在的服务** → 插件加载失败 → 界面白屏。
    //
    //  权威对照（官方 dsh-client-ui-settings-plugin-inventory 的 lib/client.js）：
    //      const inject = ["slots", "locale", "remote", "remote.pluginInventory"];
    //  包名要放在 **package.json 的 dsh.client.inject**（那里本来写对了），bundle 里只写服务名。
    //  本面板用到 ctx.slots（挂设置页 Tab），所以是 "slots"。
    var inject = ['slots']

    var React = require('react')
    var h = React.createElement

    // ---------------------------------------------------------------- 样式
    var C = {
      card: { border: '1px solid var(--dsw-alias-border-l2, #3a3f46)', borderRadius: 10, padding: '14px 16px', marginBottom: 12 },
      h2: { margin: '0 0 10px', fontSize: 15, fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
      row: { display: 'flex', justifyContent: 'space-between', gap: 12, padding: '4px 0', fontSize: 13 },
      k: { color: 'var(--dsw-alias-label-secondary, #9aa0a6)', flex: '0 0 auto' },
      v: { color: 'var(--dsw-alias-label-primary, inherit)', textAlign: 'right', wordBreak: 'break-all' },
      btn: { padding: '6px 12px', borderRadius: 6, border: '1px solid var(--dsw-alias-border-l2, #3a3f46)', background: 'transparent', color: 'inherit', cursor: 'pointer', fontSize: 13 },
      // ⚠️ 主按钮的底色与文字色都必须**写明确颜色**，不能用主题变量。
      //    2026-09-14 真机实测：浅色主题下 var(--dsw-alias-brand-primary) 解析成**浅色**，
      //    而文字是硬写的 #fff → 白底白字，按钮变成一块"空白方块"（用户原话：「怪怪的」）。
      //    这类"看着渲染成功了、其实文字看不见"的问题，只有真人肉眼能发现。
      btnPrimary: { padding: '6px 14px', borderRadius: 6, border: '1px solid #2f6fed', background: '#2f6fed', color: '#ffffff', cursor: 'pointer', fontSize: 13, fontWeight: 600 },
      btnDanger: { padding: '4px 10px', borderRadius: 6, border: '1px solid #b3261e', background: 'transparent', color: '#d93025', cursor: 'pointer', fontSize: 12, whiteSpace: 'nowrap' },
      btnConfirm: { padding: '4px 10px', borderRadius: 6, border: '1px solid transparent', background: '#b3261e', color: '#ffffff', cursor: 'pointer', fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap' },
      snap: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, padding: '8px 0', borderTop: '1px solid var(--dsw-alias-border-l1, #2b2f36)', fontSize: 13 },
      mono: { fontFamily: 'ui-monospace, Consolas, monospace', fontSize: 12 },
      // 语义色也用中间调：浅色主题下要有对比、深色主题下也不能糊成一团
      ok: { color: '#2e9e4f' }, bad: { color: '#d93025' }, warn: { color: '#b7791f' },
      msg: { marginTop: 10, padding: '8px 10px', borderRadius: 6, fontSize: 12, background: 'var(--dsw-alias-bg-layer-2, rgba(255,255,255,.04))', whiteSpace: 'pre-wrap' },
      hint: { fontSize: 12, color: 'var(--dsw-alias-label-tertiary, #8b9098)', marginTop: 6, lineHeight: 1.6 },
    }

    function api(path, body) {
      var opt = body
        ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
        : undefined
      return fetch(path, opt).then(function (r) {
        if (!r.ok) throw new Error(path + ' -> HTTP ' + r.status)
        return r.json()
      })
    }

    // 端口是从哪来的，必须写在脸上。
    // DSH 会把 DSH_WEB_URL 导出给它**自己的整个进程树**，所以第二个实例可能继承第一个
    // 实例的端口；猜错的症状不是报错，而是"看门狗盯了个没人监听的端口 → 以为 DSH 死了 →
    // 反复重启甚至回滚"。光看一个端口号分辨不出来（2026-09-14 真启动实测踩到）。
    var PORT_SOURCE_TEXT = {
      config: '（来自插件配置）',
      request: '（来自当前页面 —— 正常）',
      env: '（来自环境变量 DSH_WEB_URL —— 多实例时可能指错）',
      default: '（默认值 3080 —— 建议明确指定）',
    }
    function portSourceText(web) {
      var t = PORT_SOURCE_TEXT[web && web.portSource]
      return t ? '　' + t : ''
    }

    // ---------------------------------------------------------------- 面板
    function GuardPanel() {
      var stS = React.useState(null), st = stS[0], setSt = stS[1]
      var erS = React.useState(''), err = erS[0], setErr = erS[1]
      var buS = React.useState(''), busy = buS[0], setBusy = buS[1]
      var msS = React.useState(''), msg = msS[0], setMsg = msS[1]
      var cfS = React.useState(''), confirmName = cfS[0], setConfirmName = cfS[1]

      var load = React.useCallback(function () {
        return api('/dsh-guard/status').then(function (d) { setSt(d); setErr('') })
          .catch(function (e) { setErr(String((e && e.message) || e)) })
      }, [])

      React.useEffect(function () {
        load()
        var t = setInterval(load, 8000)
        return function () { clearInterval(t) }
      }, [load])

      // 两步确认：点一次变成"再点一次确认"，6 秒后自动复位
      React.useEffect(function () {
        if (!confirmName) return
        var t = setTimeout(function () { setConfirmName('') }, 6000)
        return function () { clearTimeout(t) }
      }, [confirmName])

      function doSnapshot() {
        setBusy('snapshot'); setMsg('')
        api('/dsh-guard/snapshot', { reason: 'manual' }).then(function (r) {
          setMsg(r.ok ? '✓ ' + (r.message || '已创建快照') : '✗ ' + (r.error || '创建失败'))
          return load()
        }).catch(function (e) { setMsg('✗ ' + String((e && e.message) || e)) })
          .then(function () { setBusy('') })
      }

      // 清理旧快照：保留最近 N 个（N 由守护配置决定），lastGood 那个永不删
      function doPrune() {
        setBusy('prune'); setMsg('')
        api('/dsh-guard/prune', {}).then(function (r) {
          setMsg(r.ok ? ('✓ ' + (r.message || '清理完成')) : ('✗ ' + (r.error || '失败')))
          return load()
        }).catch(function (e) { setMsg('✗ ' + String((e && e.message) || e)) })
          .then(function () { setBusy('') })
      }

      function doRollback(sname) {
        if (confirmName !== sname) { setConfirmName(sname); return }
        setConfirmName(''); setBusy('rollback-' + sname); setMsg('')
        api('/dsh-guard/rollback', { id: sname }).then(function (r) {
          var how = { explicit: '你指定的', lastGood: '上次健康的', latest: '最新的' }[r.how] || r.how || ''
          var lines = []
          lines.push(r.ok ? '✓ 回滚完成：' + (r.restoredFrom || sname) : '✗ 回滚失败：' + (r.error || r.message || ''))
          if (how) lines.push('  取用方式：' + how)
          if (r.steps && r.steps.length) lines.push('  ' + r.steps.join('\n  '))
          if (r.ok) lines.push('', '⚠ 需要重启 DSH 才会生效。')
          setMsg(lines.join('\n'))
          return load()
        }).catch(function (e) { setMsg('✗ ' + String((e && e.message) || e)) })
          .then(function () { setBusy('') })
      }


      if (err && !st) {
        return h('div', { style: C.card }, [
          h('h2', { key: 't', style: C.h2 }, '🛡 守护'),
          h('div', { key: 'e', style: Object.assign({}, C.msg, C.bad) }, '读不到守护状态：' + err),
          h('div', { key: 'h', style: C.hint }, '宿主路由 /dsh-guard/status 不可用 —— 确认插件已装好，并且重启过 DSH。'),
        ])
      }
      if (!st) return h('div', { style: { padding: 16, fontSize: 13 } }, '正在读取守护状态 …')

      var wd = st.watchdog || {}
      var web = st.web || {}
      var idn = st.profileIdentity || {}
      // 防御性：PowerShell 单元素数组可能被序列化成对象（历史 bug），这里一律归一成数组
      var rawSnaps = st.snapshots
      var snaps = rawSnaps ? (Array.isArray(rawSnaps) ? rawSnaps : [rawSnaps]) : []
      // 快照占多少盘要写在脸上：只增不减是最容易被忽视的问题（2026-09-14 用户报了这条）
      var totalMB = snaps.reduce(function (a, s) { return a + (Number(s.sizeMB) || 0) }, 0).toFixed(1)

      // ---- 卡片 1：守护状态 ----
      var card1 = h('div', { key: 'status', style: C.card }, [
        h('h2', { key: 't', style: C.h2 }, [
          '🛡 守护',
          h('span', {
            key: 'b',
            style: Object.assign({}, C.mono, { padding: '1px 8px', borderRadius: 10, border: '1px solid currentColor' },
              wd.running ? C.ok : C.warn),
          }, wd.running ? '看门狗运行中' : '看门狗未运行'),
        ]),
        h('div', { key: 'r1', style: C.row }, [
          h('span', { key: 'k', style: C.k }, 'DSH 网页端'),
          h('span', { key: 'v', style: web.listening ? C.v : Object.assign({}, C.v, C.bad) },
            (web.url || '-') + '　' + (web.listening ? '✓ 在监听' : '✗ 未监听！') + portSourceText(web)),
        ]),
        h('div', { key: 'r2', style: C.row }, [
          h('span', { key: 'k', style: C.k }, 'profile'),
          h('span', { key: 'v', style: Object.assign({}, C.v, C.mono) }, st.profile + (st.profileExists ? '' : '（目录不存在！）')),
        ]),
        h('div', { key: 'r3', style: C.row }, [
          h('span', { key: 'k', style: C.k }, '插件指纹'),
          h('span', { key: 'v', style: C.v }, (idn.hash || '-') + '　依赖 ' + (idn.depCount == null ? '-' : idn.depCount) + ' 项'),
        ]),
        h('div', { key: 'r4', style: C.row }, [
          h('span', { key: 'k', style: C.k }, '守护数据目录'),
          h('span', { key: 'v', style: Object.assign({}, C.v, C.mono) }, st.guardHome || '-'),
        ]),
        h('div', { key: 'r5', style: C.row }, [
          h('span', { key: 'k', style: C.k }, '看门狗 PID'),
          h('span', { key: 'v', style: C.v }, wd.running ? String(wd.pid) : '—'),
        ]),
        st.lastIncident ? h('div', { key: 'inc', style: C.msg }, '最近事故：' + JSON.stringify(st.lastIncident)) : null,
        // 看门狗跑的是 <守护数据目录>\bin 的副本，只在安装时同步 —— 不一致就说明它在跑旧代码，
        // 症状是"某个新功能死活不生效"（2026-09-14 用户报的快照自动清理就是这么来的）。
        wd.scriptsStale ? h('div', { key: 'stale', style: Object.assign({}, C.msg, C.warn) },
          '⚠️ 看门狗与插件目录里的脚本版本不一致（' + ((wd.staleFiles || []).join('、')) + '）：' +
          (wd.scriptStaleSide === 'plugin'
            ? '插件目录那份是旧的 —— 重装插件（Install-Plugin.cmd）后重启 DSH 即可，看门狗不用动。'
            : '看门狗跑的是旧脚本 —— 去独立窗口点一次「安装看门狗」即同步并重启。')) : null,
        // 看门狗的安装/卸载**故意不放在这个面板里**：
        //   它要注册计划任务（要管理员）或写启动文件夹，是"改系统"的动作；
        //   而这个面板本身就跟 DSH 同生共死 —— 一旦装崩了，你连修它的界面都没有。
        //   所以那两个按钮搬到了独立窗口（它不依赖 DSH）。2026-09-14 用户要求删掉面板里这两个。
        h('div', { key: 'wdhint', style: C.hint },
          '看门狗的安装 / 卸载请看状态徽章旁的结论，并到【独立窗口】里操作：双击插件目录里的 Open-Guard-UI.cmd。' +
          '　这里只做查看 + 快照 / 回滚。' +
          '　⚠️ 如果 DSH 根本打不开，这个面板自然也打不开 —— 那时更该用独立窗口。'),
      ])

      // ---- 卡片 2：快照 ----
      var rows = snaps.map(function (s) {
        return h('div', { key: s.name, style: C.snap }, [
          h('div', { key: 'info', style: { minWidth: 0 } }, [
            h('div', { key: 'n', style: { fontWeight: 600 } }, s.label || s.name),
            h('div', { key: 'm', style: Object.assign({}, C.mono, C.k) },
              s.name + '　' + (s.sizeMB == null ? '' : s.sizeMB + ' MB') + '　' + (s.createdAt || '') +
              '　' + (s.hash || '') + (s.nodeModules ? '' : '　(无 node_modules 镜像)')),
          ]),
          h('button', {
            key: 'go',
            style: confirmName === s.name ? C.btnConfirm : C.btnDanger,
            disabled: !!busy,
            onClick: function () { doRollback(s.name) },
          }, busy === 'rollback-' + s.name ? '回滚中…' : (confirmName === s.name ? '再点一次确认回滚' : '回滚到此快照')),
        ])
      })

      var card2 = h('div', { key: 'snaps', style: C.card }, [
        h('h2', { key: 't', style: C.h2 }, [
          '📦 快照（' + snaps.length + ' 个 · ' + totalMB + ' MB）',
          h('span', { key: 'sp', style: { flex: 1 } }),
          h('button', { key: 'pr', style: C.btn, disabled: !!busy, onClick: doPrune },
            busy === 'prune' ? '清理中…' : '清理旧快照'),
          h('button', { key: 'mk', style: C.btnPrimary, disabled: !!busy, onClick: doSnapshot },
            busy === 'snapshot' ? '正在打快照…' : '＋ 打一个快照'),
          h('button', { key: 'rf', style: C.btn, disabled: !!busy, onClick: function () { load() } }, '刷新'),
        ]),
        snaps.length === 0
          ? h('div', { key: 'none', style: C.hint }, '还没有快照。建议在"装插件 / 改配置之前"先打一个 —— 那就是你的回滚点。')
          : h('div', { key: 'list' }, rows),
      ])

      var msgStyle = Object.assign({}, C.msg, msg.indexOf('✓') === 0 ? C.ok : (msg.indexOf('✗') === 0 ? C.bad : {}))
      return h('div', { style: { maxWidth: 760 } }, [
        card1,
        card2,
        msg ? h('div', { key: 'msg', style: msgStyle }, msg) : null,
      ])
    }

    // ---------------------------------------------------------------- 注册
    function apply(ctx) {
      ctx.slots.inject('settings.plugins.tab', function () {
        return ctx.slots.register({
          name: 'settings.plugins.tab',
          id: 'guard',
          order: 20,
          label: function () { return '守护' },
          inject: function () { return {} },
        }, GuardPanel)
      })
    }

    exports.apply = apply
    exports.inject = inject
    exports.name = name
    return module.exports
  },
})
