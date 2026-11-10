import AppKit
import SwiftUI

@main
struct LocalMusicApp: App {

    /// 界面状态提到 App 这一层。
    ///
    /// 原来它住在 `ContentView` 里（`@StateObject`），菜单栏够不着 ——
    /// 而 2026-10-12 加的文件菜单要能直接驱动它（新建、载入、导出谱子、导入谱子）。
    /// 提到这儿之后，窗口和菜单看的是**同一份**状态，不存在两套。
    @StateObject private var vm = AppViewModel()

    /// ★ **把本程序钉在深色外观上**（2026-10-13 用户报的问题）。
    ///
    /// 他的原话：「**CS 的界面是纯黑的有的时候在框子里写东西的时候也是黑的，
    /// 很难被看见**」。
    ///
    /// **根因**：这套皮肤里的颜色**全是写死的暗色**（见 `Palette`），
    /// 可是**系统控件**（输入框里的字、滚动条、菜单、弹窗）默认**跟随系统外观**。
    /// 他的系统是**浅色模式** ⇒ `NSTextView` 的文字按浅色外观取色 = **黑的**，
    /// 黑字写在深色输入框里，几乎看不见。
    /// （实测证据：同一屏里「风格」框的字是亮的、「歌词」框的字是暗的 ——
    ///   差别来自控件各自的焦点/外观状态，不是字体设置。）
    ///
    /// ⇒ 钉成 `.darkAqua`：系统控件跟着走，和这套皮肤就一致了。
    /// **装在 App 的 init 里**（不是窗口的 onAppear）—— 菜单、弹窗、末尾那个
    /// 「关于」面板都要跟着变，它们比主窗口更早存在。
    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        Window("灵感路由 · MIR", id: "main") {
            ContentView(vm: vm)
        }
        .windowResizability(.contentMinSize)
        .commands {
            FileMenu(vm: vm)

            // ── 程序菜单里的「关于」──
            //
            // macOS 上「这程序是几版、这版多了什么」的习惯位置就在这儿。
            // 系统默认那条弹的是一个小面板（名字 + 号 + 版权），信息量近乎零；
            // 换成《版本历史》后，同一个位置能直接读到"多了什么"。
            // 正文与版本号都来自项目根的 `CHANGELOG.md`，见 `VersionHistory.swift`。
            CommandGroup(replacing: .appInfo) {
                Button("关于 灵感路由（MIR）") { VersionHistoryWindow.shared.open() }
            }

            // ── 帮助菜单 ──
            //
            // 系统默认在这里摆一条「My Songwriter 帮助」，指向本程序**没有**的
            // 帮助书，于是它一直是灰的 / 点开说"没有可用帮助"
            // （使用者 2026-10-11 指的就是它：「现在显示 not available」）。
            //
            // ⇒ 整组换掉：那条死路不再出现，换成**真的能打开**的两条。
            //   手册随 app 分发（`Contents/Resources/`，`gui/build.sh` 负责装），
            //   打开的逻辑与理由见 `UserGuide.swift`。
            CommandGroup(replacing: .help) {
                Button("版本历史") { VersionHistoryWindow.shared.open() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button(UserGuide.menuTitle) { UserGuide.open() }
                    .keyboardShortcut("?", modifiers: .command)
            }

            // ── 工作室菜单（2026-10-25）──
            //
            // 用户要的：「在有乐谱的情况下，点进入 studio 就带出那份乐谱」。
            // 有谱 → 走「送到 MIR Studio」那条（谱、词、风格一起过去）；
            // 没谱 → 只把页面打开，让他自己在里面导入 XML。
            CommandMenu("工作室") {
                Button("进入 MIR Studio…") { vm.enterScoreStudio() }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }

        // 偏好设置：⌘, 打开（试听走哪块声卡）
        Settings {
            PreferencesView()
        }
    }
}

// MARK: - 「文件」菜单

/// 建这个菜单的由头（用户 2026-10-12）：
/// 「把它生成的音乐保存在一个地方，让我事后进打谱软件继续打磨」。
/// 所以这里不是摆样子的菜单，**每一条都接着真动作**：
///
///   · **新建一首** / **载入一首…** —— 界面本来就有的「新写一首」和左栏点选，
///     这里给它们一个正经入口（以前只有按钮和鼠标点列表）。
///   · **导出谱子（XML / abc）** —— 存到「文稿 / My Songwriter 谱子」这个固定地方，
///     一键就完事；**按住 Option 点**则弹保存面板自己挑位置。
///     （改名之前导出的谱子还在「文稿 / Composer Step 谱子」里 —— 那个文件夹还在时
///     程序继续用它，不会让人找不到自己的谱子。）
///   · **导入谱子…** —— 外来的 XML / abc：只转格式，或者照它重唱一首
///     （拿选中那一首的词与风格，只把谱子换掉）。
///
/// 动作本身写在 `ScoreFiles.swift` 里 —— 这里是壳，那里是活。
struct FileMenu: Commands {

    @ObservedObject var vm: AppViewModel

    var body: some Commands {

        // 系统默认的「新建 / 打开」那一组：整组换成本程序真的有的两条。
        // （原先这一组被清空着 —— 那时候确实没有文件这回事。）
        CommandGroup(replacing: .newItem) {
            Button("新建一首") { vm.addNew() }
                .keyboardShortcut("n", modifiers: .command)
            Button("载入一首…") { vm.presentLoadPicker() }
                .keyboardShortcut("o", modifiers: .command)
        }

        // 生成那两条也放进菜单：界面上的按钮字小，菜单里一行能读全，
        // 而且键盘上够得着（不必先点一下输入框附近）。
        //
        // ★ 名字里把「出什么」写清楚，因为这两条**不是一回事**：
        //   · 生成一首 → 歌和谱子一起出（谱子和音频放在同一个文件夹里）
        //   · 先出谱子 → 只要乐谱，先不唱；出完再按「生成」就照它唱
        //   （用户 2026-10-12 特意交代过：直接点出歌的话，谱子和歌都会出来）
        CommandGroup(after: .newItem) {
            Button("生成（按上面选的模型出）") { vm.generate() }
                .disabled(vm.isRunning)
            Button("先出谱子（只要乐谱，先不唱）") { vm.generateScoreOnly() }
                .disabled(vm.isRunning || vm.engine != .yue2)
        }

        // 系统默认的「保存 / 导出」那一组：换成本程序的「导出谱子」。
        // ⌘S 给 XML 那条 —— 他要拿进 Dorico 的正是这一种。
        CommandGroup(replacing: .saveItem) {
            Button("导出谱子（MusicXML）") { vm.exportScore(as: .xml) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!vm.canExportScore)
            Button("导出谱子（abc）") { vm.exportScore(as: .abc) }
                .disabled(!vm.canExportScore)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("导入谱子…") { vm.importScore() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
