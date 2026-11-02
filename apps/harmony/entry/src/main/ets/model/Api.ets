/**
 * /mobile/v1 客户端。
 * 只用 @ohos.net.http，不依赖任何三方库。
 */

import http from '@ohos.net.http'
import {
  AccountInfo, ApprovalList, BridgeError, BridgeErrorEnvelope, CreateSessionResult, HelloInfo,
  ModelCatalog, PairResult, PermissionInfo, PromptResult, SessionSnapshot, SessionsResult,
  TailResult, UploadResult, UsageInfo
} from './Types'

const TIMEOUT = 25000

interface PairBody {
  code: string
  deviceName: string
}

interface PromptBody {
  text: string
}

interface ModelBody {
  provider: string
  model: string
  effort: string
}

interface CreateBody {
  workspace: string
}

interface RenameBody {
  title: string
}

interface PermissionBody {
  preset: string
}

interface UploadBody {
  dir: string
  name: string
  data: string
}

interface DecisionBody {
  decision: string
}

export class Api {
  private base: string = ''
  private token: string = ''

  constructor(baseUrl: string, token: string) {
    this.base = Api.normalize(baseUrl)
    this.token = token
  }

  /** 补全协议、去掉结尾斜杠，允许用户只填 IP:端口。 */
  static normalize(raw: string): string {
    let url = raw.trim()
    if (url === '') {
      return ''
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://' + url
    }
    while (url.endsWith('/')) {
      url = url.slice(0, url.length - 1)
    }
    if (url.endsWith('/mobile/v1')) {
      return url
    }
    return url + '/mobile/v1'
  }

  private async request<T>(method: http.RequestMethod, path: string, body?: string): Promise<T> {
    const client = http.createHttp()
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json'
      }
      if (this.token !== '') {
        header['Authorization'] = 'Bearer ' + this.token
      }
      const response = await client.request(this.base + path, {
        method: method,
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: TIMEOUT,
        readTimeout: TIMEOUT
      })
      const text = response.result as string
      if (response.responseCode < 200 || response.responseCode >= 300) {
        let code = 'http-' + response.responseCode
        let message = text
        try {
          const envelope = JSON.parse(text) as BridgeErrorEnvelope
          if (envelope.error !== undefined) {
            code = envelope.error.code
            message = envelope.error.message
          }
        } catch (e) {
          // 非 JSON 错误体，原样返回
        }
        throw new BridgeError(response.responseCode, code, message)
      }
      return JSON.parse(text) as T
    } finally {
      client.destroy()
    }
  }

  async hello(): Promise<HelloInfo> {
    return this.request<HelloInfo>(http.RequestMethod.GET, '/hello')
  }

  /** 配对不需要令牌，用临时实例。 */
  static async pair(baseUrl: string, code: string, deviceName: string): Promise<PairResult> {
    const anonymous = new Api(baseUrl, '')
    const payload: PairBody = { code: code, deviceName: deviceName }
    const body = JSON.stringify(payload)
    return anonymous.request<PairResult>(http.RequestMethod.POST, '/pair', body)
  }

  /** 拼出可直接给 Image / Video 用的带令牌地址。 */
  fileUrl(filePath: string): string {
    return this.base + '/file?path=' + encodeURIComponent(filePath) + '&token=' + encodeURIComponent(this.token)
  }

  async sessions(): Promise<SessionsResult> {
    return this.request<SessionsResult>(http.RequestMethod.GET, '/sessions')
  }

  async createSession(workspace: string): Promise<CreateSessionResult> {
    const payload: CreateBody = { workspace: workspace }
    return this.request<CreateSessionResult>(http.RequestMethod.POST, '/sessions', JSON.stringify(payload))
  }

  async archived(): Promise<SessionsResult> {
    return this.request<SessionsResult>(http.RequestMethod.GET, '/sessions/archived')
  }

  async models(): Promise<ModelCatalog> {
    return this.request<ModelCatalog>(http.RequestMethod.GET, '/models')
  }

  async usage(): Promise<UsageInfo> {
    return this.request<UsageInfo>(http.RequestMethod.GET, '/usage')
  }

  async account(): Promise<AccountInfo> {
    return this.request<AccountInfo>(http.RequestMethod.GET, '/account')
  }

  async setModel(sessionId: string, provider: string, model: string, effort: string): Promise<void> {
    const payload: ModelBody = { provider: provider, model: model, effort: effort }
    await this.request<object>(
      http.RequestMethod.POST, '/sessions/' + encodeURIComponent(sessionId) + '/model',
      JSON.stringify(payload))
  }

  async rename(sessionId: string, title: string): Promise<void> {
    const payload: RenameBody = { title: title }
    await this.request<object>(
      http.RequestMethod.POST, '/sessions/' + encodeURIComponent(sessionId) + '/rename',
      JSON.stringify(payload))
  }

  async pin(sessionId: string, on: boolean): Promise<void> {
    await this.request<object>(
      http.RequestMethod.POST,
      '/sessions/' + encodeURIComponent(sessionId) + (on ? '/pin' : '/unpin'), '{}')
  }

  async archive(sessionId: string, on: boolean): Promise<void> {
    await this.request<object>(
      http.RequestMethod.POST,
      '/sessions/' + encodeURIComponent(sessionId) + (on ? '/archive' : '/unarchive'), '{}')
  }

  async permission(sessionId: string): Promise<PermissionInfo> {
    return this.request<PermissionInfo>(
      http.RequestMethod.GET, '/sessions/' + encodeURIComponent(sessionId) + '/permission')
  }

  async approvals(): Promise<ApprovalList> {
    return this.request<ApprovalList>(http.RequestMethod.GET, '/approvals')
  }

  async decideApproval(id: string, decision: string): Promise<void> {
    const payload: DecisionBody = { decision: decision }
    await this.request<object>(
      http.RequestMethod.POST, '/approvals/' + encodeURIComponent(id), JSON.stringify(payload))
  }

  async setPermission(sessionId: string, preset: string): Promise<void> {
    const payload: PermissionBody = { preset: preset }
    await this.request<object>(
      http.RequestMethod.POST,
      '/sessions/' + encodeURIComponent(sessionId) + '/permission', JSON.stringify(payload))
  }

  async snapshot(sessionId: string): Promise<SessionSnapshot> {
    return this.request<SessionSnapshot>(http.RequestMethod.GET, '/sessions/' + encodeURIComponent(sessionId))
  }

  async tail(sessionId: string, afterSeq: number): Promise<TailResult> {
    return this.request<TailResult>(
      http.RequestMethod.GET,
      '/sessions/' + encodeURIComponent(sessionId) + '/tail?afterSeq=' + afterSeq.toString())
  }

  /** 长轮询：有增量或本轮结束时立即返回，否则最多挂 timeoutMs。 */
  async waitFresh(sessionId: string, afterSeq: number, timeoutMs: number): Promise<TailResult> {
    return this.request<TailResult>(
      http.RequestMethod.GET,
      '/sessions/' + encodeURIComponent(sessionId) + '/wait?afterSeq=' + afterSeq.toString()
        + '&timeout=' + timeoutMs.toString())
  }

  async upload(dir: string, name: string, base64: string): Promise<UploadResult> {
    const payload: UploadBody = { dir: dir, name: name, data: base64 }
    return this.request<UploadResult>(
      http.RequestMethod.POST, '/upload', JSON.stringify(payload))
  }

  async prompt(sessionId: string, text: string): Promise<PromptResult> {
    const payload: PromptBody = { text: text }
    const body = JSON.stringify(payload)
    return this.request<PromptResult>(
      http.RequestMethod.POST, '/sessions/' + encodeURIComponent(sessionId) + '/prompt', body)
  }

  async cancel(sessionId: string): Promise<void> {
    const body = '{}'
    await this.request<object>(
      http.RequestMethod.POST, '/sessions/' + encodeURIComponent(sessionId) + '/cancel', body)
  }
}
