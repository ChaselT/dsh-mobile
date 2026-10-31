import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'dsh', 'EntryAbility onCreate')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'dsh', 'loadContent failed: %{public}s', JSON.stringify(err))
        return
      }
      // 浅色状态栏文字，与白底界面一致
      const win = windowStage.getMainWindowSync()
      win.setWindowSystemBarProperties({
        statusBarContentColor: '#0F1115',
        navigationBarContentColor: '#0F1115'
      })
    })
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'dsh', 'EntryAbility onWindowStageDestroy')
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'dsh', 'EntryAbility onForeground')
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'dsh', 'EntryAbility onBackground')
  }
}
