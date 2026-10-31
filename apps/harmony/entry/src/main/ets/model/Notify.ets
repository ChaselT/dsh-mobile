/**
 * 后台提醒：常驻任务 + 定时轮询审批，发现新的审批请求就发系统通知。
 *
 * 为什么用长时任务而不是推送：DSH 是局域网/隧道自建服务，没有厂商推送通道，
 * 只有让进程常驻才能在后天持续轮询。代价是状态栏会有一条常驻通知。
 */

import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager'
import notificationManager from '@ohos.notificationManager'
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent'
import { common } from '@kit.AbilityKit'

const NOTIFY_ID = 1001
const RUNNING_ID = 1000

let running = false

export async function ensureNotificationPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const enabled = await notificationManager.isNotificationEnabled()
    if (enabled) {
      return true
    }
    await notificationManager.requestEnableNotification(context)
    return true
  } catch (error) {
    return false
  }
}

async function buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
  return await wantAgent.getWantAgent({
    wants: [{
      bundleName: context.abilityInfo.bundleName,
      abilityName: 'EntryAbility'
    }],
    operationType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  })
}

export async function startBackgroundWatch(context: common.UIAbilityContext): Promise<boolean> {
  if (running) {
    return true
  }
  try {
    const agent = await buildWantAgent(context)
    await backgroundTaskManager.startBackgroundRunning(
      context,
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
      agent,
      () => {}
    )
    running = true
    await notificationManager.publish({
      id: RUNNING_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'DSH 遥控器',
          text: '正在后台保持连接，用于接收审批提醒'
        }
      }
    })
    return true
  } catch (error) {
    return false
  }
}

export async function stopBackgroundWatch(context: common.UIAbilityContext): Promise<void> {
  if (!running) {
    return
  }
  try {
    await backgroundTaskManager.stopBackgroundRunning(context)
  } catch (error) {
    // 已经停了
  }
  running = false
}

export async function notifyApproval(toolName: string): Promise<void> {
  try {
    await notificationManager.publish({
      id: NOTIFY_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'DSH 需要你审批',
          text: toolName === '' ? '有一个操作等待确认' : ('工具：' + toolName)
        }
      }
    })
  } catch (error) {
    // 通知失败不影响主流程
  }
}

export async function notifyTurnDone(title: string): Promise<void> {
  try {
    await notificationManager.publish({
      id: NOTIFY_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '任务已完成',
          text: title
        }
      }
    })
  } catch (error) {
    // 同上
  }
}
