/**
 * DSH 手机端 · 单页三态（配对 / 会话列表 / 对话）。
 *
 * 为什么不用路由：三个状态共享同一份连接上下文，单页切换比 pushUrl 少一层
 * 参数传递，也避免返回栈与连接状态不同步。
 */

import { Api } from '../model/Api'
import {
  ensureNotificationPermission, notifyApproval, notifyTurnDone,
  startBackgroundWatch, stopBackgroundWatch
} from '../model/Notify'
import { common } from '@kit.AbilityKit'
import picker from '@ohos.file.picker'
import fs from '@ohos.file.fs'
import util from '@ohos.util'
import {
  AccountInfo, ApprovalItem, BridgeError, ChatItem, DiffFile, HostEntry, ModelCatalog, ModelEffort,
  ModelEntry, ModelGroup, PermissionInfo, PermissionOption, SessionSettings, SessionSummary,
  UsageDay, UsageInfo
} from '../model/Types'
import { MdBlock, parseMarkdown } from '../model/Markdown'

PersistentStorage.persistProp('dsh_hosts', '[]')
PersistentStorage.persistProp('dsh_active', '')

const BG = '#FFFFFF'
const PANEL = '#F9FAFB'
const LINE = '#EBEDF0'
const TEXT = '#0F1115'
const TEXT2 = '#61666B'
const TEXT3 = '#8B9099'
const ACCENT = '#3970E5'
const ACCENT_SOFT = '#EEF3FE'
/** 每个工作区默认露出几条会话，其余折叠。 */
const PREVIEW_COUNT = 5

/** 列表里混排的一行：工作区分组头或一条会话。 */
interface GroupRow {
  kind: string
  label: string
  count: number
  session?: SessionSummary
}

/** 一个工作区的会话块（iOS 分组卡）。 */
interface SessionGroup {
  label: string
  count: number
  sessions: SessionSummary[]
}

@Entry
@Component
struct Index {
  @StorageLink('dsh_hosts') hostsJson: string = '[]'
  @StorageLink('dsh_active') activeId: string = ''

  @State screen: string = 'pair'
  @State sessions: SessionSummary[] = []
  @State rows: GroupRow[] = []
  @State groups: SessionGroup[] = []
  @State expanded: string[] = []
  @State items: ChatItem[] = []
  @State rawItems: ChatItem[] = []
  @State current: SessionSummary | undefined = undefined
  @State settings: SessionSettings | undefined = undefined
  @State usage: UsageInfo | undefined = undefined
  @State account: AccountInfo | undefined = undefined
  @State avatarError: boolean = false
  @State showHosts: boolean = false
  @State pending: boolean = false
  @State pendingText: string = '已发送，等待电脑处理…'
  @State renaming: boolean = false
  @State renameTitle: string = ''
  @State showActions: boolean = false
  @State archivedSessions: SessionSummary[] = []
  @State allSessions: SessionSummary[] = []
  @State searchQuery: string = ''
  @State searching: boolean = false
  @State actionSession: SessionSummary | undefined = undefined
  @State permissionInfo: PermissionInfo | undefined = undefined
  private pollTimer: number = -1
  @State editingHostId: string = ''
  @State editName: string = ''
  @State showSheet: boolean = false
  @State saving: boolean = false
  @State pendingApprovals: ApprovalItem[] = []
  @State notifyEnabled: boolean = false
  private knownApprovals: string[] = []
  private approvalTimer: number = -1
  @State openTools: string[] = []
  @State catalog: ModelCatalog | undefined = undefined
  @State picking: boolean = false
  @State draft: string = ''
  @State busy: boolean = false
  @State notice: string = ''
  @State serverInput: string = ''
  @State codeInput: string = ''
  @State pairError: string = ''

  private scroller: Scroller = new Scroller()

  aboutToAppear(): void {
    const host = this.activeHost()
    this.serverInput = host === undefined ? '' : host.url
    if (host !== undefined) {
      this.screen = 'list'
      this.refresh()
      this.startApprovalWatch()
    }
  }

  /* ------------------------------ 主机列表 ------------------------------ */

  private hosts(): HostEntry[] {
    try {
      return JSON.parse(this.hostsJson) as HostEntry[]
    } catch (error) {
      return []
    }
  }

  private activeHost(): HostEntry | undefined {
    const list = this.hosts()
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.activeId) {
        return list[i]
      }
    }
    return list.length > 0 ? list[0] : undefined
  }

  private saveHosts(list: HostEntry[], active: string): void {
    this.hostsJson = JSON.stringify(list)
    this.activeId = active
  }

  private switchHost(host: HostEntry): void {
    this.activeId = host.id
    this.showHosts = false
    this.screen = 'list'
    this.refresh()
  }

  private applyRename(): void {
    const name = this.editName.trim()
    if (name === '' || this.editingHostId === '') {
      return
    }
    const list: HostEntry[] = []
    const current = this.hosts()
    for (let i = 0; i < current.length; i++) {
      const item = current[i]
      if (item.id === this.editingHostId) {
        const updated: HostEntry = { id: item.id, name: name, url: item.url, token: item.token }
        list.push(updated)
      } else {
        list.push(item)
      }
    }
    this.saveHosts(list, this.activeId)
    this.editingHostId = ''
    this.editName = ''
  }

  private removeHost(host: HostEntry): void {
    const list = this.hosts().filter((item: HostEntry) => item.id !== host.id)
    const nextActive = list.length > 0 ? list[0].id : ''
    this.saveHosts(list, nextActive)
    this.showHosts = false
    if (list.length === 0) {
      this.screen = 'pair'
      return
    }
    this.refresh()
  }

  private api(): Api {
    const host = this.activeHost()
    return new Api(host?.url ?? '', host?.token ?? '')
  }

  private describe(error: Object): string {
    if (error instanceof BridgeError) {
      return error.code + ': ' + error.message
    }
    return String(error)
  }

  async pair(): Promise<void> {
    this.pairError = ''
    if (this.serverInput.trim() === '' || this.codeInput.trim().length !== 8) {
      this.pairError = '请填写地址和 8 位配对码'
      return
    }
    this.busy = true
    try {
      const url = Api.normalize(this.serverInput)
      const result = await Api.pair(this.serverInput, this.codeInput.trim(), 'HarmonyOS')
      let name = url.replace('https://', '').replace('http://', '').replace('/mobile/v1', '')
      try {
        const hello = await new Api(url, '').hello()
        if (hello.host !== undefined && hello.host !== '') {
          name = hello.host
        }
      } catch (error) {
        // 拿不到机器名就用地址
      }
      const host: HostEntry = {
        id: 'h' + Date.now().toString(),
        name: name,
        url: url,
        token: result.deviceToken
      }
      const list = this.hosts()
      list.push(host)
      this.saveHosts(list, host.id)
      this.codeInput = ''
      this.screen = 'list'
      this.startApprovalWatch()
      await this.refresh()
    } catch (error) {
      this.pairError = this.describe(error as Object)
    } finally {
      this.busy = false
    }
  }

  /** DSH 每轮注入的上下文，不是用户说的话，先挡掉。 */
  private isInjected(text: string): boolean {
    return text.startsWith('Current runtime context')
      || text.startsWith('Time sampled while preparing')
      || text.startsWith('<system-reminder>')
      || text.startsWith('Current working directory')
  }

  /** 把 tool 与 tool-result 合成一条，和 PC 的"一行工具调用"一致。 */
  private mergeTools(items: ChatItem[]): ChatItem[] {
    const out: ChatItem[] = []
    const index: Map<string, number> = new Map()
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      if (item.type === 'user' && this.isInjected(item.text ?? '')) {
        continue
      }
      if (item.type === 'tool') {
        index.set(item.callId ?? '', out.length)
        out.push(item)
        continue
      }
      if (item.type === 'tool-result') {
        const at = index.get(item.callId ?? '')
        if (at !== undefined) {
          const base = out[at]
          const merged: ChatItem = {
            seq: base.seq,
            turn: base.turn,
            type: 'tool',
            name: base.name,
            callId: base.callId,
            title: base.title,
            status: item.status,
            output: item.output,
            at: base.at
          }
          out[at] = merged
          continue
        }
      }
      out.push(item)
    }
    return this.groupTools(out)
  }

  /** 连续的多个工具调用折成一行，点开才逐个展开——PC 上那种"一堆 read/edit"的收起。 */
  private groupTools(items: ChatItem[]): ChatItem[] {
    const result: ChatItem[] = []
    let buffer: ChatItem[] = []
    const flush = () => {
      if (buffer.length === 0) {
        return
      }
      if (buffer.length === 1) {
        result.push(buffer[0])
      } else {
        const head: ChatItem = {
          seq: buffer[0].seq,
          turn: buffer[0].turn,
          type: 'tool-group',
          children: buffer,
          at: buffer[0].at
        }
        result.push(head)
      }
      buffer = []
    }
    for (let i = 0; i < items.length; i++) {
      if (items[i].type === 'tool') {
        buffer.push(items[i])
        continue
      }
      flush()
      result.push(items[i])
    }
    flush()
    return result
  }

  async createSession(workspace: string): Promise<void> {
    if (this.busy) {
      return
    }
    this.busy = true
    this.notice = ''
    try {
      const target = workspace !== ''
        ? workspace
        : (this.sessions.length > 0 ? this.sessions[0].workspace : '')
      const created = await this.api().createSession(target)
      await this.refresh()
      await this.open(created.session)
    } catch (error) {
      this.notice = this.describe(error as Object)
    } finally {
      this.busy = false
    }
  }

  async refresh(): Promise<void> {
    this.busy = true
    try {
      const result = await this.api().sessions()
      // 只挡真正的 subagent 子会话；播种会话带 parentId 但用户可见。
      const mine = result.sessions.filter((s: SessionSummary) => s.origin !== 'subagent')
      // 和 PC 侧栏一致：按最近活动时间倒序。
      mine.sort((a: SessionSummary, b: SessionSummary) => b.updatedAt.localeCompare(a.updatedAt))
      this.allSessions = mine
      this.applyFilter()
      this.notice = ''
    } catch (error) {
      const e = error as BridgeError
      if (e.status === 401) {
        this.screen = 'pair'
        this.pairError = '这台电脑的设备凭据已失效，请重新配对'
      } else {
        this.notice = this.describe(error as Object)
      }
    } finally {
      this.busy = false
    }

    // 账号与用量独立加载：一个失败不影响另一个，也不影响列表。
    try {
      this.account = await this.api().account()
      this.avatarError = false
    } catch (error) {
      this.account = undefined
    }
    try {
      this.usage = await this.api().usage()
    } catch (error) {
      this.usage = undefined
    }
  }

  /** 本地过滤：标题 + 最后一条消息预览，纯内存，不请求接口。 */
  /** 分组卡的复用 key 必须带上成员，否则过滤后 ArkUI 会复用旧节点不刷新。 */
  private groupKey(group: SessionGroup): string {
    const ids: string[] = []
    for (let i = 0; i < group.sessions.length; i++) {
      ids.push(group.sessions[i].id)
    }
    return group.label + '|' + ids.join(',')
  }

  private applyFilter(): void {
    const keyword = this.searchQuery.trim().toLowerCase()
    const list: SessionSummary[] = []
    for (let i = 0; i < this.allSessions.length; i++) {
      const item = this.allSessions[i]
      const title = (item.title ?? '').toLowerCase()
      const preview = (item.preview ?? '').toLowerCase()
      const workspace = (item.workspace ?? '').toLowerCase()
      if (keyword === '' || title.includes(keyword) || preview.includes(keyword)
        || workspace.includes(keyword)) {
        list.push(item)
      }
    }
    this.sessions = list
    this.rows = this.buildRows(list)
    this.groups = this.buildGroups(list)
  }

  /** 按工作区聚合：分组顺序取各工作区首次出现的顺序，组内保持原有时间序。 */
  private buildRows(sessions: SessionSummary[]): GroupRow[] {
    const rows: GroupRow[] = []
    const order: string[] = []
    for (let i = 0; i < sessions.length; i++) {
      const workspace = sessions[i].workspace === '' ? '未分组' : sessions[i].workspace
      if (!order.includes(workspace)) {
        order.push(workspace)
      }
    }
    for (let g = 0; g < order.length; g++) {
      const members: SessionSummary[] = []
      for (let i = 0; i < sessions.length; i++) {
        const workspace = sessions[i].workspace === '' ? '未分组' : sessions[i].workspace
        if (workspace === order[g]) {
          members.push(sessions[i])
        }
      }
      const header: GroupRow = { kind: 'header', label: order[g], count: members.length }
      rows.push(header)

      const expanded = this.expanded.includes(order[g])
      const visible = expanded ? members.length : Math.min(PREVIEW_COUNT, members.length)
      for (let i = 0; i < visible; i++) {
        const row: GroupRow = { kind: 'session', label: '', count: 0, session: members[i] }
        rows.push(row)
      }
      if (members.length > PREVIEW_COUNT) {
        const more: GroupRow = { kind: 'more', label: order[g], count: members.length }
        rows.push(more)
      }
    }
    return rows
  }

  private buildGroups(sessions: SessionSummary[]): SessionGroup[] {
    const order: string[] = []
    for (let i = 0; i < sessions.length; i++) {
      const workspace = sessions[i].workspace === '' ? '未分组' : sessions[i].workspace
      if (!order.includes(workspace)) {
        order.push(workspace)
      }
    }
    const groups: SessionGroup[] = []
    for (let g = 0; g < order.length; g++) {
      const members: SessionSummary[] = []
      for (let i = 0; i < sessions.length; i++) {
        const workspace = sessions[i].workspace === '' ? '未分组' : sessions[i].workspace
        if (workspace === order[g]) {
          members.push(sessions[i])
        }
      }
      const group: SessionGroup = { label: order[g], count: members.length, sessions: members }
      groups.push(group)
    }
    return groups
  }

  private toggleGroup(workspace: string): void {
    if (this.expanded.includes(workspace)) {
      this.expanded = this.expanded.filter((item: string) => item !== workspace)
    } else {
      this.expanded = this.expanded.concat([workspace])
    }
  }

  /** 只取路径最后一段；DSH 的默认工作区给一个中文名。 */
  private baseName(path: string): string {
    let text = path
    while (text.endsWith('\\') || text.endsWith('/')) {
      text = text.slice(0, text.length - 1)
    }
    const lower = text.toLowerCase()
    if (lower.endsWith('deepseek-harness\\default-workspace') || lower.endsWith('deepseek-harness/default-workspace')) {
      return '默认工作区'
    }
    const cut = Math.max(text.lastIndexOf('\\'), text.lastIndexOf('/'))
    return cut >= 0 ? text.slice(cut + 1) : text
  }

  /** 没有标题的会话多半是空白会话，别让它显示成"未命名"。 */
  private displayTitle(session: SessionSummary): string {
    return session.title === '未命名会话' || session.title === '' ? '空白会话' : session.title
  }

  async open(session: SessionSummary): Promise<void> {
    this.busy = true
    this.notice = ''
    this.stopPolling()
    try {
      const snapshot = await this.api().snapshot(session.id)
      this.current = snapshot.session
      this.rawItems = snapshot.items
      this.items = this.mergeTools(snapshot.items)
      this.settings = snapshot.settings
      this.screen = 'chat'
      setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom) }, 60)
    } catch (error) {
      this.notice = this.describe(error as Object)
    } finally {
      this.busy = false
    }
  }

  async send(): Promise<void> {
    const text = this.draft.trim()
    if (text === '' || this.current === undefined) {
      return
    }
    this.draft = ''
    this.busy = true
    try {
      const sessionId = this.current.id
      await this.api().prompt(sessionId, text)
      const snapshot = await this.api().snapshot(sessionId)
      this.rawItems = snapshot.items
      this.items = this.mergeTools(snapshot.items)
      this.current = snapshot.session
      setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom) }, 60)
      // 电脑收到后要起模型、跑工具，期间界面保持"处理中"，直到出现新条目。
      this.pending = true
      this.pendingText = '已发送，等待电脑处理…'
      this.waitSession(sessionId)
    } catch (error) {
      this.notice = this.describe(error as Object)
    } finally {
      this.busy = false
    }
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearTimeout(this.pollTimer)
      this.pollTimer = -1
    }
    this.pending = false
  }

  private startApprovalWatch(): void {
    if (this.approvalTimer !== -1) {
      return
    }
    this.approvalTimer = setInterval((): void => {
      if (this.activeHost() === undefined) {
        this.pendingApprovals = []
        return
      }
      this.api().approvals().then((list) => {
        this.pendingApprovals = list.items
        if (this.notifyEnabled) {
          for (let i = 0; i < list.items.length; i++) {
            const item = list.items[i]
            if (!this.knownApprovals.includes(item.id)) {
              this.knownApprovals.push(item.id)
              notifyApproval(item.toolName)
            }
          }
        }
      }).catch(() => {
        this.pendingApprovals = []
      })
    }, 2000)
  }

  async toggleNotify(on: boolean): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    if (!on) {
      this.notifyEnabled = false
      await stopBackgroundWatch(context)
      return
    }
    const allowed = await ensureNotificationPermission(context)
    if (!allowed) {
      this.notice = '没有通知权限，请在系统设置里允许'
      return
    }
    const started = await startBackgroundWatch(context)
    this.notifyEnabled = started
    if (!started) {
      this.notice = '后台运行没启动起来'
    }
  }

  async decideApproval(id: string, decision: string): Promise<void> {
    try {
      await this.api().decideApproval(id, decision)
      this.pendingApprovals = this.pendingApprovals.filter((item: ApprovalItem) => item.id !== id)
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async pickImage(): Promise<void> {
    const session = this.current
    if (session === undefined) {
      return
    }
    try {
      const options = new picker.PhotoSelectOptions()
      options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE
      options.maxSelectNumber = 1
      const photoPicker = new picker.PhotoViewPicker()
      const picked = await photoPicker.select(options)
      const uri = picked.photoUris.length > 0 ? picked.photoUris[0] : ''
      if (uri === '') {
        return
      }
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const stat = fs.statSync(uri)
      const buffer = new ArrayBuffer(stat.size)
      fs.readSync(file.fd, buffer)
      fs.closeSync(file)
      const helper = new util.Base64Helper()
      const base64 = helper.encodeToStringSync(new Uint8Array(buffer))
      const parts = uri.split('/')
      const name = parts.length > 0 ? parts[parts.length - 1] : 'image.png'
      const result = await this.api().upload(session.workspace, name, base64)
      this.draft = this.draft + '[图片] ' + result.path + '\n'
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async stopTurn(): Promise<void> {
    const session = this.current
    if (session === undefined) {
      return
    }
    this.stopPolling()
    try {
      await this.api().cancel(session.id)
      this.notice = '已请求停止'
      const snapshot = await this.api().snapshot(session.id)
      this.rawItems = snapshot.items
      this.items = this.mergeTools(snapshot.items)
      this.current = snapshot.session
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async applyRenameSession(): Promise<void> {
    const title = this.renameTitle.trim()
    const session = this.current
    if (title === '' || session === undefined) {
      return
    }
    try {
      await this.api().rename(session.id, title)
      const updated: SessionSummary = {
        id: session.id,
        title: title,
        workspace: session.workspace,
        status: session.status,
        updatedAt: session.updatedAt,
        preview: session.preview,
        origin: session.origin,
        parentId: session.parentId
      }
      this.current = updated
      this.renaming = false
      this.notice = ''
      this.refresh()
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async openArchived(): Promise<void> {
    this.screen = 'archived'
    try {
      const result = await this.api().archived()
      this.archivedSessions = result.sessions
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async unarchive(session: SessionSummary): Promise<void> {
    try {
      await this.api().archive(session.id, false)
      this.archivedSessions = this.archivedSessions.filter((item: SessionSummary) => item.id !== session.id)
      this.refresh()
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async pinAction(on: boolean): Promise<void> {
    const session = this.actionSession
    this.showActions = false
    if (session === undefined) {
      return
    }
    try {
      await this.api().pin(session.id, on)
      this.notice = on ? '已置顶' : '已取消置顶'
      this.refresh()
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  async archiveAction(): Promise<void> {
    const session = this.actionSession
    this.showActions = false
    if (session === undefined) {
      return
    }
    try {
      await this.api().archive(session.id, true)
      this.notice = '已归档'
      this.refresh()
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  /** 轮询会话快照，等到新条目出现就撤掉"处理中"。 */
  private phaseText(phase: string, running: boolean): string {
    if (phase === 'tools') {
      return '正在执行工具…'
    }
    if (phase === 'writing') {
      return '正在生成回复…'
    }
    if (phase === 'thinking' || running) {
      return '电脑正在思考…'
    }
    return '已发送，等待电脑处理…'
  }

  private lastSeq(): number {
    let max = -1
    for (let i = 0; i < this.rawItems.length; i++) {
      if (this.rawItems[i].seq > max) {
        max = this.rawItems[i].seq
      }
    }
    return max
  }

  /** 长轮询：有新条目或本轮结束就立刻返回，否则在宿主上挂住等。 */
  private waitSession(sessionId: string): void {
    if (this.current === undefined || this.current.id !== sessionId) {
      this.pending = false
      return
    }
    this.api().waitFresh(sessionId, this.lastSeq(), 20000).then((tail) => {
      if (this.current === undefined || this.current.id !== sessionId) {
        this.pending = false
        return
      }
      if (tail.items.length > 0) {
        this.rawItems = this.rawItems.concat(tail.items)
        this.items = this.mergeTools(this.rawItems)
        if (tail.settings !== undefined) {
          this.settings = tail.settings
        }
        setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom) }, 40)
      }
      const running = tail.running === true
      this.pendingText = this.phaseText(tail.phase ?? '', running)
      if (!running) {
        if (this.notifyEnabled && tail.items.length > 0) {
          notifyTurnDone(this.current?.title ?? '会话已完成')
        }
        this.pending = false
        return
      }
      this.waitSession(sessionId)
    }).catch(() => {
      if (this.current !== undefined && this.current.id === sessionId && this.pending) {
        setTimeout((): void => { this.waitSession(sessionId) }, 1200)
      }
    })
  }

  /* ------------------------------ 界面 ------------------------------ */

  @Builder
  BrandHeader() {
    Row({ space: 11 }) {
      Image($r('app.media.app_icon'))
        .width(40)
        .height(40)
        .borderRadius(12)
        .shadow({ radius: 10, color: '#1A101820', offsetY: 3 })
      Column({ space: 1 }) {
        Text('DeepSeek Harness')
          .fontSize(16.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
        Text('手机遥控器')
          .fontSize(11.5)
          .fontColor(TEXT3)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.busy) {
        LoadingProgress().width(16).height(16).color(ACCENT)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  PairView() {
    Column() {
      this.BrandHeader()

      Column({ space: 10 }) {
        Text('连接你的电脑')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
        Text('在电脑上安装 dsh-mobile-bridge 插件后，\n这里填地址和配对码即可。')
          .fontSize(13.5)
          .fontColor(TEXT2)
          .lineHeight(21)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 22 })
      .alignItems(HorizontalAlign.Start)

      Column({ space: 18 }) {
        Column({ space: 7 }) {
          Text('电脑地址').fontSize(12.5).fontColor(TEXT3)
          TextInput({ text: this.serverInput, placeholder: '192.168.1.157:3099' })
            .height(46)
            .backgroundColor(PANEL)
            .border({ width: 1, color: LINE })
            .borderRadius(12)
            .fontSize(15)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => { this.serverInput = value })
        }
        .alignItems(HorizontalAlign.Start)

        Column({ space: 7 }) {
          Text('配对码').fontSize(12.5).fontColor(TEXT3)
          TextInput({ text: this.codeInput, placeholder: '8 位数字' })
            .type(InputType.Number)
            .maxLength(8)
            .height(46)
            .backgroundColor(PANEL)
            .border({ width: 1, color: LINE })
            .borderRadius(12)
            .fontSize(15)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => { this.codeInput = value })
        }
        .alignItems(HorizontalAlign.Start)

        if (this.pairError !== '') {
          Text(this.pairError)
            .fontSize(12.5)
            .fontColor('#C62828')
            .width('100%')
        }

        Button(this.busy ? '连接中…' : '连接')
          .width('100%')
          .height(46)
          .backgroundColor(ACCENT)
          .borderRadius(12)
          .fontSize(15)
          .enabled(!this.busy)
          .onClick(() => { this.pair() })
      }
      .padding({ left: 16, right: 16 })

      Blank()

      Text('配对码显示在电脑上的 DSH 日志里，10 分钟内有效')
        .fontSize(11.5)
        .fontColor(TEXT3)
        .padding({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  @Builder
  SessionRow(session: SessionSummary) {
    Row({ space: 8 }) {
      if (session.status === 'running') {
        Circle({ width: 6, height: 6 }).fill('#E0A03A')
      }
      Column({ space: 3 }) {
        if (session.pinned === true) {
          Text('📌').fontSize(11)
        }
        Text(this.displayTitle(session))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (session.status === 'running') {
          Text('运行中')
            .fontSize(11.5)
            .fontColor('#8A5A00')
        } else if ((session.preview ?? '') !== '') {
          Text(session.preview)
            .fontSize(12.5)
            .fontColor(TEXT3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.shortTime(session.updatedAt))
        .fontSize(11.5)
        .fontColor(TEXT3)
        .flexShrink(0)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .border({ width: { bottom: 0.5 }, color: '#F1F2F4' })
    .gesture(LongPressGesture().onAction(() => {
      this.actionSession = session
      this.showActions = true
    }))
    .onClick(() => { this.open(session) })
  }

  @Builder
  HomeCard() {
    Column({ space: 12 }) {
      Row({ space: 11 }) {
        if (this.avatarUrl() !== '' && !this.avatarError) {
          Image(this.avatarUrl())
            .width(42)
            .height(42)
            .borderRadius(21)
            .objectFit(ImageFit.Cover)
            .backgroundColor('#EEF1F5')
            .onError(() => { this.avatarError = true })
        } else {
          Text(this.profileName().slice(0, 1))
            .width(42)
            .height(42)
            .borderRadius(21)
            .backgroundColor(ACCENT)
            .fontColor('#FFFFFF')
            .fontSize(17)
            .textAlign(TextAlign.Center)
        }
        Column({ space: 2 }) {
          Text(this.profileName())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.profileContact() !== '') {
            Text(this.profileContact()).fontSize(11.5).fontColor(TEXT3)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('设置')
          .fontSize(12)
          .fontColor(TEXT2)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .border({ width: 1, color: LINE })
          .borderRadius(8)
          .backgroundColor('#FFFFFF')
          .onClick(() => { this.openSettingsPage() })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('余额').fontSize(11.5).fontColor(TEXT3)
        Text(this.balanceText())
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
        Blank()
        if (this.usage !== undefined) {
          Text(this.usage.peak.active ? '高峰' : '空闲')
            .fontSize(10.5)
            .fontColor(this.usage.peak.active ? '#C2410C' : '#1A7F37')
            .backgroundColor(this.usage.peak.active ? '#FDF1E7' : '#EAF7EF')
            .borderRadius(5)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          Text(this.usage.peak.active
            ? (this.usage.peak.nextAt + ' 结束')
            : ((this.usage.peak.tomorrow === true ? '明天 ' : '') + this.usage.peak.nextAt + ' 起高峰'))
            .fontSize(10.5)
            .fontColor(TEXT3)
        }
      }
      .width('100%')

      if (this.usage !== undefined) {
        Row() {
          Text('今日消耗').fontSize(11.5).fontColor(TEXT3)
          Text(' ¥' + this.usage.today.cost.toFixed(2))
            .fontSize(12)
            .fontColor(TEXT2)
          Text(' · ' + this.usage.today.calls.toString() + ' 次')
            .fontSize(12)
            .fontColor(TEXT3)
          Blank()
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .shadow({ radius: 16, color: '#0F172A14', offsetY: 4 })
    .margin({ left: 14, right: 14, top: 12, bottom: 2 })
  }

  @Builder
  UsageStrip() {
    if (this.usage !== undefined) {
      Row({ space: 6 }) {
        Text('今日 ¥' + this.usage.today.cost.toFixed(2))
          .fontSize(12)
          .fontColor(TEXT2)
        Text('· ' + this.usage.today.calls.toString() + ' 次')
          .fontSize(12)
          .fontColor(TEXT3)
        Blank()
        Text(this.usage.peak.active ? '高峰' : '空闲')
          .fontSize(10.5)
          .fontColor(this.usage.peak.active ? '#C2410C' : '#1A7F37')
          .backgroundColor(this.usage.peak.active ? '#FDF1E7' : '#EAF7EF')
          .borderRadius(5)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        if (this.usage.peak.nextAt !== '') {
          Text(this.usage.peak.active
            ? (this.usage.peak.nextAt + ' 结束')
            : ((this.usage.peak.tomorrow === true ? '明天 ' : '') + this.usage.peak.nextAt + ' 进入高峰'))
            .fontSize(11)
            .fontColor(TEXT3)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })
    }
  }

  async applyEffort(effort: string): Promise<void> {
    if (this.current === undefined || this.settings === undefined) {
      return
    }
    if (this.settings.provider === '' || this.settings.model === '') {
      this.notice = '这个会话还没有模型记录，先发一条消息再试'
      return
    }
    this.saving = true
    try {
      await this.api().setModel(this.current.id, this.settings.provider, this.settings.model, effort)
      const next: SessionSettings = {
        permission: this.settings.permission,
        provider: this.settings.provider,
        model: this.settings.model,
        effort: effort
      }
      this.settings = next
      this.notice = ''
    } catch (error) {
      this.notice = this.describe(error as Object)
    } finally {
      this.saving = false
    }
  }

  async openSettings(): Promise<void> {
    this.showSheet = true
    this.picking = false
    const session = this.current
    if (session !== undefined) {
      try {
        this.permissionInfo = await this.api().permission(session.id)
      } catch (error) {
        this.permissionInfo = undefined
      }
    }
    if (this.catalog === undefined) {
      try {
        this.catalog = await this.api().models()
      } catch (error) {
        this.catalog = undefined
      }
    }
  }

  private permissionOptions(): PermissionOption[] {
    const options = this.permissionInfo?.options ?? []
    if (options.length > 0) {
      return options
    }
    return [
      { value: 'read-only', name: '仅可查看' },
      { value: 'workspace-write', name: '工作区内修改' },
      { value: 'danger-full-access', name: '完全权限' }
    ]
  }

  /** 宿主给的选项名是英文标识，界面上换成中文。 */
  private presetLabel(value: string): string {
    if (value === 'read-only') {
      return '仅可查看'
    }
    if (value === 'workspace-write') {
      return '工作区内修改'
    }
    if (value === 'danger-full-access') {
      return '完全权限'
    }
    return value
  }

  private permissionPreset(): string {
    const preset = this.permissionInfo?.preset ?? this.settings?.permission ?? ''
    return preset
  }

  async changePermission(preset: string): Promise<void> {
    const session = this.current
    if (session === undefined) {
      return
    }
    try {
      await this.api().setPermission(session.id, preset)
      this.permissionInfo = await this.api().permission(session.id)
      this.notice = '权限已切换'
    } catch (error) {
      this.notice = this.describe(error as Object)
    }
  }

  /** 当前模型支持的档位；拿不到目录时退回三档。 */
  private effortIds(): string[] {
    const groups = this.catalog?.groups ?? []
    for (let g = 0; g < groups.length; g++) {
      const models = groups[g].models
      for (let m = 0; m < models.length; m++) {
        if (models[m].id === this.settings?.model && models[m].reasoning !== undefined) {
          const efforts = models[m].reasoning?.efforts ?? []
          if (efforts.length > 0) {
            return efforts.map((item: ModelEffort) => item.id)
          }
        }
      }
    }
    return ['low', 'medium', 'high']
  }

  private effortLabel(effort: string): string {
    const groups = this.catalog?.groups ?? []
    for (let g = 0; g < groups.length; g++) {
      const models = groups[g].models
      for (let m = 0; m < models.length; m++) {
        if (models[m].id !== this.settings?.model) {
          continue
        }
        const efforts = models[m].reasoning?.efforts ?? []
        for (let e = 0; e < efforts.length; e++) {
          if (efforts[e].id === effort) {
            return efforts[e].name
          }
        }
      }
    }
    if (effort === 'low') {
      return '低'
    }
    if (effort === 'medium') {
      return '中'
    }
    if (effort === 'high') {
      return '高'
    }
    if (effort === 'max') {
      return '最高'
    }
    return effort === '' ? '默认' : effort
  }

  private modelName(): string {
    const groups = this.catalog?.groups ?? []
    for (let g = 0; g < groups.length; g++) {
      const models = groups[g].models
      for (let m = 0; m < models.length; m++) {
        if (models[m].id === this.settings?.model) {
          return models[m].name
        }
      }
    }
    return this.settings?.model ?? '未知'
  }

  async applyModel(provider: string, model: string): Promise<void> {
    if (this.current === undefined) {
      return
    }
    this.saving = true
    try {
      let effort = this.settings?.effort ?? ''
      const groups = this.catalog?.groups ?? []
      for (let g = 0; g < groups.length; g++) {
        const models = groups[g].models
        for (let m = 0; m < models.length; m++) {
          if (models[m].id === model && models[m].reasoning !== undefined) {
            const supported = (models[m].reasoning?.efforts ?? []).map((item: ModelEffort) => item.id)
            if (supported.length > 0 && !supported.includes(effort)) {
              effort = models[m].reasoning?.defaultEffort ?? supported[0]
            }
          }
        }
      }
      await this.api().setModel(this.current.id, provider, model, effort)
      const next: SessionSettings = {
        permission: this.settings?.permission ?? '',
        provider: provider,
        model: model,
        effort: effort
      }
      this.settings = next
      this.picking = false
      this.notice = ''
    } catch (error) {
      this.notice = this.describe(error as Object)
    } finally {
      this.saving = false
    }
  }

  @Builder
  ModelPicker() {
    Column() {
      Scroll() {
        Column() {
          ForEach(this.catalog?.groups ?? [], (group: ModelGroup) => {
            Text(group.name)
              .fontSize(12)
              .fontColor(TEXT3)
              .width('100%')
              .padding({ left: 18, right: 18, top: 10, bottom: 4 })
            ForEach(group.models, (model: ModelEntry) => {
              Row() {
                Text(model.name)
                  .fontSize(14.5)
                  .fontColor(this.settings?.model === model.id ? ACCENT : TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.settings?.model === model.id) {
                  Text('当前').fontSize(11).fontColor(ACCENT)
                }
              }
              .width('100%')
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .onClick(() => { this.applyModel(group.id, model.id) })
            }, (model: ModelEntry) => group.id + '-' + model.id)
          }, (group: ModelGroup) => group.id)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
  }

  @Builder
  ApprovalDialog() {
    Column({ space: 10 }) {
      Text('需要你审批')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%')
      Text(this.pendingApprovals[0].toolName === ''
        ? '这个操作需要确认后才会执行'
        : ('工具：' + this.pendingApprovals[0].toolName))
        .fontSize(14)
        .fontColor(TEXT2)
        .width('100%')
      Text('会话 ' + this.pendingApprovals[0].sessionId.slice(-8))
        .fontSize(11.5)
        .fontColor(TEXT3)
        .width('100%')
      Text('5 分钟内不回复会自动取消，这次不会执行')
        .fontSize(11.5)
        .fontColor(TEXT3)
        .width('100%')

      Row({ space: 10 }) {
        Button('拒绝')
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#F2F3F5')
          .fontColor(TEXT)
          .fontSize(15)
          .onClick(() => { this.decideApproval(this.pendingApprovals[0].id, 'reject') })
        Button('允许一次')
          .layoutWeight(1)
          .height(42)
          .backgroundColor(ACCENT)
          .fontColor('#FFFFFF')
          .fontSize(15)
          .onClick(() => { this.decideApproval(this.pendingApprovals[0].id, 'allow') })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .margin({ left: 28, right: 28 })
    .shadow({ radius: 24, color: '#0F172A33', offsetY: 8 })
  }

  @Builder
  ActionSheet() {
    Column() {
      Text(this.actionSession?.title ?? '会话')
        .fontSize(12.5)
        .fontColor(TEXT3)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 18, right: 18, top: 16, bottom: 10 })

      Row() {
        Text('置顶').fontSize(15).fontColor(TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 14 })
      .onClick(() => { this.pinAction(true) })

      Divider().strokeWidth(0.5).color(LINE).margin({ left: 18, right: 18 })

      Row() {
        Text('归档').fontSize(15).fontColor(TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 14 })
      .onClick(() => { this.archiveAction() })

      Divider().strokeWidth(0.5).color(LINE).margin({ left: 18, right: 18 })

      Row() {
        Text('重命名').fontSize(15).fontColor(TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 14 })
      .onClick(() => {
        const session = this.actionSession
        this.showActions = false
        if (session === undefined) {
          return
        }
        this.current = session
        this.renameTitle = session.title
        this.renaming = true
      })

      Divider().strokeWidth(0.5).color(LINE).margin({ left: 18, right: 18 })

      Row() {
        Text('取消').fontSize(15).fontColor(TEXT3)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 22 })
      .onClick(() => { this.showActions = false })
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  @Builder
  RenameSheet() {
    Column() {
      Row() {
        Text('重命名会话').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TEXT)
        Blank()
        Text('取消')
          .fontSize(13)
          .fontColor(TEXT3)
          .onClick(() => { this.renaming = false })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 10 })

      TextInput({ text: this.renameTitle, placeholder: '会话名称' })
        .height(46)
        .backgroundColor('#F7F8FA')
        .borderRadius(10)
        .fontSize(15)
        .padding({ left: 12, right: 12 })
        .margin({ left: 18, right: 18 })
        .onChange((value: string) => { this.renameTitle = value })

      Row() {
        Button('保存')
          .width('100%')
          .height(44)
          .backgroundColor(ACCENT)
          .fontColor('#FFFFFF')
          .fontSize(15)
          .onClick(() => { this.applyRenameSession() })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 18 })
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  @Builder
  HostSheet() {
    Column() {
      if (this.editingHostId !== '') {
        Row() {
          Text('重命名').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TEXT)
          Blank()
          Text('取消')
            .fontSize(13)
            .fontColor(TEXT3)
            .onClick(() => {
              this.editingHostId = ''
              this.editName = ''
            })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 10 })

        TextInput({ text: this.editName, placeholder: '给这台电脑起个名字' })
          .height(46)
          .backgroundColor('#F7F8FA')
          .borderRadius(10)
          .fontSize(15)
          .padding({ left: 12, right: 12 })
          .margin({ left: 18, right: 18 })
          .onChange((value: string) => { this.editName = value })

        Row({ space: 10 }) {
          Button('保存')
            .layoutWeight(1)
            .height(44)
            .backgroundColor(ACCENT)
            .fontColor('#FFFFFF')
            .fontSize(15)
            .onClick(() => { this.applyRename() })
        }
        .padding({ left: 18, right: 18, top: 14, bottom: 18 })
        .width('100%')
      } else {
        Row() {
          Text('切换电脑').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TEXT)
          Blank()
          Text('完成')
            .fontSize(13)
            .fontColor(ACCENT)
            .onClick(() => { this.showHosts = false })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 6 })

        ForEach(this.hosts(), (host: HostEntry) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(host.name)
                .fontSize(15)
                .fontColor(host.id === this.activeId ? ACCENT : TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(host.url)
                .fontSize(11.5)
                .fontColor(TEXT3)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (host.id === this.activeId) {
              Text('当前').fontSize(11).fontColor(ACCENT)
            }
            Image($r('app.media.ic_edit'))
              .width(30)
              .height(30)
              .padding(7)
              .backgroundColor('#F2F3F5')
              .borderRadius(15)
              .objectFit(ImageFit.Contain)
              .onClick(() => {
                this.editingHostId = host.id
                this.editName = host.name
              })
            Image($r('app.media.ic_delete'))
              .width(30)
              .height(30)
              .padding(7)
              .backgroundColor('#FDECEA')
              .borderRadius(15)
              .objectFit(ImageFit.Contain)
              .margin({ left: 6 })
              .onClick(() => { this.removeHost(host) })          }
          .width('100%')
          .padding({ left: 18, right: 12, top: 12, bottom: 12 })
          .onClick(() => { this.switchHost(host) })
        }, (host: HostEntry) => host.id)

        Divider().strokeWidth(0.5).color(LINE)

        Row() {
          Text('＋ 添加电脑').fontSize(14).fontColor(ACCENT)
          Blank()
        }
        .width('100%')
        .padding({ left: 18, right: 16, top: 14, bottom: 20 })
        .onClick(() => {
          this.showHosts = false
          this.serverInput = ''
          this.codeInput = ''
          this.screen = 'pair'
        })
      }
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  @Builder
  SettingsSheet() {
    Column({ space: 0 }) {
      Row() {
        Text('会话设置').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TEXT)
        Blank()
        Button('完成')
          .fontSize(13)
          .height(30)
          .backgroundColor('#FFFFFF')
          .fontColor(ACCENT)
          .borderRadius(8)
          .onClick(() => { this.showSheet = false })
      }
      .width('100%')
      .padding({ left: 18, right: 12, top: 14, bottom: 8 })

      Row() {
        Text('会话名').fontSize(13).fontColor(TEXT3).width(64)
        Text(this.current?.title ?? '')
          .fontSize(14)
          .fontColor(TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('重命名')
          .fontSize(12)
          .fontColor(ACCENT)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .onClick(() => {
        this.showSheet = false
        this.renameTitle = this.current?.title ?? ''
        this.renaming = true
      })

      Divider().strokeWidth(0.5).color(LINE)

      Row({ space: 8 }) {
        Text('权限').fontSize(13).fontColor(TEXT3).width(64)
        ForEach(this.permissionOptions(), (option: PermissionOption) => {
          Text(this.presetLabel(option.value))
            .fontSize(11.5)
            .fontColor(this.permissionPreset() === option.value ? '#FFFFFF' : TEXT2)
            .backgroundColor(this.permissionPreset() === option.value ? ACCENT : '#F2F3F5')
            .borderRadius(8)
            .padding({ left: 7, right: 7, top: 5, bottom: 5 })
            .onClick(() => { this.changePermission(option.value) })
        }, (option: PermissionOption) => option.value)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })

      Divider().strokeWidth(0.5).color(LINE)

      Row() {
        Text('模型').fontSize(13).fontColor(TEXT3).width(64)
        Text(this.modelName())
          .fontSize(14)
          .fontColor(TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.picking ? '收起' : '更换')
          .fontSize(12)
          .fontColor(ACCENT)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .onClick(() => { this.picking = !this.picking })

      if (this.picking) {
        this.ModelPicker()
      }

      Divider().strokeWidth(0.5).color(LINE)

      Column({ space: 8 }) {
        Row() {
          Text('思考档位').fontSize(13).fontColor(TEXT3).width(64)
          Text(this.saving ? '应用中…' : '').fontSize(11).fontColor(TEXT3)
          Blank()
        }
        .width('100%')

        Row({ space: 8 }) {
          ForEach(this.effortIds(), (level: string) => {
            Text(this.effortLabel(level))
              .fontSize(13.5)
              .fontColor((this.settings?.effort ?? '') === level ? '#FFFFFF' : TEXT2)
              .backgroundColor((this.settings?.effort ?? '') === level ? ACCENT : '#FFFFFF')
              .border({ width: 1, color: (this.settings?.effort ?? '') === level ? ACCENT : LINE })
              .borderRadius(9)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .onClick(() => { this.applyEffort(level) })
          }, (level: string) => level)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 14 })

      if (this.notice !== '') {
        Text(this.notice)
          .fontSize(12)
          .fontColor('#C62828')
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 12 })
      }
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 18, topRight: 18 })
    .padding({ bottom: 18 })
  }

  async openSettingsPage(): Promise<void> {
    this.screen = 'settings'
    try {
      this.account = await this.api().account()
    } catch (error) {
      this.account = undefined
    }
    if (this.catalog === undefined) {
      try {
        this.catalog = await this.api().models()
      } catch (error) {
        this.catalog = undefined
      }
    }
    if (this.usage === undefined) {
      try {
        this.usage = await this.api().usage()
      } catch (error) {
        this.usage = undefined
      }
    }
  }

  private profileName(): string {
    const name = this.account?.profile?.value?.name ?? ''
    return name === '' ? 'DeepSeek 账号' : name
  }

  private profileContact(): string {
    const contact = this.account?.profile?.value?.contact ?? ''
    return contact === '' ? '' : this.maskPhone(contact)
  }

  private avatarUrl(): string {
    return this.account?.profile?.value?.avatarUrl ?? ''
  }

  private maskPhone(phone: string): string {
    if (phone.includes('@') || phone.length < 7) {
      return phone
    }
    return phone.slice(0, 3) + '****' + phone.slice(phone.length - 4)
  }

  private balanceText(): string {
    const balance = this.account?.balance
    if (balance === undefined || balance === null || balance.status !== 'ready') {
      return '—'
    }
    const wallets = balance.value ?? []
    if (wallets.length === 0) {
      return '—'
    }
    const symbol = wallets[0].currency === 'CNY' ? '¥' : '$'
    const raw = wallets[0].balance ?? ''
    const amount = Number(raw)
    if (!Number.isFinite(amount)) {
      return symbol + raw
    }
    return symbol + amount.toFixed(2)
  }

  @Builder
  SettingsView() {
    Column() {
      Row({ space: 6 }) {
        Button('‹')
          .fontSize(30)
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .fontColor(TEXT)
          .margin({ left: -6 })
          .onClick(() => { this.screen = 'list' })
        Text('设置').fontSize(17).fontWeight(FontWeight.Bold).fontColor(TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 10, right: 16, top: 8, bottom: 8 })

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 10 }) {
            Text('账号与余额').fontSize(12).fontColor(TEXT3).width('100%')
            Row({ space: 12 }) {
              if (this.avatarUrl() !== '' && !this.avatarError) {
                Image(this.avatarUrl())
                  .width(46)
                  .height(46)
                  .borderRadius(23)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor('#EEF1F5')
                  .onError(() => { this.avatarError = true })
              } else {
                Text(this.profileName().slice(0, 1))
                  .width(46)
                  .height(46)
                  .borderRadius(23)
                  .backgroundColor(ACCENT)
                  .fontColor('#FFFFFF')
                  .fontSize(19)
                  .textAlign(TextAlign.Center)
              }
              Column({ space: 3 }) {
                Text(this.profileName())
                  .fontSize(15.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.profileContact() !== '') {
                  Text(this.profileContact())
                    .fontSize(12)
                    .fontColor(TEXT3)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Row() {
              Text('余额').fontSize(13).fontColor(TEXT3)
              Blank()
              Text(this.balanceText())
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(TEXT)
            }
            .width('100%')

            if (this.usage !== undefined) {
              Row() {
                Text('今日消耗').fontSize(13).fontColor(TEXT3)
                Blank()
                Text('¥' + this.usage.today.cost.toFixed(2)
                  + '  ·  ' + this.usage.today.calls.toString() + ' 次')
                  .fontSize(13)
                  .fontColor(TEXT2)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(PANEL)
          .borderRadius(14)

          Column({ space: 10 }) {
            Text('模型').fontSize(12).fontColor(TEXT3).width('100%')
            Row() {
              Text('默认模型').fontSize(13).fontColor(TEXT3)
              Blank()
              Text(this.catalog?.default.model ?? '—')
                .fontSize(14)
                .fontColor(TEXT)
            }
            .width('100%')
            Row() {
              Text('提供方').fontSize(13).fontColor(TEXT3)
              Blank()
              Text(this.catalog?.default.provider ?? '—')
                .fontSize(13)
                .fontColor(TEXT2)
            }
            .width('100%')
            Text('在对话页底部的模型标签里可以按会话切换')
              .fontSize(11.5)
              .fontColor(TEXT3)
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(PANEL)
          .borderRadius(14)

          Column({ space: 10 }) {
            Text('通用设置').fontSize(12).fontColor(TEXT3).width('100%')
            Row() {
              Text('当前电脑').fontSize(13).fontColor(TEXT3)
              Blank()
              Text((this.activeHost()?.name ?? '未连接') + ' · ' + (this.activeHost()?.url ?? ''))
                .fontSize(12.5)
                .fontColor(TEXT2)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            Row() {
              Text('管理主机').fontSize(14).fontColor(TEXT)
              Blank()
              Text((this.hosts().length).toString() + ' 台 ›').fontSize(14).fontColor(TEXT3)
            }
            .width('100%')
            .padding({ top: 4 })
            .onClick(() => { this.showHosts = true })
            Row() {
              Text('已归档会话').fontSize(14).fontColor(TEXT)
              Blank()
              Text('›').fontSize(14).fontColor(TEXT3)
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
            .onClick(() => { this.openArchived() })
            Row() {
              Text('版本').fontSize(13).fontColor(TEXT3)
              Blank()
              Text('0.1.0').fontSize(12.5).fontColor(TEXT2)
            }
            .width('100%')
            Row() {
              Column({ space: 2 }) {
                Text('后台提醒').fontSize(14).fontColor(TEXT)
                Text('常驻后台，收到审批或任务完成时通知')
                  .fontSize(11)
                  .fontColor(TEXT3)
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.notifyEnabled })
                .selectedColor(ACCENT)
                .onChange((on: boolean) => { this.toggleNotify(on) })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            Row() {
              Text('移除当前主机').fontSize(14).fontColor('#C62828')
              Blank()
              Text('›').fontSize(14).fontColor(TEXT3)
            }
            .width('100%')
            .padding({ top: 4 })
            .onClick(() => {
              const host = this.activeHost()
              if (host !== undefined) {
                this.removeHost(host)
              }
              this.screen = 'pair'
            })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(PANEL)
          .borderRadius(14)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }


  @Builder
  TopBar() {
    Row({ space: 10 }) {
      Column({ space: 1 }) {
        Text('会话')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
        Row({ space: 4 }) {
          Text(this.activeHost()?.name ?? '未连接主机')
            .fontSize(12)
            .fontColor(TEXT3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('▾')
            .fontSize(9)
            .fontColor(TEXT3)
        }
        .onClick(() => { this.showHosts = true })
      }
      .alignItems(HorizontalAlign.Start)

      Blank()
      Row() {
        Image($r('app.media.ic_search'))
          .width(19)
          .height(19)
          .objectFit(ImageFit.Contain)
      }
      .width(36)
      .height(36)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.searching = !this.searching
        if (!this.searching) {
          this.searchQuery = ''
          this.applyFilter()
        }
      })
      Text('↻')
        .fontSize(20)
        .fontColor(TEXT2)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .onClick(() => { this.refresh() })
      if (this.avatarUrl() !== '' && !this.avatarError) {
        Image(this.avatarUrl())
          .width(32)
          .height(32)
          .borderRadius(16)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#EEF1F5')
          .onError(() => { this.avatarError = true })
          .onClick(() => { this.openSettingsPage() })
      } else {
        Text(this.profileName().slice(0, 1))
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(ACCENT)
          .fontColor('#FFFFFF')
          .fontSize(14)
          .textAlign(TextAlign.Center)
          .onClick(() => { this.openSettingsPage() })
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 6 })
  }

  @Builder
  AccountStrip() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('余额')
          .fontSize(11.5)
          .fontColor(TEXT3)
        Text(this.balanceText())
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT)
        Blank()
        if (this.usage !== undefined) {
          Text(this.usage.peak.active ? '高峰' : '空闲')
            .fontSize(10.5)
            .fontColor(this.usage.peak.active ? '#C2410C' : '#1A7F37')
            .backgroundColor(this.usage.peak.active ? '#FDF1E7' : '#EAF7EF')
            .borderRadius(5)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          Text(this.usage.peak.active
            ? (this.usage.peak.nextAt + ' 结束')
            : ((this.usage.peak.tomorrow === true ? '明天 ' : '') + this.usage.peak.nextAt))
            .fontSize(10.5)
            .fontColor(TEXT3)
        }
      }
      .width('100%')

      if (this.usage !== undefined) {
        Row({ space: 6 }) {
          Text('今日消耗 ¥' + this.usage.today.cost.toFixed(2))
            .fontSize(12)
            .fontColor(TEXT2)
          Text('· ' + this.usage.today.calls.toString() + ' 次')
            .fontSize(12)
            .fontColor(TEXT3)
          Blank()
        }
        .width('100%')
      }
    }
    .padding({ left: 18, right: 18, top: 14, bottom: 14 })
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .shadow({ radius: 10, color: '#0F172A10', offsetY: 2 })
    .margin({ left: 16, right: 16, top: 2, bottom: 12 })
    .onClick(() => { this.screen = 'usage' })
  }

  private barHeight(cost: number): number {
    const week = this.usage?.week ?? []
    let max = 0.01
    for (let i = 0; i < week.length; i++) {
      if (week[i].cost > max) {
        max = week[i].cost
      }
    }
    return Math.max(4, Math.round(cost / max * 96))
  }

  private shortDate(date: string): string {
    const parts = date.split('-')
    if (parts.length < 3) {
      return date
    }
    return parts[1] + '/' + parts[2]
  }

  @Builder
  UsageView() {
    Column() {
      Row({ space: 6 }) {
        Button('‹')
          .fontSize(30)
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .fontColor(TEXT)
          .margin({ left: -6 })
          .onClick(() => { this.screen = 'list' })
        Text('用量').fontSize(17).fontWeight(FontWeight.Bold).fontColor(TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 10, right: 16, top: 8, bottom: 8 })

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 6 }) {
            Text('今日消耗').fontSize(12).fontColor(TEXT3).width('100%')
            Text(this.usage === undefined ? '—' : ('¥' + this.usage.today.cost.toFixed(2)))
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor(TEXT)
              .width('100%')
            if (this.usage !== undefined) {
              Text(this.usage.today.calls.toString() + ' 次调用 · 输入 '
                + this.usage.today.inputTokens.toString() + ' / 输出 '
                + this.usage.today.outputTokens.toString())
                .fontSize(12)
                .fontColor(TEXT3)
                .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .shadow({ radius: 10, color: '#0F172A10', offsetY: 2 })

          Column({ space: 12 }) {
            Row() {
              Text('最近 7 天').fontSize(12).fontColor(TEXT3)
              Blank()
              if (this.usage !== undefined) {
                Text('合计 ¥' + this.weekTotal().toFixed(2)).fontSize(12).fontColor(TEXT3)
              }
            }
            .width('100%')

            Row({ space: 4 }) {
              ForEach(this.usage?.week ?? [], (day: UsageDay) => {
                Column({ space: 6 }) {
                  Column()
                    .width(20)
                    .height(this.barHeight(day.cost))
                    .backgroundColor(ACCENT)
                    .borderRadius(5)
                  Text(this.shortDate(day.date))
                    .fontSize(9)
                    .fontColor(TEXT3)
                }
                .layoutWeight(1)
                .justifyContent(FlexAlign.End)
              }, (day: UsageDay) => day.date)
            }
            .width('100%')
            .height(150)
            .alignItems(VerticalAlign.Bottom)
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .shadow({ radius: 10, color: '#0F172A10', offsetY: 2 })

          if (this.usage !== undefined) {
            Column({ space: 8 }) {
              Text('峰谷计费').fontSize(12).fontColor(TEXT3).width('100%')
              Text(this.usage.peak.window).fontSize(12.5).fontColor(TEXT2).width('100%')
              Text(this.usage.peak.active
                ? ('当前高峰，' + this.usage.peak.nextAt + ' 转空闲（半价）')
                : ('当前空闲（半价），' + (this.usage.peak.tomorrow === true ? '明天 ' : '')
                  + this.usage.peak.nextAt + ' 转高峰（双倍）'))
                .fontSize(12.5)
                .fontColor(TEXT3)
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(14)
            .shadow({ radius: 10, color: '#0F172A10', offsetY: 2 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }

  private weekTotal(): number {
    const week = this.usage?.week ?? []
    let total = 0
    for (let i = 0; i < week.length; i++) {
      total += week[i].cost
    }
    return total
  }

  @Builder
  ArchivedView() {
    Column() {
      Row({ space: 6 }) {
        Button('‹')
          .fontSize(30)
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .fontColor(TEXT)
          .margin({ left: -6 })
          .onClick(() => { this.screen = 'list' })
        Text('已归档').fontSize(17).fontWeight(FontWeight.Bold).fontColor(TEXT)
        Blank()
      }
      .width('100%')
      .padding({ left: 10, right: 16, top: 8, bottom: 8 })

      if (this.archivedSessions.length === 0) {
        Text('没有归档的会话')
          .fontSize(13)
          .fontColor(TEXT3)
          .padding({ top: 60 })
      } else {
        List() {
          ForEach(this.archivedSessions, (session: SessionSummary) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.displayTitle(session))
                  .fontSize(15)
                  .fontColor(TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('恢复')
                  .fontSize(12.5)
                  .fontColor(ACCENT)
                  .padding({ left: 10, right: 4, top: 6, bottom: 6 })
                  .onClick(() => { this.unarchive(session) })
              }
              .width('100%')
              .padding({ left: 16, right: 12, top: 14, bottom: 14 })
              .backgroundColor('#FFFFFF')
              .border({ width: { bottom: 0.5 }, color: '#F1F2F4' })
            }
          }, (session: SessionSummary) => session.id)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }

  @Builder
  GroupCard(group: SessionGroup) {
    Column() {
      Row({ space: 6 }) {
        Text(this.expanded.includes(group.label) ? '▾' : '▸')
          .fontSize(11)
          .fontColor(TEXT3)
        Text(this.baseName(group.label))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(group.count.toString())
          .fontSize(11.5)
          .fontColor(TEXT3)
        Blank()
        Text('＋')
          .fontSize(19)
          .fontColor(ACCENT)
          .padding({ left: 12, right: 2, top: 0, bottom: 0 })
          .onClick(() => { this.createSession(group.label === '未分组' ? '' : group.label) })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor('#F4F6FB')
      .onClick(() => { this.toggleGroup(group.label) })

      ForEach(group.sessions.slice(0,
        this.expanded.includes(group.label) ? group.count : Math.min(5, group.count)),
        (session: SessionSummary) => {
          this.SessionRow(session)
        }, (session: SessionSummary) => session.id)

      if (group.count > 5) {
        Row() {
          Text(this.expanded.includes(group.label) ? '收起' : ('展开全部 ' + group.count.toString() + ' 个'))
            .fontSize(12.5)
            .fontColor(TEXT3)
          Blank()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
        .onClick(() => { this.toggleGroup(group.label) })
      }
    }
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .shadow({ radius: 10, color: '#0F172A12', offsetY: 2 })
    .margin({ left: 16, right: 16, bottom: 14 })
    .clip(true)
  }

  @Builder
  ListView() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.TopBar()
        if (this.searching) {
        TextInput({ text: this.searchQuery, placeholder: '搜索会话' })
          .height(38)
          .margin({ left: 16, right: 16, bottom: 8 })
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .fontSize(14)
          .padding({ left: 10, right: 10 })
          .onChange((value: string) => {
            this.searchQuery = value
            this.applyFilter()
          })
        Text(this.searchQuery.trim() === '' ? '搜标题 / 预览 / 工作区'
          : ('匹配 ' + this.sessions.length.toString() + ' 个'))
          .fontSize(11)
          .fontColor(TEXT3)
          .width('100%')
          .padding({ left: 18, bottom: 6 })
        }

        this.AccountStrip()

        if (this.notice !== '') {
          Text(this.notice)
          .fontSize(12)
          .fontColor('#C62828')
          .padding({ left: 16, right: 16, bottom: 8 })
          .width('100%')
      }

      List() {
        ForEach(this.groups, (group: SessionGroup) => {
          ListItem() {
            this.GroupCard(group)
          }
        }, (group: SessionGroup) => this.groupKey(group))
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ top: 2 })

      if (this.sessions.length === 0 && !this.busy) {
        Text('还没有会话')
          .fontSize(13)
          .fontColor(TEXT3)
          .padding({ top: 40, bottom: 40 })
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F2F3F5')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }

  @Builder
  BlockView(block: MdBlock) {
    if (block.kind === 'heading') {
      Text(block.text)
        .fontSize(block.level <= 2 ? 19 : 17)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
        .width('100%')
    } else if (block.kind === 'code') {
      Column() {
        Text(block.text)
          .fontSize(12.5)
          .fontColor('#3A4048')
          .fontFamily('monospace')
          .lineHeight(18)
          .width('100%')
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#F6F7F9')
      .border({ width: 1, color: LINE })
      .borderRadius(10)
    } else if (block.kind === 'table') {
      Column() {
        ForEach(block.rows, (row: string[], rowIndex: number) => {
          Row() {
            ForEach(row, (cell: string, cellIndex: number) => {
              Text(cell)
                .fontSize(13)
                .fontColor(TEXT)
                .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                .layoutWeight(1)
                .padding({ left: 8, right: 8, top: 7, bottom: 7 })
            }, (cell: string, cellIndex: number) => rowIndex.toString() + '-' + cellIndex.toString())
          }
          .width('100%')
          .backgroundColor(rowIndex === 0 ? '#F4F6F9' : '#FFFFFF')
          .border({ width: { bottom: 0.5 }, color: LINE })
        }, (row: string[], rowIndex: number) => 'row-' + rowIndex.toString())
      }
      .width('100%')
      .border({ width: 1, color: LINE })
      .borderRadius(8)
      .clip(true)
    } else if (block.kind === 'quote') {
      Text(block.text)
        .fontSize(14.5)
        .lineHeight(23)
        .fontColor(TEXT2)
        .width('100%')
        .padding({ left: 11 })
        .border({ width: { left: 2 }, color: LINE })
    } else {
      Text(block.text)
        .fontSize(15)
        .lineHeight(24)
        .fontColor(TEXT)
        .width('100%')
    }
  }

  @Builder
  ToolRow(item: ChatItem) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(this.openTools.includes(item.callId ?? '') ? '▾' : '▸')
          .fontSize(10)
          .fontColor(TEXT3)
        Text(item.name ?? 'tool')
          .fontSize(13.5)
          .fontColor(TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.toolStatusLabel(item.status ?? 'running'))
          .fontSize(12)
          .fontColor((item.status ?? 'running') === 'running'
            ? '#8A5A00'
            : ((item.status ?? '') === 'error' ? '#C62828' : '#1A7F37'))
      }
      .width('100%')
      .padding({ top: 3, bottom: 3 })
      .onClick(() => { this.toggleTool(item.callId ?? '') })

      if (this.openTools.includes(item.callId ?? '') && (item.output ?? '') !== '') {
        Text(item.output ?? '')
          .fontSize(11.5)
          .fontColor('#40454D')
          .lineHeight(18)
          .width('100%')
          .padding(10)
          .backgroundColor(PANEL)
          .border({ width: 1, color: LINE })
          .borderRadius(8)
      }
    }
    .width('100%')
  }

  @Builder
  ItemView(item: ChatItem) {
    if (item.type === 'user') {
      Row() {
        Text(item.text ?? '')
          .fontSize(15)
          .fontColor(TEXT)
          .lineHeight(23)
          .padding({ left: 13, right: 13, top: 9, bottom: 9 })
          .backgroundColor('#F3F4F6')
          .borderRadius(14)
          .constraintSize({ maxWidth: '86%' })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    } else if (item.type === 'assistant') {
      Column({ space: 8 }) {
        ForEach(parseMarkdown(item.markdown ?? ''), (block: MdBlock, index: number) => {
          this.BlockView(block)
        }, (block: MdBlock, index: number) => index.toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (item.type === 'thought') {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(this.openTools.includes('t' + item.seq.toString()) ? '▾' : '▸')
            .fontSize(10)
            .fontColor(TEXT3)
          Text('思考 · ' + (item.text ?? '').length.toString() + ' 字')
            .fontSize(13)
            .fontColor(TEXT3)
          Blank()
        }
        .width('100%')
        .onClick(() => { this.toggleTool('t' + item.seq.toString()) })

        if (this.openTools.includes('t' + item.seq.toString())) {
          Text(item.text ?? '')
            .fontSize(13)
            .fontColor(TEXT3)
            .lineHeight(20)
            .width('100%')
            .padding({ left: 16 })
        }
      }
      .width('100%')
    } else if (item.type === 'diff') {
      Column() {
        Row() {
          Text('已编辑 ' + (item.files?.length ?? 0).toString() + ' 个文件')
            .fontSize(12.5)
            .fontColor(TEXT2)
          Blank()
          Text(this.diffSummary(item.files ?? []))
            .fontSize(11.5)
            .fontColor(TEXT3)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })

        ForEach(item.files ?? [], (file: DiffFile) => {
          Row({ space: 8 }) {
            Text(this.baseName(file.path))
              .fontSize(12)
              .fontColor(TEXT2)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('+' + file.adds.toString())
              .fontSize(11.5)
              .fontColor('#1A7F37')
            Text('−' + file.dels.toString())
              .fontSize(11.5)
              .fontColor('#C62828')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .border({ width: { top: 0.5 }, color: LINE })
        }, (file: DiffFile) => file.path + file.adds.toString())
      }
      .width('100%')
      .backgroundColor('#FCFCFD')
      .border({ width: 1, color: LINE })
      .borderRadius(10)
      .clip(true)
    } else if (item.type === 'tool') {
      this.ToolRow(item)
    } else if (item.type === 'tool-group') {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(this.openTools.includes('g' + item.seq.toString()) ? '▾' : '▸')
            .fontSize(10)
            .fontColor(TEXT3)
          Text((item.children?.length ?? 0).toString() + ' 个操作')
            .fontSize(13.5)
            .fontColor(TEXT2)
          Blank()
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .onClick(() => { this.toggleTool('g' + item.seq.toString()) })

        if (this.openTools.includes('g' + item.seq.toString())) {
          Column({ space: 6 }) {
            ForEach(item.children ?? [], (child: ChatItem) => {
              this.ToolRow(child)
            }, (child: ChatItem) => (child.callId ?? '') + child.seq.toString())
          }
          .width('100%')
          .padding({ left: 14 })
        }
      }
      .width('100%')
    } else if (item.type === 'tool-result') {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(item.status === 'error' ? '失败' : '完成')
            .fontSize(12)
            .fontColor(item.status === 'error' ? '#C62828' : '#1A7F37')
          Blank()
          Text(item.callId ?? '').fontSize(10).fontColor(TEXT3)
        }
        .width('100%')

        if ((item.output ?? '') !== '') {
          Text(item.output ?? '')
            .fontSize(11.5)
            .fontColor('#40454D')
            .lineHeight(18)
            .width('100%')
            .maxLines(8)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding(11)
      .backgroundColor(PANEL)
      .border({ width: 1, color: LINE })
      .borderRadius(10)
    }
  }

  @Builder
  ChatView() {
    Column() {
      Row({ space: 6 }) {
        Button('‹')
          .fontSize(30)
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .fontColor(TEXT)
          .margin({ left: -6 })
          .onClick(() => {
            this.stopPolling()
            this.screen = 'list'
            this.refresh()
          })
        Text(this.current?.title ?? '会话')
          .fontSize(15.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 8, right: 12, top: 8, bottom: 8 })

      Divider().strokeWidth(0.5).color(LINE)

      List({ space: 16, scroller: this.scroller }) {
        ForEach(this.items, (item: ChatItem) => {
          ListItem() {
            this.ItemView(item)
          }
        }, (item: ChatItem) => item.seq.toString() + '-' + item.type)
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 14 })
      .scrollBar(BarState.Off)

      if (this.pending) {
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color(ACCENT)
          Text(this.pendingText)
            .fontSize(12)
            .fontColor(TEXT3)
          Blank()
        }
        .width('100%')
        .padding({ left: 18, right: 18, bottom: 2 })
      }

      Column() {
        Row({ space: 6 }) {
          TextArea({ text: this.draft, placeholder: '发消息…' })
            .height(44)
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .fontSize(15)
            .padding({ left: 2, right: 2, top: 2, bottom: 2 })
            .onChange((value: string) => { this.draft = value })

          if (this.pending) {
            Text('■')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .backgroundColor('#40454D')
              .borderRadius(17)
              .onClick(() => { this.stopTurn() })
          } else {
            Text('↑')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.draft.trim() === '' ? '#D7DAE0' : ACCENT)
              .borderRadius(17)
              .enabled(this.draft.trim() !== '' && !this.busy)
              .onClick(() => {
                if (this.draft.trim() !== '' && !this.busy) {
                  this.send()
                }
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 6 }) {
          Text(this.permissionLabel())
            .fontSize(11.5)
            .fontColor(TEXT2)
            .border({ width: 1, color: LINE })
            .borderRadius(7)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .onClick(() => { this.openSettings() })
          Text(this.modelBadge())
            .fontSize(11.5)
            .fontColor(TEXT2)
            .border({ width: 1, color: LINE })
            .borderRadius(7)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .maxLines(1)
            .onClick(() => { this.openSettings() })
          Text('＋')
            .fontSize(18)
            .fontColor(TEXT2)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .backgroundColor('#F2F3F5')
            .borderRadius(15)
            .onClick(() => { this.pickImage() })
          Blank()
        }
        .width('100%')
        .padding({ top: 6 })
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#E3E5E8' })
      .borderRadius(16)
      .shadow({ radius: 8, color: '#0F172A0D', offsetY: 2 })
      .margin({ left: 12, right: 12, top: 8, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  /**
   * 系统返回（含右滑手势）：先逐级退回，退到底才允许离开应用。
   * 返回 true 表示这次返回已被消费。
   */
  onBackPress(): boolean {
    if (this.showHosts) {
      this.showHosts = false
      this.editingHostId = ''
      return true
    }
    if (this.showSheet) {
      this.showSheet = false
      return true
    }
    if (this.screen === 'chat') {
      this.stopPolling()
      this.screen = 'list'
      this.refresh()
      return true
    }
    if (this.screen === 'settings' || this.screen === 'usage' || this.screen === 'archived') {
      this.screen = 'list'
      return true
    }
    if (this.screen === 'pair') {
      // 从列表里点"添加电脑"进来的，退回列表；一台都没有时才允许退出。
      if (this.hosts().length > 0) {
        this.screen = 'list'
        this.refresh()
        return true
      }
      return false
    }
    return false
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.screen === 'pair') {
          this.PairView()
        } else if (this.screen === 'list') {
          this.ListView()
        } else if (this.screen === 'settings') {
          this.SettingsView()
        } else if (this.screen === 'archived') {
          this.ArchivedView()
        } else if (this.screen === 'usage') {
          this.UsageView()
        } else {
          this.ChatView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(BG)

      if (this.showSheet) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.showSheet = false })
        this.SettingsSheet()
      }

      if (this.showHosts) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.showHosts = false })
        this.HostSheet()
      }

      if (this.renaming) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.renaming = false })
        this.RenameSheet()
      }

      if (this.showActions) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.showActions = false })
        this.ActionSheet()
      }
      if (this.pendingApprovals.length > 0) {
        Column() {
          this.ApprovalDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  /* ------------------------------ 工具 ------------------------------ */

  private diffSummary(files: DiffFile[]): string {
    let adds = 0
    let dels = 0
    for (let i = 0; i < files.length; i++) {
      adds += files[i].adds
      dels += files[i].dels
    }
    return '+' + adds.toString() + ' −' + dels.toString()
  }

  private toggleTool(callId: string): void {
    if (callId === '') {
      return
    }
    if (this.openTools.includes(callId)) {
      this.openTools = this.openTools.filter((item: string) => item !== callId)
    } else {
      this.openTools = this.openTools.concat([callId])
    }
  }

  private toolStatusLabel(status: string): string {
    if (status === 'running') {
      return '运行中'
    }
    if (status === 'error') {
      return '失败'
    }
    return '完成'
  }

  /** 输入框下面的模型标签：名称 + 思考档位，和 PC 一致。 */
  private modelBadge(): string {
    const model = this.settings?.model ?? ''
    if (model === '') {
      return '模型'
    }
    let name = model
    const groups = this.catalog?.groups ?? []
    for (let g = 0; g < groups.length; g++) {
      const models = groups[g].models
      for (let m = 0; m < models.length; m++) {
        if (models[m].id === model) {
          name = models[m].name
        }
      }
    }
    const effort = this.settings?.effort ?? ''
    if (effort === '' || effort === 'off') {
      return name
    }
    if (effort === 'low') {
      return name + ' · Low'
    }
    if (effort === 'high') {
      return name + ' · High'
    }
    if (effort === 'max') {
      return name + ' · Max'
    }
    return name + ' · ' + effort
  }

  private permissionLabel(): string {
    const preset = this.permissionInfo?.preset ?? this.settings?.permission ?? ''
    if (preset === '') {
      return '权限未知'
    }
    return this.presetLabel(preset)
  }

  /** 极简 Markdown 清理：v1 只保留纯文本，代码块单独成行。 */
  private plain(markdown: string): string {
    return markdown
      .replace(/```[\s\S]*?```/g, (block: string) => block.replace(/```[a-zA-Z]*\n?/g, ''))
      .replace(/\*\*([^*]+)\*\*/g, '$1')
      .replace(/`([^`]+)`/g, '$1')
  }

  private shortTime(iso: string): string {
    const date = new Date(iso)
    const now = new Date()
    const sameDay = date.getFullYear() === now.getFullYear()
      && date.getMonth() === now.getMonth()
      && date.getDate() === now.getDate()
    if (sameDay) {
      const hh = date.getHours().toString().padStart(2, '0')
      const mm = date.getMinutes().toString().padStart(2, '0')
      return hh + ':' + mm
    }
    return (date.getMonth() + 1).toString() + '/' + date.getDate().toString()
  }
}
