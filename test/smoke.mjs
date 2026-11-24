// 冒烟自测：健康检查、事件总线、鉴权边界。
// 用假 ctx 起一份桥，不需要真的 DSH 宿主（也不连网络）。
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { apply } from '../lib/index.mjs'

const PORT = 3399
const PROXY_PORT = 3398
const TOKEN = 'testtoken-0123456789'

const handlers = new Map()
let disposer = null

/** 假网关：记录调用形状，供配对审批链路的单测用。 */
const gatewayCalls = []
const fakeGateway = {
  async invoke(request) {
    gatewayCalls.push(request)
    if (request.method === 'pairingRequests') {
      return {
        requests: [
          { id: 'req-1', code: 'ABCD2345', authority: 'https://x', sourceIp: '10.0.0.2', expiresInMs: 120000 },
        ],
        pollIntervalMs: 2000,
      }
    }
    if (request.method === 'decidePairing') return 'approved'
    return undefined
  },
}

const ctx = {
  webServer: { port: 7999 },
  connection: {
    trustedHosts: [],
    browserAuth: null,
    createPeer(options) {
      return { id: 'peer-owner', principal: options?.principal, disposed: false }
    },
  },
  typertGateway: fakeGateway,
  on(name, fn) {
    handlers.set(name, fn)
    return () => handlers.delete(name)
  },
  effect(fn) {
    const result = fn()
    if (typeof result === 'function') disposer = result
    return () => {}
  },
}

const results = []
function check(name, ok, detail = '') {
  results.push({ name, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** 用自建请求发，才能控制 Host 头（模拟经隧道域名访问）。 */
function request(pathname, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port: PORT, path: pathname, method: 'GET', headers },
      (res) => {
        let body = ''
        res.setEncoding('utf8')
        res.on('data', (chunk) => { body += chunk })
        res.on('end', () => resolve({ status: res.statusCode, body }))
      },
    )
    req.on('error', reject)
    req.end()
  })
}

const PUBLIC_HOST = 'dsh.example.com'

async function main() {
  apply(ctx, {
    port: PORT,
    proxyPort: PROXY_PORT,
    bind: '127.0.0.1',
    token: TOKEN,
    tokenFile: path.join(os.tmpdir(), 'dshremote-smoke.token'),
    hostsFile: path.join(os.tmpdir(), 'dshremote-smoke.hosts'),
    publicUrlFile: path.join(os.tmpdir(), 'dshremote-smoke.public'),
    logFile: path.join(os.tmpdir(), 'dshremote-smoke.log'),
    proxyEnabled: false,
    discovery: false,
    tunnel: 'off',
  })
  await sleep(700)

  // 1. /health
  const health = JSON.parse((await request('/health')).body)
  check('health 返回 ok', health.ok === true && health.service === 'dshremote-bridge', JSON.stringify(health))

  // 2. 事件总线：伪造宿主事件
  const onSessionEvent = handlers.get('session/event')
  check('注册了 session/event 处理器', typeof onSessionEvent === 'function')

  onSessionEvent(
    { id: 'session-abc' },
    { type: 'session/title', data: { title: '修构建问题' }, seq: 10 },
  )
  onSessionEvent(
    { id: 'session-abc' },
    {
      type: 'user/message',
      data: { content: [{ type: 'text', text: '帮我看下 hvigor 为什么报 00303024' }] },
      seq: 11,
    },
  )
  onSessionEvent(
    { id: 'session-abc' },
    {
      type: 'assistant/message',
      data: { message: { content: [{ type: 'text', text: '因为 modelVersion 没写一致的版本号，两个文件都要写。' }] } },
      seq: 12,
    },
  )
  onSessionEvent(
    { id: 'session-abc' },
    { type: 'turn/end', data: { turn: 2, reason: { kind: 'natural' } }, seq: 13 },
  )

  // 3. /events —— 回环免 token
  const loopback = await request('/events')
  check('/events 回环免 token', loopback.status === 200, String(loopback.status))

  // 4. /events —— 公网 Host 无 token 必须 401
  const noToken = await request('/events', { host: PUBLIC_HOST })
  check('/events 公网 Host 无 token → 401', noToken.status === 401, String(noToken.status))

  // 5. /events —— 公网 Host 用请求头带 token
  const viaHeader = await request('/events', { host: PUBLIC_HOST, 'x-dsh-token': TOKEN })
  const body = JSON.parse(viaHeader.body)
  const turnEnd = body.events.find((item) => item.type === 'turn_end')
  check('/events 请求头带 token → 200', viaHeader.status === 200, String(viaHeader.status))
  check('事件里带 turn_end', Boolean(turnEnd), `${body.events.length} 条`)
  check('turn_end 带会话标题', turnEnd?.sessionTitle === '修构建问题', String(turnEnd?.sessionTitle))
  check('turn_end 带提问', String(turnEnd?.question || '').includes('00303024'))
  check('turn_end 带回复摘要', String(turnEnd?.answerHead || '').includes('modelVersion'))
  check('turn_end 状态归一为 done', turnEnd?.status === 'done', String(turnEnd?.status))
  check('turn_end 带 turn 序号', turnEnd?.turn === 2, String(turnEnd?.turn))
  check('每个事件带单调 seq', body.events.every((item, i) => i === 0 || item.seq > body.events[i - 1].seq))
  check('响应带 latestSeq', Number(body.latestSeq) >= Number(turnEnd?.seq), String(body.latestSeq))

  // 6. afterSeq 增量拉取
  const afterSeq = Number(turnEnd?.seq || 0)
  const incremental = JSON.parse((await request(`/events?afterSeq=${afterSeq}`)).body)
  check('afterSeq 过滤掉已读事件', incremental.events.every((item) => Number(item.seq) > afterSeq))

  // 7. 错误 token 被拒（公网 Host 下）
  const wrong = await request(`/events?token=wrong`, { host: PUBLIC_HOST })
  check('错误 token → 401', wrong.status === 401, String(wrong.status))

  // 8. /auth/url：无 token 401；有 token 时——宿主不给 browserAuth 也能自签，
  //    只有在读不到持久密钥的机器上才回 503（CI 就是这种机器）。
  check('/auth/url 无 token → 401', (await request('/auth/url', { host: PUBLIC_HOST })).status === 401)
  const authUrl = await request(`/auth/url?token=${TOKEN}&base=http://dsh.example.com:3398/`, { host: PUBLIC_HOST })
  const selfSigned = authUrl.status === 200 && /"cookie":"dsh-auth-/.test(authUrl.body)
  check('/auth/url 自签 cookie 或降级 503', selfSigned || authUrl.status === 503, String(authUrl.status))

  // 9. 配对审批接口：网关可用时按 owner 身份读列表与批准
  check('/pairing/list 无 token → 401', (await request('/pairing/list', { host: PUBLIC_HOST })).status === 401)
  const pairingList = await request(`/pairing/list?token=${TOKEN}`, { host: PUBLIC_HOST })
  const pairingBody = JSON.parse(pairingList.body || '{}')
  check('/pairing/list 返回待批准申请',
    pairingList.status === 200 && pairingBody.ok === true && pairingBody.requests.length === 1
      && pairingBody.requests[0].code === 'ABCD2345',
    pairingList.body.slice(0, 90))
  const listCall = gatewayCalls.find((call) => call.method === 'pairingRequests')
  check('/pairing/list 走 remoteConnection 命名空间且用 owner peer',
    Boolean(listCall) && listCall.namespace === 'remoteConnection'
      && listCall.peer?.principal?.kind === 'owner', JSON.stringify(listCall?.namespace ?? null))

  const decide = await request(`/pairing/decide?id=req-1&decision=allow`, {
    host: PUBLIC_HOST,
    'x-dsh-token': TOKEN,
  })
  const decideBody = JSON.parse(decide.body || '{}')
  check('/pairing/decide 批准成功', decide.status === 200 && decideBody.ok === true && decideBody.result === 'approved',
    decide.body.slice(0, 90))
  const decideCall = gatewayCalls.find((call) => call.method === 'decidePairing')
  check('/pairing/decide 参数正确', Boolean(decideCall) && decideCall.args?.id === 'req-1'
    && decideCall.args?.decision === 'allow', JSON.stringify(decideCall?.args ?? null))
  check('/pairing/decide 拒绝非法 decision',
    (await request(`/pairing/decide?id=req-1&decision=maybe`, { host: PUBLIC_HOST, 'x-dsh-token': TOKEN })).status === 400)

  // 10. 非法 Host 不再崩进程
  const badHost = await request('/', { host: 'bad host with spaces' })
  check('非法 Host → 400 而不是崩溃', badHost.status === 400, String(badHost.status))
  const stillAlive = JSON.parse((await request('/health')).body)
  check('非法 Host 之后进程仍存活', stillAlive.ok === true)

  // 11. 面板按钮的鉴权：面板没有 token，只带 X-DSH-Panel: 1
  //     这两个接口过去只认 X-DSH-Token，导致「一键修复」「让 AI 修」一直是 401 bad-token。
  const panelRepair = await request('/repair', { host: '127.0.0.1', 'x-dsh-panel': '1', origin: 'dsh-app://app' })
  check('/repair 接受面板凭据（不再 401 bad-token）',
    !(panelRepair.status === 401 && JSON.parse(panelRepair.body || '{}').error === 'bad-token'),
    `${panelRepair.status} ${panelRepair.body.slice(0, 70)}`)

  const panelAiFix = await request('/ai-fix', { host: '127.0.0.1', 'x-dsh-panel': '1', origin: 'dsh-app://app' })
  check('/ai-fix 接受面板凭据（不再 401 bad-token）',
    !(panelAiFix.status === 401 && JSON.parse(panelAiFix.body || '{}').error === 'bad-token'),
    `${panelAiFix.status} ${panelAiFix.body.slice(0, 70)}`)

  // 没有凭据、没有面板头的外部请求仍然要被拒，别为了修面板把门开大
  const naked = await request('/ai-fix', { host: PUBLIC_HOST })
  check('/ai-fix 无凭据仍拒绝', naked.status === 401 || naked.status === 403, String(naked.status))

  // 面板头 + 非回环来源必须拒绝（伪造面板头的网页）
  const spoofed = await request('/ai-fix', { host: PUBLIC_HOST, 'x-dsh-panel': '1', origin: 'https://evil.example.com' })
  check('/ai-fix 伪造面板头被拒', spoofed.status === 401 || spoofed.status === 403, String(spoofed.status))

  // 12. cloudflared 自动探测：未配置路径时不应抛错，且 tunnelHint 给出人话
  const probeDiag = JSON.parse((await request('/pair/test')).body || '{}')
  const tunnelCheck = (probeDiag.checks ?? []).find((item) => item.name === '隧道')
  check('/pair/test 的隧道项给出可读原因',
    Boolean(tunnelCheck) && typeof tunnelCheck.detail === 'string' && tunnelCheck.detail.length > 0,
    tunnelCheck?.detail ?? '(无 detail)')

  disposer?.()
  await sleep(200)

  const failed = results.filter((item) => !item.ok)
  console.log(`\n${results.length - failed.length}/${results.length} 通过`)
  process.exit(failed.length === 0 ? 0 : 1)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
