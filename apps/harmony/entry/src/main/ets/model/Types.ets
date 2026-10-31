/**
 * /mobile/v1 的数据形状。
 * 与 docs/api.md 一一对应，改动协议时先改这里。
 */

export interface SessionSummary {
  id: string
  title: string
  workspace: string
  status: string
  updatedAt: string
  preview?: string
  pinned?: boolean
  /** user | subagent；旧版桥接不返回时按 user 处理 */
  origin?: string
  parentId?: string | null
}

export interface DiffFile {
  path: string
  adds: number
  dels: number
}

export interface ChatItem {
  seq: number
  turn: number
  /** user | assistant | thought | tool | tool-result | diff | tool-group */
  type: string
  text?: string
  markdown?: string
  name?: string
  callId?: string
  status?: string
  title?: string
  output?: string
  files?: DiffFile[]
  children?: ChatItem[]
  at?: string
}

export interface SessionSnapshot {
  session: SessionSummary
  items: ChatItem[]
  cursor: number
  hasMore: boolean
  settings?: SessionSettings
  /** 宿主是否正在跑这一轮（旧版桥接不返回） */
  running?: boolean
  /** thinking | tools | writing | idle */
  phase?: string
}

/** /tail 只返回增量条目，session 字段缺省。 */
export interface TailResult {
  items: ChatItem[]
  cursor: number
  running?: boolean
  phase?: string
  settings?: SessionSettings
}

export interface SessionSettings {
  permission: string
  provider: string
  model: string
  effort: string
}

export interface PermissionOption {
  value: string
  name: string}

export interface PermissionInfo {
  preset: string
  sandbox: string
  approval: string
  options: PermissionOption[]
}

export interface UploadResult {
  path: string
}

export interface ApprovalItem {
  id: string
  sessionId: string
  toolName: string
  callId: string
  expiresInMs: number
}

export interface ApprovalList {
  items: ApprovalItem[]
}

export interface UsageToday {
  date: string
  cost: number
  calls: number
  inputTokens: number
  outputTokens: number
}

export interface PeakState {
  active: boolean
  nextAt: string
  nextInMinutes: number
  tomorrow?: boolean
  window: string
}

export interface ModelEffort {
  id: string
  name: string
  description?: string
}

export interface ModelReasoning {
  efforts: ModelEffort[]
  defaultEffort?: string
}

export interface ModelEntry {
  id: string
  name: string
  reasoning?: ModelReasoning
}

export interface ModelGroup {
  id: string
  name: string
  models: ModelEntry[]
}

export interface ModelCatalog {
  default: SessionSettings
  routableProviders: string[]
  groups: ModelGroup[]
}

export interface UsageDay {
  date: string
  cost: number
}

export interface UsageInfo {
  today: UsageToday
  week: UsageDay[]
  peak: PeakState
  balance: number | null
}

export interface WalletEntry {
  currency: string
  balance: string
}

export interface AccountBalance {
  status: string
  value?: WalletEntry[]
  bonusWallets?: WalletEntry[]
}

export interface ProfileValue {
  id?: string | null
  name?: string | null
  contact?: string | null
  avatarUrl?: string | null
}

export interface AccountProfile {
  status: string
  value?: ProfileValue
}

export interface AccountInfo {
  available: boolean
  balance: AccountBalance | null
  profile: AccountProfile | null
}

export interface HelloInfo {
  name: string
  /** 宿主机名，用于自动命名主机（旧版桥接没有这个字段） */
  host?: string
  bridgeVersion: string
  protocol: string
  capabilities: string[]
  paired: boolean
}

/** 一台被控制的电脑。 */
export interface HostEntry {
  id: string
  name: string
  url: string
  token: string
}

export interface PairResult {
  deviceId: string
  deviceToken: string
  serverName: string
}

export interface SessionsResult {
  sessions: SessionSummary[]
}

export interface CreateSessionResult {
  session: SessionSummary
}

export interface PromptResult {
  accepted: boolean
  requestId: string
}

export interface BridgeErrorBody {
  code: string
  message: string
}

export interface BridgeErrorEnvelope {
  error: BridgeErrorBody
}

/** 一次请求的失败，携带 HTTP 状态与后端错误码。 */
export class BridgeError extends Error {
  status: number
  code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}
