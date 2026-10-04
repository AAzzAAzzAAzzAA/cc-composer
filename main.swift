// cc-composer — 在 Mac 本地写好一段话，再一次性送进 Ghostty 当前的终端。给通过 SSH 在远程机器上用 Claude Code 的人准备。
//
// 为高延迟 SSH 准备：打字、选字、改错都在本地完成，零延迟；
// 只有发送那一下（括号粘贴 + 回车）走一次网络。
//
// ⌥Space 打开/收起（只在 Ghostty 处于前台时生效，不影响其他应用）
// 输入框贴在 Ghostty 窗口底部，配色、字号跟随 Ghostty 配置，高度随内容增长
// 输入框里：↩ 发送并提交 · ⇧↩/⌥↩ 换行 · ⌘↩ 只粘贴不提交 · Esc 收起（草稿保留）· 发送后 ⌘Z 找回
//           ↑/↓ 翻发过的消息（规则同 Claude Code：多行时先在行间移动，到首行/末行再翻；只记文字）
//           开头打 / 弹出 Claude Code 的命令（带中文说明，中文也能搜）：↑↓ 选 · Tab 补全 · ↩ 直接发 · Esc 关列表；
//           /model、/effort 这类有固定选项的，补全命令后接着列出选项；/resume 后面列出最近的会话。
//           命令表是 VPS 上的 Claude Code 自己报的；只打 / 时常用的排前面；带着附件发命令时只发命令，附件留着
// 焦点不在输入框时它会变暗，这时按 Esc 也只收起输入框，不会传给终端（免得误中断 Claude）
// 草稿（连同已上传的图片和文件）存在硬盘上，程序重启后还在
// 打开期间跟着 Ghostty 窗口：切到别的应用时留在原处（别的窗口能盖住它，方便从访达拖文件），
// 窗口最小化/隐藏/切到别的桌面时收起（草稿保留）；按下最小化按钮的那一刻就先藏起来，不悬在原处
// 输入框开着时，把文件拖到 Ghostty 窗口任何位置都会进输入框（不会变成路径进 Claude 的输入框）
// 点附件：图片放大预览，其他文件用“快速查看”打开
//
// ⌘V 或拖进来：图片缩小后经 SSH 传到 VPS，发送时先把图片路径单独粘贴一次
// （Claude Code 只在“整段粘贴内容都是图片路径”时才把它们变成 [Image #N]），再粘贴文字；
// 其他文件原样传到 VPS，发送时把路径写在文字前面
//
// 配置：~/.config/cc-composer/config（远程机器的 SSH 主机名等，见下面的 Config）
//
// 调试：cc-composer --diagnose 打印读到的配色和窗口位置
//       cc-composer --upload <文件> 走一遍上传（图片会先压缩），打印 VPS 上的路径
//       cc-composer --selftest 检查剪贴板识别、历史和草稿存取、命令补全（用独立的剪贴板，不碰系统剪贴板）
//       cc-composer --commands 从 VPS 取一次命令表和 /resume 的会话列表，打印出来
//       cc-composer --render-commands <文字> <png> 把这段文字对应的候选列表画成图片

import Cocoa
import Carbon.HIToolbox
import Quartz
import UniformTypeIdentifiers

// MARK: - 配置

let ghosttyBundleID = "com.mitchellh.ghostty"
let hotKeyCode = UInt32(kVK_Space)
let hotKeyModifiers = UInt32(optionKey)
let hotKeyLabel = "⌥Space"
let submitDelay = 0.15  // 几次粘贴、回车之间的间隔（秒）

let escKeyCode = UInt32(kVK_Escape)
let maxImageEdge: CGFloat = 2000                     // 长边超过就缩小，模型那边本来也会缩
let pngSizeLimit = 1_500_000                         // PNG 超过这个大小（多半是照片）改用 JPEG
let historyLimit = 100                               // ↑ 能翻到的消息条数
let draftAttachmentMaxAge: TimeInterval = 6 * 86400  // 草稿里的附件放久了就不恢复（VPS 那边 7 天清理）
let commandsRefreshInterval: TimeInterval = 600      // 命令表（含新装的 skill）多久从 VPS 刷新一次

/// 配置文件 ~/.config/cc-composer/config：一行一个 key = value，# 开头的是注释。每次用到时现读，改了不用重启
///   ssh_host = myvps                   连远程机器用的 SSH 主机名或别名，要能免密登录。图片、文件、命令表、会话列表都靠它
///   remote_dir = ~/.cache/cc-composer  远程机器上存图片和文件的目录（可选），超过 7 天的自动清理
///   label.my-skill = 我的 skill        给命令加中文说明（可选，可以写多行；也能覆盖自带的说明）
struct Config {
    static let path = NSHomeDirectory() + "/.config/cc-composer/config"
    static let missingHost = "还没设置远程机器：在 ~/.config/cc-composer/config 里写一行 ssh_host = 你的 SSH 主机"

    var sshHost = ""
    var remoteDir = "$HOME/.cache/cc-composer"
    var labels: [String: String] = [:]

    static func load() -> Config {
        parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    static func parse(_ text: String) -> Config {
        var config = Config()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
            switch key {
            case "ssh_host": config.sshHost = value
            case "remote_dir": config.remoteDir = value.hasPrefix("~/") ? "$HOME/" + value.dropFirst(2) : value
            default: if key.hasPrefix("label.") { config.labels[String(key.dropFirst(6))] = value }
            }
        }
        return config
    }
}

// MARK: - Ghostty 外观

extension NSColor {
    /// Ghostty 配置里的颜色：#rrggbb 或 rrggbb
    convenience init?(ghosttyHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    func mixed(_ fraction: CGFloat, of other: NSColor) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }
}

struct GhosttyLook {
    var background = NSColor(ghosttyHex: "#282c34")!
    var foreground = NSColor(ghosttyHex: "#ffffff")!
    var opacity: CGFloat = 1
    var cursor: NSColor?
    var selectionBackground: NSColor?
    var selectionForeground: NSColor?
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var isDark: Bool { background.luminance < 0.5 }

    /// 读 Ghostty 实际生效的配置。优先级：用户显式写的 > 主题文件 > Ghostty 默认值
    static func load() -> GhosttyLook {
        var look = GhosttyLook()
        guard let cli = ghosttyAppURL?.appendingPathComponent("Contents/MacOS/ghostty").path else { return look }
        let effective = showConfig(cli, ["--changes-only=false"])
        let explicit = showConfig(cli, [])
        let theme = themeName(explicit["theme"] ?? effective["theme"] ?? "")
            .flatMap(themeFile)
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map(parse) ?? [:]
        func value(_ key: String) -> String? {
            [explicit[key], theme[key], effective[key]].lazy.compactMap { $0 }.first { !$0.isEmpty }
        }
        func color(_ key: String) -> NSColor? { value(key).flatMap(NSColor.init(ghosttyHex:)) }

        if let c = color("background") { look.background = c }
        if let c = color("foreground") { look.foreground = c }
        look.cursor = color("cursor-color")
        look.selectionBackground = color("selection-background")
        look.selectionForeground = color("selection-foreground")
        if let o = value("background-opacity").flatMap(Double.init) { look.opacity = CGFloat(min(max(o, 0.3), 1)) }
        let size = value("font-size").flatMap(Double.init).map { CGFloat($0) } ?? 13
        let family = value("font-family") ?? ""
        // Ghostty 默认的 JetBrains Mono 编译在它自己的程序里，系统里没有，退回 SF Mono
        look.font = (family.isEmpty ? nil : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return look
    }

    private static var ghosttyAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleID)
    }

    private static func showConfig(_ cli: String, _ args: [String]) -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["+show-config"] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// `key = value` 逐行解析；同名键（如多个 font-family）取第一个非空值
    private static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key.hasPrefix("#") { continue }
            if result[key]?.isEmpty ?? true { result[key] = value }
        }
        return result
    }

    /// 支持 `theme = 名字` 和 `theme = light:A,dark:B`（按系统外观挑一个）
    private static func themeName(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard raw.contains("light:") || raw.contains("dark:") else { return raw }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for part in raw.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == (dark ? "dark" : "light") { return kv[1] }
        }
        return nil
    }

    private static func themeFile(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.fileExists(atPath: name) ? name : nil }
        let home = NSHomeDirectory()
        var dirs = ["\(home)/.config/ghostty/themes", "\(home)/Library/Application Support/com.mitchellh.ghostty/themes"]
        if let app = ghosttyAppURL { dirs.append(app.appendingPathComponent("Contents/Resources/ghostty/themes").path) }
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Ghostty 窗口位置（CGWindowList，不需要额外权限）

enum GhosttyWindow {
    /// Ghostty 最前面的普通窗口：按屏幕层级从前往后找第一个
    static func frontID() -> CGWindowID? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let info = list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return (info?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }

    /// 窗口在屏幕上的位置，换算成 AppKit 坐标（主屏左下角为原点）；最小化或不在屏幕上时返回 nil
    static func frame(of id: CGWindowID) -> NSRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
              let primary = NSScreen.screens.first
        else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - 图片和文件：剪贴板 / 拖入 → 经 SSH 传到 VPS

struct UploadError: Error {
    let message: String
}

/// ⌘V 或拖进来的一样东西
enum Incoming {
    case image(NSImage)  // 会压缩后上传，发送时变成 [Image #N]
    case file(URL)       // 原样上传，发送时把 VPS 上的路径写进文字
    case folder(URL)     // 暂不支持
}

enum ImageUploader {
    private static let controlDir = NSHomeDirectory() + "/Library/Caches/cc-composer"

    static var sshOptions: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
         "-o", "ControlPath=\(controlDir)/cm-%C"]
    }

    /// 剪贴板（或拖动）里能当附件的东西：Finder 里的文件（图片按图片，其他原样），或截图之类的图片数据。
    /// 剪贴板里有正常文字时返回空，按文字粘贴（Keynote 之类复制文字时也会顺带一张预览图）
    @MainActor
    static func items(from pasteboard: NSPasteboard) -> [Incoming] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(item(forFile:))
        }
        // 浏览器“拷贝图像”有时会附带图片网址，这种仍当图片处理
        if let text = pasteboard.string(forType: .string),
           !(text.hasPrefix("http") && !text.contains(where: \.isWhitespace)) {
            return []
        }
        return NSImage(pasteboard: pasteboard).map { [.image($0)] } ?? []
    }

    @MainActor
    static func item(forFile url: URL) -> Incoming {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder(url) }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            return .image(image)
        }
        return .file(url)
    }

    /// 打开输入框时预热：没有复用连接就建一个，空闲 10 分钟后自动断开。不等结果
    static func warmUp() {
        try? FileManager.default.createDirectory(
            atPath: controlDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let host = Config.load().sshHost
        guard !host.isEmpty else { return }
        process.arguments = sshOptions + ["-o", "ControlMaster=auto", "-o", "ControlPersist=600", host, "true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 长边缩到 maxImageEdge 以内。截图用 PNG（字清楚）；太大的（多半是照片）改用 JPEG
    static func encode(_ image: NSImage) -> (data: Data, ext: String)? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxImageEdge / CGFloat(max(source.width, source.height)))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let png = render(source, width, height, opaque: false)
            .flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
        else { return nil }
        if png.count <= pngSizeLimit { return (png, "png") }
        // JPEG 没有透明通道，先铺白底，免得透明处变黑
        guard let jpeg = render(source, width, height, opaque: true)
            .flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) })
        else { return (png, "png") }
        return (jpeg, "jpg")
    }

    private static func render(_ image: CGImage, _ width: Int, _ height: Int, opaque: Bool) -> CGImage? {
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: alpha.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        if opaque {
            context.setFillColor(.white)
            context.fill(rect)
        }
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// 上传压缩好的图片，返回 VPS 上的绝对路径。会阻塞，要在后台线程调用
    static func upload(_ data: Data, ext: String) -> Result<String, UploadError> {
        let input = Pipe()
        return run(remotePath: "\(uniqueStamp()).\(ext)", input: input.fileHandleForReading) {
            // 大图会超过管道缓冲，写入放到另一个线程，免得和读输出互相等
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
            }
        }
    }

    /// 原样上传一个文件，保留文件名，放在 files/<时间>-<随机>/ 下免得重名。
    /// 直接从磁盘边读边传，不整个读进内存，多大的文件都行。会阻塞，要在后台线程调用
    static func upload(file url: URL) -> Result<String, UploadError> {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(UploadError(message: "读不了这个文件：\(url.lastPathComponent)"))
        }
        defer { try? handle.close() }
        return run(remotePath: "files/\(uniqueStamp())/\(safeName(url.lastPathComponent))", input: handle) {}
    }

    private static func uniqueStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    /// 文件名会拼进远端的 shell 命令（双引号里），去掉会被 shell 解释的字符；空格也换掉，路径贴给 Claude 时不会断开
    static func safeName(_ name: String) -> String {
        let unsafe = Set("\"$`\\/")
        let cleaned = String(name.map { unsafe.contains($0) || $0.isWhitespace || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } ? "_" : $0 })
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    private static func run(remotePath: String, input: FileHandle, afterLaunch: () -> Void) -> Result<String, UploadError> {
        // 先清理 7 天前的文件和空目录（目录要放了一小时以上才删，免得删掉别的上传刚建好的），再写入
        let config = Config.load()
        guard !config.sshHost.isEmpty else { return .failure(UploadError(message: Config.missingHost)) }
        let script = """
            d="\(config.remoteDir)"; f="$d/\(remotePath)"; mkdir -p "$d" && \
            find "$d" -type f -mtime +7 -delete; find "$d" -mindepth 1 -type d -empty -mmin +60 -delete 2>/dev/null; \
            mkdir -p "$(dirname "$f")" && cat > "$f" && printf %s "$f"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // ControlMaster=no：有预热好的连接就复用，没有就单独连一次。
        // 不能让上传进程自己变成常驻连接，否则它会一直占着输出管道，这里就永远读不完
        process.arguments = sshOptions + ["-o", "ControlMaster=no", config.sshHost, script]
        let output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(UploadError(message: "启动 ssh 失败：\(error.localizedDescription)")) }
        afterLaunch()

        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0, path.hasPrefix("/") else {
            let reason = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh 退出码 \(process.terminationStatus)"
            return .failure(UploadError(message: reason))
        }
        return .success(path)
    }
}

// MARK: - Ghostty AppleScript 桥

@MainActor
final class GhosttyBridge {
    private let script: NSAppleScript

    init() {
        script = NSAppleScript(source: """
            on targetinfo()
                tell application "Ghostty"
                    set t to focused terminal of selected tab of front window
                    return {id of t, name of t}
                end tell
            end targetinfo

            on findterm(tid)
                tell application "Ghostty"
                    try
                        return first terminal whose id is tid
                    on error
                        return focused terminal of selected tab of front window
                    end try
                end tell
            end findterm

            on sendmessage(tid, imgs, txt, submit, gap)
                set t to findterm(tid)
                tell application "Ghostty"
                    focus t
                    if imgs is not "" then
                        input text imgs to t
                        delay gap
                    end if
                    if txt is not "" then input text txt to t
                    if submit then
                        delay gap
                        send key "enter" to t
                    end if
                end tell
            end sendmessage

            on focusterm(tid)
                set t to findterm(tid)
                tell application "Ghostty" to focus t
            end focusterm
            """)!
        var err: NSDictionary?
        script.compileAndReturnError(&err)
    }

    private var ghosttyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).isEmpty
    }

    func targetInfo() -> (id: String, name: String)? {
        guard ghosttyRunning, case .success(let r) = call("targetinfo", []),
              let id = r.atIndex(1)?.stringValue else { return nil }
        return (id, r.atIndex(2)?.stringValue ?? "")
    }

    /// images 是空格分隔的图片路径，单独粘贴一次；text 再粘贴一次。成功返回 nil，失败返回错误信息
    func send(images: String, text: String, to tid: String, submit: Bool) -> String? {
        guard ghosttyRunning else { return "Ghostty 没有在运行" }
        let args: [NSAppleEventDescriptor] = [
            .init(string: tid), .init(string: images), .init(string: text), .init(boolean: submit), .init(double: submitDelay),
        ]
        if case .failure(let message) = call("sendmessage", args) { return message }
        return nil
    }

    func focus(_ tid: String) {
        guard ghosttyRunning else { return }
        _ = call("focusterm", [.init(string: tid)])
    }

    private enum CallResult {
        case success(NSAppleEventDescriptor)
        case failure(String)
    }

    /// 调用脚本里的具名 handler，参数直接以 Apple Event 描述符传入，不用拼接转义字符串
    private func call(_ handler: String, _ args: [NSAppleEventDescriptor]) -> CallResult {
        let params = NSAppleEventDescriptor.list()
        for (i, arg) in args.enumerated() { params.insert(arg, at: i + 1) }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setDescriptor(params, forKeyword: AEKeyword(keyDirectObject))
        var err: NSDictionary?
        let result = script.executeAppleEvent(event, error: &err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -1743 {
                return .failure("没有控制 Ghostty 的权限：系统设置 → 隐私与安全性 → 自动化 → cc-composer → 打开 Ghostty")
            }
            return .failure(err[NSAppleScript.errorMessage] as? String ?? "未知错误")
        }
        return .success(result)
    }
}

// MARK: - 全局快捷键（Carbon，不需要辅助功能权限）

@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        Self.actions[id] = action
        Self.installHandler()
    }

    /// 整个应用只装一个处理器，按快捷键编号分派
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            return MainActor.assumeIsolated {
                guard let action = HotKey.actions[id] else { return OSStatus(eventNotHandledErr) }
                action()
                return noErr
            }
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register() -> Bool {
        guard ref == nil else { return true }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4743_4D50), id: id)  // 'GCMP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

// MARK: - 输入框

/// 不激活自身的浮动面板：弹出时 Ghostty 仍是前台应用，输入法照常工作。
/// 也负责“快速查看”：系统的预览面板会顺着键盘焦点所在窗口找谁来提供文件
final class ComposerPanel: NSPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override var canBecomeKey: Bool { true }

    var quickLookURL: URL?
    var onQuickLookClosed: (() -> Void)?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookURL != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookURL = nil
        onQuickLookClosed?()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { quickLookURL as NSURL? }
}

/// 点缩略图时放大看图：盖在 Ghostty 窗口上，背景压暗，图片按比例缩放到放得下（小图最多放大 2 倍）。
/// 点任意位置、Esc、空格、回车都会关掉
@MainActor
final class ImagePreview {
    private let panel = ComposerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
    private let backdrop = PreviewBackdrop()
    private let imageView = NSImageView()
    var onClose: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = backdrop
        backdrop.addSubview(imageView)
        backdrop.onClose = { [weak self] in self?.close() }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
    }

    func show(_ image: NSImage, over area: NSRect) {
        panel.setFrame(area, display: false)
        backdrop.frame = NSRect(origin: .zero, size: area.size)
        let pixels = image.representations.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .first { $0.width > 0 && $0.height > 0 } ?? image.size
        // 按屏幕点数算：Retina 上 1 个点 = 2 个像素
        let natural = NSSize(width: pixels.width / (panel.screen?.backingScaleFactor ?? 2),
                             height: pixels.height / (panel.screen?.backingScaleFactor ?? 2))
        let scale = min((area.width - 80) / natural.width, (area.height - 80) / natural.height, 2)
        let size = NSSize(width: natural.width * scale, height: natural.height * scale)
        imageView.frame = NSRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2,
                                 width: size.width, height: size.height)
        imageView.image = image
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(backdrop)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        imageView.image = nil
        onClose?()
    }
}

final class PreviewBackdrop: NSView {
    var onClose: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func mouseDown(with event: NSEvent) { onClose?() }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape, kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter: onClose?()
        default: super.keyDown(with: event)
        }
    }
}

/// 接收粘贴和拖放进来的文件、图片（Composer 实现）
@MainActor
protocol DropHandler: AnyObject {
    func canAccept(_ pasteboard: NSPasteboard) -> Bool
    /// 能当附件处理就处理并返回 true；返回 false 时按普通文字粘贴 / 拖放
    func accept(_ pasteboard: NSPasteboard) -> Bool
}

let attachmentDragTypes: [NSPasteboard.PasteboardType] =
    [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

/// 文字区：⌘V、右键粘贴、拖进来的文件和图片先交给 DropHandler，文字照常处理
final class ComposerTextView: NSTextView {
    weak var dropHandler: DropHandler?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + attachmentDragTypes }

    override func paste(_ sender: Any?) {
        if dropHandler?.accept(.general) != true { super.paste(sender) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.canAccept(sender.draggingPasteboard) == true ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.canAccept(sender.draggingPasteboard) == true ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?.accept(sender.draggingPasteboard) == true || super.performDragOperation(sender)
    }
}

/// 圆角卡片，颜色由 Composer 按 Ghostty 配色设置。文字区以外的地方（边距、缩略图条）也能接住拖进来的文件
final class CardView: NSView {
    weak var dropHandler: DropHandler?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        registerForDraggedTypes(attachmentDragTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.canAccept(sender.draggingPasteboard) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?.accept(sender.draggingPasteboard) == true
    }
}

// MARK: - 草稿和历史（存在 ~/Library/Application Support/cc-composer/）

enum Store {
    struct Draft: Codable {
        struct Item: Codable {
            var kind: String  // "image" / "file"
            var remotePath: String
            var name: String?
            var thumbnail: String?  // 图片存的那份（上传的同一份），在 thumbnails/ 下
            var localPath: String?  // 文件在 Mac 上的原位置，“快速查看”用
            var created: Date
        }
        var text: String
        var items: [Item]
    }

    nonisolated(unsafe) static var directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/cc-composer")
    private static var thumbnails: URL { directory.appendingPathComponent("thumbnails") }

    static func loadDraft() -> Draft? { load(Draft.self, "draft.json") }
    static func saveDraft(_ draft: Draft) { save(draft, "draft.json") }
    static func loadHistory() -> [String] { load([String].self, "history.json") ?? [] }
    static func saveHistory(_ history: [String]) { save(history, "history.json") }
    static func loadCommandUsage() -> [String: Int] { load([String: Int].self, "command-usage.json") ?? [:] }
    static func saveCommandUsage(_ usage: [String: Int]) { save(usage, "command-usage.json") }

    /// 把上传的那份图片也存一份，返回文件名；草稿恢复后用它显示和放大预览（长边 2000 以内，放大也清楚）
    static func saveImage(_ data: Data, ext: String) -> String? {
        let name = UUID().uuidString + "." + ext
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        return (try? data.write(to: thumbnails.appendingPathComponent(name))) != nil ? name : nil
    }

    static func thumbnail(_ name: String) -> NSImage? {
        NSImage(contentsOf: thumbnails.appendingPathComponent(name))
    }

    /// 删掉草稿里已经不用的图片。刚存一分钟内的不删：可能是还在上传、还没记进附件的
    static func pruneThumbnails(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path)) ?? []
        for file in files where !names.contains(file) {
            let url = thumbnails.appendingPathComponent(file)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > 60 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ file: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(file), options: .atomic)
    }
}

// MARK: - 斜杠命令：开头打 / 弹出候选，Tab 补全、↩ 发送

/// 一条命令。参数有固定选项的（/model、/effort 之类），补全命令后接着列出选项
struct SlashCommand {
    var name: String
    var hint = ""   // 参数格式，显示在命令后面
    var label = ""  // 中文说明
    var aliases: [String] = []
    var options: [SlashOption] = []
    var takesArguments: Bool { !hint.isEmpty || !options.isEmpty }
}

struct SlashOption: Equatable {
    var value: String
    var label = ""
    var display: String?  // 列表里显示的名字，不设就显示 value（/resume 的会话显示时间，填进去的是会话 ID）
}

/// 候选列表里的一行。选中后输入框里的文字换成 text
struct SlashSuggestion: Equatable {
    var text: String   // 比如 "/compact "、"/model opus"
    var title: String  // 比如 "/compact"、"opus"
    var hint = ""
    var label = ""
}

/// 命令的中文说明和参数格式（参数格式留空就用 Claude Code 自己的）。
/// 包括 Claude Code 自带的命令和 skill；不在表里的命令显示它自己英文说明的第一句，
/// 自己装的 skill 可以在配置文件里用 label.<命令名> = 说明 加上
let slashCommandTable: [String: (hint: String, label: String)] = [
    "add-dir": ("<路径>", "添加工作目录"),
    "advisor": ("", "关键时刻请教更强的模型"),
    "artifacts": ("", "浏览发布过的 Artifact"),
    "auto-mode-setup": ("[选项]", "设置自动模式规则"),
    "autocompact": ("", "设置自动压缩的阈值"),
    "background": ("[提示]", "把会话放到后台"),
    "batch": ("<指令>", "大规模改动：先规划再并行执行"),
    "branch": ("[名字]", "从这里分叉出一个对话"),
    "btw": ("[问题]", "顺便问一句，不打断主对话"),
    "bug": ("[描述]", "报告 bug"),
    "cd": ("<路径>", "切换工作目录"),
    "claude-api": ("", "Claude API 参考"),
    "clear": ("[名字]", "清空对话，开新会话"),
    "code-review": ("[档位] [--fix] [--comment] [PR号/分支/路径]", "审查代码改动"),
    "color": ("", "设置提示栏颜色"),
    "compact": ("[压缩要求]", "压缩对话"),
    "config": ("", "打开设置"),
    "context": ("", "查看上下文用量"),
    "copy": ("", "复制上一条回复"),
    "dataviz": ("", "画图表"),
    "debug": ("[问题描述]", "打开调试日志排查问题"),
    "design": ("", "设计项目访问授权"),
    "design-sync": ("[项目名]", "把设计系统同步到 claude.ai"),
    "diff": ("", "查看代码改动"),
    "docs": ("", "协作文档"),
    "docx": ("", "处理 Word 文档"),
    "doctor": ("", "检查 Claude Code 的安装和配置"),
    "effort": ("<low|medium|high|xhigh|max|auto>", "设置思考强度"),
    "exit": ("", "退出 Claude Code"),
    "export": ("[文件名]", "导出对话"),
    "fast": ("[on|off]", "快速模式开关"),
    "feedback": ("[内容]", "给 Anthropic 反馈"),
    "fewer-permission-prompts": ("", "减少权限确认弹窗"),
    "focus": ("[on|off]", "专注视图开关"),
    "fork": ("<指令>", "派一个带着完整对话的后台代理"),
    "goal": ("[<条件> | clear]", "设定目标，没达成不停"),
    "google-workspace": ("", "Google 文档、表格、幻灯片"),
    "help": ("", "帮助"),
    "hooks": ("", "查看 hooks 配置"),
    "ide": ("", "IDE 集成"),
    "import": ("", "从别的 AI 工具导入配置"),
    "import-memory": ("", "导入别的助手的记忆"),
    "init": ("", "生成 CLAUDE.md"),
    "insights": ("", "使用情况分析报告"),
    "keybindings": ("", "打开快捷键配置"),
    "list-agents": ("", "列出能发消息的代理和会话"),
    "login": ("", "登录"),
    "logout": ("", "退出登录"),
    "loop": ("[间隔] [提示]", "定时重复执行"),
    "loops": ("", "管理定时循环"),
    "mcp": ("", "管理 MCP 服务器"),
    "memory": ("", "编辑 CLAUDE.md 和记忆"),
    "model": ("<模型>", "切换模型"),
    "morning": ("", "早间简报"),
    "output-style": ("[风格]", "切换输出风格"),
    "pdf": ("", "处理 PDF"),
    "permissions": ("", "管理工具权限"),
    "plan": ("[open|<描述>]", "进入计划模式"),
    "plugin": ("", "管理插件"),
    "pptx": ("", "处理 PPT"),
    "recap": ("", "一句话总结当前会话"),
    "release-notes": ("", "更新说明"),
    "reload-plugins": ("", "重新加载插件"),
    "reload-skills": ("", "重新加载 skill"),
    "rename": ("[名字]", "重命名对话"),
    "resume": ("[会话 ID 或关键词]", "恢复以前的对话"),
    "rewind": ("", "回退到之前的某一步"),
    "run": ("", "运行项目看改动效果"),
    "run-skill-generator": ("", "生成项目的运行 skill"),
    "schedule": ("", "云端定时任务"),
    "scroll-speed": ("", "调整滚轮速度"),
    "security-review": ("", "安全审查当前改动"),
    "setup-writing-style": ("", "学习你的写作风格"),
    "simplify": ("[目标]", "找改动里能简化的地方"),
    "skill-creator": ("", "创建或改进 skill"),
    "skill-doctor": ("", "找出没用上的 skill"),
    "skills": ("", "列出可用的 skill"),
    "status": ("", "查看版本、模型、账号"),
    "statusline": ("", "设置状态栏"),
    "subtask": ("<任务>", "派子代理带着完整上下文去做"),
    "tasks": ("", "查看后台任务"),
    "team-onboarding": ("", "生成新人上手指南"),
    "terminal-setup": ("", "设置终端的换行快捷键"),
    "theme": ("", "换主题"),
    "tui": ("[default|fullscreen]", "切换界面模式"),
    "ultrareview": ("", "云端多代理审查当前分支"),
    "update-config": ("", "改 Claude Code 设置"),
    "usage": ("", "查看用量和额度"),
    "usage-credits": ("", "用量额度设置"),
    "verify": ("", "验证改动确实有效"),
    "version": ("", "查看版本"),
    "workflows": ("", "查看工作流"),
    "xlsx": ("", "处理表格"),
]

/// 只在交互界面里能用的命令：VPS 上取到的命令表里没有它们，一直加上
let interactiveSlashCommands: Set<String> = [
    "add-dir", "artifacts", "background", "branch", "btw", "bug", "cd", "copy", "diff", "exit", "export",
    "feedback", "fork", "help", "hooks", "ide", "keybindings", "login", "logout", "loops", "memory", "permissions",
    "plan", "plugin", "release-notes", "resume", "rewind", "scroll-speed", "skills", "status", "statusline",
    "subtask", "tasks", "terminal-setup", "theme", "tui", "version", "workflows",
]

/// 不显示的命令：内部用的、已经改名或删掉的
let hiddenSlashCommands: Set<String> = [
    "__remote-workflow", "workflow-launch-exec", "heapdump", "extra-usage", "agents", "design-consent", "design-revoke",
]

let slashCommandAliases: [String: [String]] = [
    "clear": ["new", "reset"], "exit": ["quit"], "resume": ["continue"], "rewind": ["undo", "checkpoint"],
    "usage": ["cost", "stats"], "rename": ["name"], "background": ["bg"], "plugin": ["plugins"],
]

/// 参数选项的中文。"命令 选项" 优先，其次只按选项查
let slashOptionLabels: [String: String] = [
    "low": "低", "medium": "中", "high": "高", "xhigh": "很高", "max": "最高", "auto": "自动",
    "on": "开", "off": "关", "default": "默认", "ultra": "云端多代理深度审查",
    "red": "红", "blue": "蓝", "green": "绿", "yellow": "黄", "purple": "紫", "orange": "橙", "pink": "粉", "cyan": "青",
    "open": "打开", "clear": "清除", "consent": "授权", "revoke": "撤销",
    "reconnect": "重连", "enable": "启用", "disable": "停用", "hold": "按住说话", "tap": "点一下开始说话",
    "Proactive": "主动", "Concise": "简洁", "Explanatory": "讲解型", "Learning": "学习型",
    "tui default": "经典（滚动顺）", "tui fullscreen": "全屏",
]

/// 命令表：VPS 上的 Claude Code 自己报的（含 skill、插件），缓存在本地，打开输入框时过期了就在后台刷新
enum CommandCatalog {
    private static var cacheFile: URL { Store.directory.appendingPathComponent("commands.json") }

    static func load() -> [SlashCommand] {
        build(response: (try? Data(contentsOf: cacheFile)).flatMap(parse), labels: Config.load().labels)
    }

    static var isStale: Bool {
        let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Date().timeIntervalSince(modified ?? .distantPast) > commandsRefreshInterval
    }

    /// 让 VPS 上的 Claude Code 以无界面模式启动，只做初始化握手就退出：不调用模型、不花额度、不留会话记录，约 3 秒
    static func fetch() -> Result<Int, UploadError> {
        let script = """
            c=$(command -v claude || echo "$HOME/.local/bin/claude"); cd ~ && \
            printf '%s\\n' '{"type":"control_request","request_id":"gc","request":{"subtype":"initialize"}}' | \
            timeout 40 "$c" -p --input-format stream-json --output-format stream-json --verbose 2>/dev/null | \
            grep -m1 '"control_response"'
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let host = Config.load().sshHost
        guard !host.isEmpty else { return .failure(UploadError(message: Config.missingHost)) }
        process.arguments = ImageUploader.sshOptions + ["-o", "ControlMaster=no", host, script]
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(UploadError(message: "启动 ssh 失败：\(error.localizedDescription)")) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let response = parse(data), let commands = response["commands"] as? [Any] else {
            let reason = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "没取到命令表（退出码 \(process.terminationStatus)）"
            return .failure(UploadError(message: reason))
        }
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        return .success(commands.count)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = (json["response"] as? [String: Any])?["response"] as? [String: Any],
              response["commands"] is [Any] else { return nil }
        return response
    }

    /// 合成命令表。response 是 Claude Code 初始化时报的内容，nil（还没取到过）就先用自带的表
    static func build(response: [String: Any]?, labels: [String: String] = [:]) -> [SlashCommand] {
        var commands: [String: SlashCommand] = [:]
        var claudeHints: [String: String] = [:]
        func add(_ name: String, description: String = "") {
            let known = slashCommandTable[name]
            commands[name] = SlashCommand(name: name, hint: known?.hint ?? "",
                                          label: labels[name] ?? known?.label ?? shortDescription(description),
                                          aliases: slashCommandAliases[name] ?? [])
        }
        if let list = response?["commands"] as? [[String: Any]] {
            for item in list {
                guard let name = item["name"] as? String else { continue }
                let description = item["description"] as? String ?? ""
                if hiddenSlashCommands.contains(name) || name.hasPrefix("_")
                    || description.hasPrefix("(removed)") || description.hasPrefix("Renamed to") { continue }
                add(name, description: description)
                claudeHints[name] = item["argumentHint"] as? String ?? ""
            }
            for name in interactiveSlashCommands where commands[name] == nil { add(name) }
        } else {
            for name in slashCommandTable.keys { add(name) }
        }

        let models = (response?["models"] as? [[String: Any]] ?? []).compactMap { model -> SlashOption? in
            guard let value = model["value"] as? String else { return nil }
            if value == "default" {
                let resolved = (model["description"] as? String)?.components(separatedBy: " · ").first ?? ""
                return SlashOption(value: value, label: resolved.isEmpty ? "默认" : "默认 · \(resolved)")
            }
            return SlashOption(value: value, label: model["displayName"] as? String ?? "")
        }
        func label(_ value: String, of command: String) -> String {
            slashOptionLabels["\(command) \(value)"] ?? slashOptionLabels[value]
                ?? models.first { $0.label.lowercased().hasPrefix(value.lowercased()) }?.label ?? ""
        }
        for (name, var command) in commands {
            let claudeHint = claudeHints[name] ?? ""
            if command.hint.isEmpty { command.hint = claudeHint }
            // 选项以 Claude Code 给的参数格式为准（新版本加了选项也能跟上），它没给才用表里的
            let values = optionValues(claudeHint.contains("|") ? claudeHint : command.hint)
            command.options = values.map { SlashOption(value: $0, label: label($0, of: name)) }
            commands[name] = command
        }
        commands["model"]?.options = models.isEmpty
            ? [.init(value: "default", label: "默认"), .init(value: "opus", label: "Opus"),
               .init(value: "sonnet", label: "Sonnet"), .init(value: "haiku", label: "Haiku")]
            : models
        if let styles = response?["available_output_styles"] as? [String], !styles.isEmpty {
            commands["output-style"]?.options = styles.map { SlashOption(value: $0, label: label($0, of: "output-style")) }
        }
        return commands.values.sorted { $0.name < $1.name }
    }

    /// 从参数格式里取第一组固定选项："<low|medium|high>" → low/medium/high；
    /// "[auto|<tokens>]" → auto（尖括号的是要自己填的）；"[name]" 这种只有一个占位的没有选项
    static func optionValues(_ hint: String) -> [String] {
        var group = hint.replacingOccurrences(of: " | ", with: "|").split(separator: " ").first.map(String.init) ?? ""
        guard group.contains("|") else { return [] }
        if group.first == "[" || group.first == "<" { group.removeFirst() }
        return group.split(separator: "|").compactMap { token in
            guard !token.hasPrefix("<") else { return nil }
            let value = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]<>"))
            return value.range(of: "^[A-Za-z][A-Za-z0-9._-]*$", options: .regularExpression) != nil ? value : nil
        }
    }

    /// 不在表里的命令（新装的 skill 之类）：取英文说明的第一句，太长截断
    static func shortDescription(_ text: String) -> String {
        var line = text.replacingOccurrences(of: #"\s*\((user|project|plugin)\)$"#, with: "", options: .regularExpression)
        for separator in [". ", "。", "; ", "；", " — "] {
            if let range = line.range(of: separator) { line = String(line[..<range.lowerBound]) }
        }
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }
}

enum SlashCompleter {
    /// 输入框里的文字对应的候选：只有一行、以 / 开头时才有。
    /// 还在打命令名时列命令（名字开头匹配的在前，中文说明也能搜）；命令打完、空格后列它的参数选项
    static func suggestions(for text: String, in commands: [SlashCommand], usage: [String: Int] = [:]) -> [SlashSuggestion] {
        guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return [] }
        let body = text.dropFirst()
        if let space = body.firstIndex(of: " ") {
            let name = body[..<space].lowercased()
            let argument = String(body[body.index(after: space)...])
            guard !argument.contains(" "),
                  let command = commands.first(where: { $0.name == name || $0.aliases.contains(name) }) else { return [] }
            let query = argument.lowercased()
            if command.options.contains(where: { $0.value.lowercased() == query }) { return [] }  // 已经填好了
            return command.options
                .filter { query.isEmpty || $0.value.lowercased().hasPrefix(query) || $0.label.lowercased().contains(query)
                    || ($0.display ?? "").contains(argument) }
                .map { SlashSuggestion(text: "/\(command.name) \($0.value)", title: $0.display ?? $0.value, label: $0.label) }
        }
        let query = body.lowercased()
        guard !query.contains("/") else { return [] }  // 是路径，不是命令
        func rank(_ command: SlashCommand) -> Int? {
            if query.isEmpty || command.name == query || command.aliases.contains(query) { return 0 }
            if command.name.hasPrefix(query) { return 1 }
            if command.aliases.contains(where: { $0.hasPrefix(query) }) { return 2 }
            if command.name.contains(query) { return 3 }
            if command.label.lowercased().hasPrefix(query) { return 4 }  // 中文说明：开头就对上的在前
            if command.label.lowercased().contains(query) { return 5 }
            return nil
        }
        // 匹配程度一样时，用得多的排前面；只打了 / 时就是按使用次数排
        let ranked: [(command: SlashCommand, rank: Int, uses: Int)] = commands.compactMap { command in
            guard let rank = rank(command) else { return nil }
            return (command, rank, usage[command.name] ?? 0)
        }
        return ranked
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.uses != $1.uses { return $0.uses > $1.uses }
                return $0.command.name < $1.command.name
            }
            .map { item -> SlashSuggestion in
                let name = "/" + item.command.name
                let text = item.command.takesArguments ? name + " " : name
                return SlashSuggestion(text: text, title: name, hint: item.command.hint, label: item.command.label)
            }
    }
}

extension SlashCompleter {
    /// 整段文字是不是一条命令（开头是认识的命令名或别名）。是的话发送时只发命令，附件留着
    static func command(in text: String, among commands: [SlashCommand]) -> SlashCommand? {
        guard text.hasPrefix("/") else { return nil }
        let name = text.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        return commands.first { $0.name == name || $0.aliases.contains(name) }
    }
}

/// /resume 后面列出的会话：当前那个 Claude Code 所在目录下最近的 30 个会话，不含正在聊的这个。
/// “当前”看 ~/.claude/sessions/ 里正在运行的会话登记，有好几个时取最近有动静的那个。
/// Claude Code 的 /resume <会话 ID> 只认当前目录下的会话，所以不列别的目录的
enum SessionList {
    private static let script = #"""
        import glob, json, os, re
        home = os.path.expanduser("~/.claude")
        running = []
        for f in glob.glob(home + "/sessions/*.json"):
            try:
                s = json.load(open(f))
            except (OSError, ValueError):
                continue
            if s.get("kind") == "interactive" and os.path.exists("/proc/%d" % s.get("pid", 0)):
                running.append(s)
        def transcript(s):
            hit = glob.glob(home + "/projects/*/" + str(s.get("sessionId")) + ".jsonl")
            return hit[0] if hit else ""
        running.sort(key=lambda s: (os.path.getmtime(transcript(s)) if transcript(s) else 0, s.get("startedAt", 0)), reverse=True)
        current = running[0] if running else {}
        project = os.path.dirname(transcript(current)) if current else ""
        if not project and current.get("cwd"):
            project = home + "/projects/" + re.sub(r"[^A-Za-z0-9]", "-", current["cwd"])
        if not project:
            files = glob.glob(home + "/projects/*/*.jsonl")
            project = os.path.dirname(max(files, key=os.path.getmtime)) if files else ""
        out = []
        for f in sorted(glob.glob(project + "/*.jsonl"), key=os.path.getmtime, reverse=True):
            sid = os.path.basename(f)[:-6]
            if sid == current.get("sessionId"):
                continue
            seen = {}
            with open(f, "rb") as fh:
                for line in fh:
                    if b'"custom-title"' in line or b'"ai-title"' in line or b'"last-prompt"' in line:
                        try:
                            m = json.loads(line)
                        except ValueError:
                            continue
                        key = {"custom-title": "customTitle", "ai-title": "aiTitle", "last-prompt": "lastPrompt"}.get(m.get("type"))
                        if key and m.get(key):
                            seen[key] = m[key]
            title = seen.get("customTitle") or seen.get("aiTitle") or seen.get("lastPrompt")
            if title:
                out.append({"id": sid, "time": os.path.getmtime(f), "title": " ".join(title.split())})
            if len(out) >= 30:
                break
        print(json.dumps(out, ensure_ascii=False))
        """#

    static func fetch() -> Result<[SlashOption], UploadError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let host = Config.load().sshHost
        guard !host.isEmpty else { return .failure(UploadError(message: Config.missingHost)) }
        process.arguments = ImageUploader.sshOptions + ["-o", "ControlMaster=no", host, "python3 -"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(UploadError(message: "启动 ssh 失败：\(error.localizedDescription)")) }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let sessions = parse(data) else {
            let reason = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "没取到会话列表（退出码 \(process.terminationStatus)）"
            return .failure(UploadError(message: reason))
        }
        return .success(sessions)
    }

    static func parse(_ data: Data, now: Date = Date()) -> [SlashOption]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String, let time = item["time"] as? Double else { return nil }
            return SlashOption(value: id, label: item["title"] as? String ?? "",
                               display: timeLabel(Date(timeIntervalSince1970: time), now: now))
        }
    }

    /// 刚刚 / 今天 14:32 / 昨天 21:10 / 10月2日 09:05（按 Mac 的时区）
    static func timeLabel(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "刚刚" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 " + clock
        }
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

/// 输入框正上方的候选列表。不拿键盘焦点：↑↓、Tab、↩、Esc 由输入框转过来；点一行等于按 Tab
@MainActor
final class CompletionPopup {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    private let list = CompletionListView()
    private weak var parent: NSWindow?
    var onPick: ((Int) -> Void)?

    var items: [SlashSuggestion] { list.items }
    var isShown: Bool { !list.items.isEmpty }
    var selectedIndex: Int { list.selected }
    var current: SlashSuggestion? { list.items.indices.contains(list.selected) ? list.items[list.selected] : nil }

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = list
        list.onClick = { [weak self] index in self?.onPick?(index) }
    }

    /// 换一批候选：和上次一样（比如命令表刚刷新）就保留选中的那条，否则选第一条
    func show(_ items: [SlashSuggestion], above parent: NSWindow, look: GhosttyLook) {
        if items != list.items {
            list.selected = 0
            list.offset = 0
        }
        list.items = items
        list.look = look
        list.needsDisplay = true
        self.parent = parent
        place()
    }

    func move(_ delta: Int) {
        guard isShown else { return }
        list.selected = (list.selected + delta + list.items.count) % list.items.count
        list.scrollToSelection()
        list.needsDisplay = true
    }

    func hide() {
        list.items = []
        if let parent, panel.parent === parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    /// 贴在输入框正上方、和它一样宽。输入框可见时才真的显示（自检时只算候选，不出窗口）
    func place() {
        guard isShown, let parent, parent.isVisible else { return }
        let frame = NSRect(x: parent.frame.minX, y: parent.frame.maxY + 6, width: parent.frame.width, height: list.preferredHeight)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if panel.level != parent.level { panel.level = parent.level }
        if panel.parent == nil {
            parent.addChildWindow(panel, ordered: .above)
        } else if !panel.isVisible {
            panel.orderFront(nil)
        }
    }
}

final class CompletionListView: NSView {
    static let maxRows = 8
    private static let pad: CGFloat = 5
    // 触控板：跟着手指的部分按 0.6 倍走，松手后的惯性再减半，免得一甩就到底
    private static let scrollSpeed: CGFloat = 0.6
    private static let momentumSpeed: CGFloat = 0.5
    var items: [SlashSuggestion] = [] { didSet { widest = nil } }
    var selected = 0
    var offset: CGFloat = 0  // 往下滚了多少点（超过 maxRows 条时），按像素滚动，不是一行一跳
    var look = GhosttyLook() {
        didSet {
            layer?.backgroundColor = look.background.withAlphaComponent(max(look.opacity, 0.97)).cgColor
            layer?.borderColor = look.foreground.mixed(0.8, of: look.background).cgColor
        }
    }
    var onClick: ((Int) -> Void)?
    private var widest: CGFloat?  // 第一列按全部候选里最宽的算，滚动时第二列不会左右跳

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var rowHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: look.font)) + 6 }
    private var visibleHeight: CGFloat { CGFloat(min(items.count, Self.maxRows)) * rowHeight }
    var preferredHeight: CGFloat { visibleHeight + Self.pad * 2 }
    private var maxOffset: CGFloat { max(0, CGFloat(items.count) * rowHeight - visibleHeight) }

    /// 选中的那条滚进可见范围（键盘 ↑↓ 时）
    func scrollToSelection() {
        let rowTop = CGFloat(selected) * rowHeight
        offset = min(max(offset, rowTop + rowHeight - visibleHeight), rowTop)
    }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int(floor(offset / rowHeight)))
        let rows = Array(items.enumerated()).dropFirst(first).prefix(Self.maxRows + 1)  // 滚到一半时上下各露半行
        let dim = look.foreground.mixed(0.5, of: look.background)
        let labelFont = NSFont.systemFont(ofSize: look.font.pointSize)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: truncating])
        }
        // 第一列是命令（或选项）和参数格式，第二列是中文说明，各行对齐
        let widest = self.widest ?? items.map { text($0.title + "  " + $0.hint, look.font, dim).size().width }.max() ?? 0
        self.widest = widest
        let maxColumn = min(bounds.width * 0.5, text("M", look.font, dim).size().width * 34)  // 太长的参数格式截断，不把说明挤远
        let column = Self.pad + 12 + min(ceil(widest), maxColumn) + 24
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: Self.pad, width: bounds.width, height: visibleHeight)).addClip()
        let titleHeight = NSLayoutManager().defaultLineHeight(for: look.font)
        let labelHeight = NSLayoutManager().defaultLineHeight(for: labelFont)
        for (index, item) in rows {
            let row = NSRect(x: Self.pad, y: Self.pad + CGFloat(index) * rowHeight - offset, width: bounds.width - Self.pad * 2, height: rowHeight)
            let isSelected = index == selected
            if isSelected {
                (look.selectionBackground ?? look.foreground.withAlphaComponent(0.18)).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            let color = isSelected ? (look.selectionForeground ?? look.foreground) : look.foreground
            let title = NSMutableAttributedString(attributedString: text(item.title, look.font, color))
            if !item.hint.isEmpty { title.append(text("  " + item.hint, look.font, isSelected ? color.withAlphaComponent(0.6) : dim)) }
            title.draw(with: NSRect(x: row.minX + 12, y: row.midY - titleHeight / 2, width: column - row.minX - 36, height: titleHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            text(item.label, labelFont, isSelected ? color : dim)
                .draw(with: NSRect(x: column, y: row.midY - labelHeight / 2, width: row.maxX - column - 12, height: labelHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()
        if maxOffset > 0 {  // 右边一条细滚动条，看得出还有多少
            let track = bounds.insetBy(dx: 0, dy: Self.pad + 2)
            let thumb = max(16, track.height * CGFloat(Self.maxRows) / CGFloat(items.count))
            let y = track.minY + (track.height - thumb) * offset / maxOffset
            dim.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 6, y: y, width: 3, height: thumb), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= Self.pad, point.y < Self.pad + visibleHeight else { return }
        let index = Int(floor((point.y - Self.pad + offset) / rowHeight))
        if items.indices.contains(index) { onClick?(index) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxOffset > 0 else { return }
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            delta *= Self.scrollSpeed * (event.momentumPhase.isEmpty ? 1 : Self.momentumSpeed)
        } else {
            delta *= rowHeight  // 普通鼠标滚轮：一格一行
        }
        offset = min(max(offset - delta, 0), maxOffset)
        needsDisplay = true
    }
}

/// 输入框开着、又有文件正被拖动时，盖在整个 Ghostty 窗口上的接收层：拖到终端任何位置松手，文件都进输入框，
/// 不会变成一串路径进 Claude 自己的输入框。只排在 Ghostty 窗口上面，叠在它上面的别的窗口照常能接拖放
@MainActor
final class DropZone {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    private let view = DropZoneView()

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = view
        view.onFinished = { [weak self] in self?.hide() }
    }

    func show(over frame: NSRect, above windowID: CGWindowID, handler: DropHandler) {
        view.dropHandler = handler
        view.highlighted = false
        panel.setFrame(frame, display: true)
        panel.level = .normal
        panel.order(.above, relativeTo: Int(windowID))
    }

    func hide() {
        panel.orderOut(nil)
    }
}

final class DropZoneView: NSView {
    weak var dropHandler: DropHandler?
    var onFinished: (() -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(attachmentDragTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // 不能全透明：全透明的地方系统会让拖放直接穿过去
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(highlighted ? 0.45 : 0.3).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(highlighted ? 0.9 : 0.6).setStroke()
        shape.lineWidth = 2
        shape.setLineDash([8, 6], count: 2, phase: 0)
        shape.stroke()
        let text = NSAttributedString(string: "松开放进输入框", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(highlighted ? 1 : 0.8),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = dropHandler?.canAccept(sender.draggingPasteboard) == true
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?.accept(sender.draggingPasteboard) == true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onFinished?()
    }
}

/// 输入框里的一个附件：图片显示缩略图，其他文件显示图标 + 文件名；
/// 上面叠上传状态（转圈 / 完成 / 失败的红点）和右上角的 ×
final class AttachmentView: NSView {
    static let size = NSSize(width: 72, height: 46)
    static let fileWidth: CGFloat = 160
    private static let iconSize: CGFloat = 30
    private let imageLayer = CALayer()
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let isFile: Bool
    private let shade = NSView()
    private let spinner = NSProgressIndicator()
    private let badge = NSTextField(labelWithString: "!")
    private let onRemove: () -> Void

    /// fileName 为 nil 时按图片显示
    init(image: NSImage, fileName: String? = nil, onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        isFile = fileName != nil
        let width = isFile ? Self.fileWidth : Self.size.width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.size.height))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        imageLayer.contents = image
        imageLayer.contentsGravity = isFile ? .resizeAspect : .resizeAspectFill
        layer?.addSublayer(imageLayer)
        if let fileName {
            caption.stringValue = fileName
            caption.font = .systemFont(ofSize: 10.5)
            caption.maximumNumberOfLines = 2
            caption.lineBreakMode = .byTruncatingMiddle
            caption.cell?.truncatesLastVisibleLine = true
            caption.translatesAutoresizingMaskIntoConstraints = false
            addSubview(caption)
            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 + Self.iconSize + 6),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        spinner.style = .spinning
        spinner.controlSize = .small
        badge.font = .boldSystemFont(ofSize: 12)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 9
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "移除图片")!,
                             target: self, action: #selector(remove))
        close.isBordered = false
        close.refusesFirstResponder = true
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))

        translatesAutoresizingMaskIntoConstraints = false
        for view in [shade, spinner, badge, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            shade.leadingAnchor.constraint(equalTo: leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: trailingAnchor),
            shade.topAnchor.constraint(equalTo: topAnchor),
            shade.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        show(uploading: true, error: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageLayer.frame = isFile
            ? NSRect(x: 8, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
            : bounds
    }

    /// 点一下：图片放大看，文件用“快速查看”打开（右上角的 × 是删除，不走这里）
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}  // 接住按下，松开时才算点击

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// 颜色跟着 Ghostty 配色走（文件卡片有底色和文件名）
    func style(border: CGColor, fill: CGColor, text: NSColor) {
        layer?.borderColor = border
        layer?.backgroundColor = isFile ? fill : nil
        caption.textColor = text
    }

    func show(uploading: Bool, error: String?) {
        shade.isHidden = !uploading && error == nil
        badge.isHidden = error == nil
        toolTip = error ?? (isFile ? "点一下用“快速查看”打开" : "点一下放大看")
        if uploading {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    @objc private func remove() {
        onRemove()
    }
}

@MainActor
final class Attachment {
    enum State {
        case uploading
        case uploaded(path: String)
        case failed(String)
    }

    enum Kind {
        case image
        case file(name: String)
    }

    let kind: Kind
    let view: AttachmentView
    var image: NSImage?         // 图片原图（本次运行内），放大预览用
    var thumbnailFile: String?  // 图片存在草稿目录里的一份（就是上传的那份），草稿恢复后显示和预览用
    var localURL: URL?          // 文件在 Mac 上的位置，“快速查看”用
    var created = Date()
    var state = State.uploading {
        didSet {
            switch state {
            case .uploading: view.show(uploading: true, error: nil)
            case .uploaded: view.show(uploading: false, error: nil)
            case .failed(let message): view.show(uploading: false, error: message)
            }
        }
    }

    var isUploading: Bool { if case .uploading = state { true } else { false } }
    var isFailed: Bool { if case .failed = state { true } else { false } }
    var remotePath: String? { if case .uploaded(let path) = state { path } else { nil } }
    var isImage: Bool { if case .image = kind { true } else { false } }

    init(kind: Kind, preview: NSImage, onRemove: @escaping () -> Void) {
        self.kind = kind
        if case .file(let name) = kind {
            view = AttachmentView(image: preview, fileName: name, onRemove: onRemove)
        } else {
            view = AttachmentView(image: preview, onRemove: onRemove)
        }
    }
}

enum Layout {
    static let inset: CGFloat = 8          // 卡片离 Ghostty 窗口边缘的距离
    static let padTop: CGFloat = 10
    static let padBottom: CGFloat = 7
    static let hintGap: CGFloat = 4
    static let attachmentsGap: CGFloat = 8  // 缩略图条和文字之间
    static let minLines: CGFloat = 2
    static let minWidth: CGFloat = 360
    static let fallbackWidth: CGFloat = 680

    /// 有 Ghostty 窗口就贴在它底部、和它一样宽；没有就放在屏幕中间偏上。底边固定，内容变多时往上长
    static func panelFrame(window: NSRect?, height: CGFloat) -> NSRect {
        let screen = window.flatMap { w in NSScreen.screens.first { $0.frame.intersects(w) } } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        guard let window else {
            return NSRect(x: area.midX - fallbackWidth / 2, y: area.minY + area.height * 0.5, width: fallbackWidth, height: height)
        }
        let width = max(window.width - inset * 2, minWidth)
        // 窗口下沿被程序坞挡住时往上抬；全屏时没有程序坞，不用抬
        let fullScreen = window.height >= screen.frame.height - 1
        let bottom = fullScreen ? window.minY : max(window.minY, area.minY)
        return NSRect(x: window.midX - width / 2, y: bottom + inset, width: width, height: height)
    }

    static func maxHeight(window: NSRect?) -> CGFloat {
        max(140, (window?.height ?? NSScreen.main?.visibleFrame.height ?? 800) * 0.4)
    }
}

@MainActor
final class Composer: NSObject, NSTextViewDelegate, DropHandler {
    private let bridge = GhosttyBridge()
    private let panel: ComposerPanel
    private let card = CardView()
    private let scroll = NSScrollView()
    private let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: Layout.fallbackWidth, height: 40))
    private var escKey: HotKey!  // 输入框开着但焦点在终端时，拦下 Esc 只收起输入框
    private var history = Store.loadHistory()
    private var historyIndex: Int?  // nil：正在写自己的草稿；否则正显示 history[historyIndex]
    private var historyStash = ""    // 开始翻历史前正在写的内容，翻回来时还原
    private var showingHistory = false
    private var saveTimer: Timer?
    private var hintIsError = false
    private let imagePreview = ImagePreview()
    /// 用户打开了输入框、还没收起或发送。打开期间它跟着 Ghostty 窗口走
    private var isOpen = false
    private let dropZone = DropZone()
    private var seenDragCount = NSPasteboard(name: .drag).changeCount  // 已经看过的那次拖动
    private var releasedTicks = 0
    private let completion = CompletionPopup()
    private var commands = CommandCatalog.load()
    private var fetchingCommands = false
    private var commandUsage = Store.loadCommandUsage()  // 每个命令发过几次，只打 / 时常用的排前面
    private var sessions: [SlashOption] = []              // /resume 后面列的会话
    private var sessionsFetched = Date.distantPast
    private var fetchingSessions = false
    private var completionDismissed = false  // Esc 关掉了列表，或文字是翻历史带出来的：再改文字（或按 Tab）之前不弹
    private var minimizePressed = false  // 正按着 Ghostty 窗口的最小化按钮：先藏起来，免得窗口缩进程序坞时它还悬在原处
    private let prompt = NSTextField(labelWithString: "›")
    private let keysHint = NSTextField(labelWithString: "")
    private let targetHint = NSTextField(labelWithString: "")
    private let attachmentsRow = NSStackView()
    private var scrollBelowCard: NSLayoutConstraint!
    private var scrollBelowAttachments: NSLayoutConstraint!
    private var attachments: [Attachment] = []
    private var pendingSubmit: Bool?  // 图片还没传完时按了发送：传完后按这个值自动发
    private var look = GhosttyLook()
    private var targetID = ""
    private var targetName = ""
    private var windowID: CGWindowID?
    private var followTimer: Timer?

    override init() {
        panel = ComposerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.fallbackWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        escKey = HotKey(id: 2, keyCode: escKeyCode, modifiers: 0) { [weak self] in self?.dismiss() }

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 不跟着出现在所有桌面上：只待在 Ghostty 窗口所在的桌面，切走时由 follow() 收起、切回来再出现
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = card
        panel.onQuickLookClosed = { [weak self] in self?.quickLookClosed() }
        imagePreview.onClose = { [weak self] in self?.previewClosed() }
        completion.onPick = { [weak self] index in self?.pickSuggestion(index) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        // 和 NSTextView.scrollableTextView() 一样的搭法，只是换成能接文件的子类
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: Layout.fallbackWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 代码和命令要原样发送：关掉所有自动替换
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.delegate = self
        textView.dropHandler = self
        textView.updateDragTypeRegistration()
        card.dropHandler = self

        keysHint.font = .systemFont(ofSize: 11)
        keysHint.lineBreakMode = .byTruncatingTail
        targetHint.font = .systemFont(ofSize: 11)
        targetHint.lineBreakMode = .byTruncatingTail
        targetHint.alignment = .right
        targetHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        prompt.setContentHuggingPriority(.required, for: .horizontal)
        attachmentsRow.orientation = .horizontal
        attachmentsRow.spacing = 8
        attachmentsRow.isHidden = true

        for view in [prompt, attachmentsRow, scroll, keysHint, targetHint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        // 有图片时文字区下移到缩略图条下面，两条约束二选一
        scrollBelowCard = scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.padTop)
        scrollBelowAttachments = scroll.topAnchor.constraint(equalTo: attachmentsRow.bottomAnchor, constant: Layout.attachmentsGap)
        NSLayoutConstraint.activate([
            attachmentsRow.topAnchor.constraint(equalTo: card.topAnchor, constant: Layout.padTop),
            attachmentsRow.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            attachmentsRow.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            attachmentsRow.heightAnchor.constraint(equalToConstant: AttachmentView.size.height),
            prompt.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            prompt.topAnchor.constraint(equalTo: scroll.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            scrollBelowCard,
            keysHint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Layout.hintGap),
            keysHint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            keysHint.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Layout.padBottom),
            targetHint.firstBaselineAnchor.constraint(equalTo: keysHint.firstBaselineAnchor),
            targetHint.leadingAnchor.constraint(greaterThanOrEqualTo: keysHint.trailingAnchor, constant: 16),
            targetHint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])

        apply(look)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleShortcut(event) ? nil : event
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusChanged() }
            }
        }
        // 看别的应用里的鼠标拖动（只看鼠标，不需要额外权限）：有文件被拖起来就在 Ghostty 窗口上铺接收层
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let down = event.type == .leftMouseDown
            MainActor.assumeIsolated { self?.mouseClicked(down: down) }
        }
        restoreDraft()
    }

    /// 最小化按钮（红黄绿里的黄色）中心离 Ghostty 窗口左上角的距离，按截图量的；半宽 8 点，碰不到旁边两个按钮
    private static let minimizeButton = NSPoint(x: 36.8, y: 14.8)

    private func onMinimizeButton(_ frame: NSRect) -> Bool {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - frame.minX, dy = frame.maxY - mouse.y
        return abs(dx - Self.minimizeButton.x) <= 8 && abs(dy - Self.minimizeButton.y) <= 8
    }

    /// 按下最小化按钮就先藏起来，窗口再正常缩进程序坞；按下后挪开再松手（取消了）就重新出现。
    /// 全屏时左上角没有这几个按钮，那里是终端内容，不处理
    private func mouseClicked(down: Bool) {
        guard isOpen, let windowID, let frame = GhosttyWindow.frame(of: windowID) else { return }
        let fullScreen = NSScreen.screens.contains { $0.frame == frame }
        if down {
            guard !fullScreen, panel.isVisible, onMinimizeButton(frame) else { return }
            minimizePressed = true
            completion.hide()
            imagePreview.close()
            dropZone.hide()
            panel.orderOut(nil)
        } else if minimizePressed {
            minimizePressed = false
            if onMinimizeButton(frame) {
                close()  // 窗口马上就要缩进程序坞了
            } else {
                panel.orderFront(nil)
                focusChanged()
            }
        }
    }

    /// 每次拖动开始时系统会重写“拖动剪贴板”，计数随之变化；同一次拖动只看一次
    private func mouseDragged() {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != seenDragCount else { return }
        seenDragCount = pasteboard.changeCount
        guard isOpen, !dropZone.isVisible, canAccept(pasteboard),
              let windowID, let frame = GhosttyWindow.frame(of: windowID) else { return }
        dropZone.show(over: frame, above: windowID, handler: self)
    }

    /// 拖动结束（鼠标左键松开约 0.4 秒）后收起接收层。不立刻收：松手和放下文件的处理先后不定，
    /// 太早收起会让这次放下落空。放在 follow() 里每 0.1 秒查一次，不依赖别的应用转来的松手事件
    private func hideDropZoneAfterRelease() {
        guard dropZone.isVisible else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            releasedTicks += 1
            if releasedTicks >= 4 {
                dropZone.hide()
                releasedTicks = 0
            }
        } else {
            releasedTicks = 0
        }
    }

    /// 焦点不在输入框（比如点了一下终端去选字）时变暗，并拦下 Esc：按 Esc 只收起输入框，不会传给 Claude 去中断任务。
    /// 焦点在输入框里时 Esc 由输入框自己处理，输入法用 Esc 取消选字也不受影响。
    /// 只在 Ghostty 处于前台时拦，切到别的应用后 Esc 照常；看大图时 Esc 交给预览
    private func focusChanged() {
        let unfocused = panel.isVisible && !panel.isKeyWindow && !imagePreview.isVisible
        let ghosttyActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID
        card.alphaValue = unfocused ? 0.6 : 1
        if unfocused { completion.hide() }
        if unfocused && ghosttyActive { escKey.register() } else { escKey.unregister() }
        if !hintIsError { refreshHint() }
    }

    /// 前台应用变了（AppDelegate 通知）：马上调整层级和 Esc，不用等下一次跟随
    func frontAppChanged() {
        follow()
        focusChanged()
    }

    /// 首次运行时触发一次“自动化”授权弹窗（Ghostty 没开就跳过，免得把它拉起来）
    func warmUp() {
        _ = bridge.targetInfo()
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { dismiss() } else { present() }
    }

    func present() {
        // 从菜单栏打开时 Ghostty 可能被挡在后面，先把它叫到前面
        let fromBackground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier != ghosttyBundleID
        if let info = bridge.targetInfo() {
            targetID = info.id
            targetName = info.name
        }
        if fromBackground && !targetID.isEmpty { bridge.focus(targetID) }
        ImageUploader.warmUp()  // 先把到 VPS 的连接建好，贴图时就不用再等 3~4 秒握手
        refreshCommands()
        refreshSessions()

        apply(GhosttyLook.load())
        refreshHint()
        windowID = GhosttyWindow.frontID()
        layout()
        NSLog("present: window=%@ panel=%@", windowID.flatMap(GhosttyWindow.frame(of:)).map { NSStringFromRect($0) } ?? "nil",
              NSStringFromRect(panel.frame))

        isOpen = true
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        startFollowing()
        if fromBackground {
            // Ghostty 被激活后会抢回键盘焦点，稍等再拿回来
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if self.panel.isVisible { self.panel.makeKey() }
            }
        }
    }

    /// 用户主动收起：把键盘焦点还给目标终端
    func dismiss() {
        close()
        if !targetID.isEmpty { bridge.focus(targetID) }
    }

    /// 收起（草稿保留），不动键盘焦点：发送时、Ghostty 窗口被关掉时
    func close() {
        isOpen = false
        stopFollowing()
        imagePreview.close()
        dropZone.hide()
        completion.hide()
        if panel.isVisible { panel.orderOut(nil) }
        focusChanged()
        saveDraftNow()
    }

    /// 打开期间每 0.1 秒跟一次 Ghostty 窗口：位置大小、层级。
    /// 窗口离开屏幕（最小化、隐藏、切到别的桌面、关掉）就收起，草稿保留，回来后按 ⌥Space 再打开
    private func follow() {
        guard isOpen, !minimizePressed, let windowID else { return }  // 按着最小化按钮时别把它又调出来
        guard GhosttyWindow.frame(of: windowID) != nil else {
            close()
            return
        }
        layout()
        stack()
        completion.place()  // 输入框换了层级或位置，候选列表跟着
        if NSEvent.pressedMouseButtons & 1 != 0 { mouseDragged() }  // 万一拖动事件没转过来，按着左键时也查一次
        hideDropZoneAfterRelease()
    }

    /// 这个 Ghostty 窗口在最前面时浮在最上层；切到别的应用或别的 Ghostty 窗口时，排到这个窗口正上方：
    /// 别的窗口能正常盖住它，不会浮在其他应用上面挡东西，从访达拖文件过来时也还在
    private func stack() {
        guard let windowID else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let onTop = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || (front?.bundleIdentifier == ghosttyBundleID && GhosttyWindow.frontID() == windowID)
        if onTop {
            if panel.level != .floating {
                panel.level = .floating
                panel.orderFront(nil)
            }
        } else if panel.level != .normal {
            panel.level = .normal
            panel.order(.above, relativeTo: Int(windowID))
        }
    }

    // MARK: 外观与布局

    private func apply(_ look: GhosttyLook) {
        self.look = look
        let dim = look.foreground.mixed(0.55, of: look.background)
        card.layer?.backgroundColor = look.background.withAlphaComponent(look.opacity).cgColor
        card.layer?.borderColor = look.foreground.mixed(0.8, of: look.background).cgColor
        panel.appearance = NSAppearance(named: look.isDark ? .darkAqua : .aqua)

        textView.font = look.font
        textView.textColor = look.foreground
        textView.insertionPointColor = look.cursor ?? look.foreground
        textView.typingAttributes = [.font: look.font, .foregroundColor: look.foreground]
        textView.selectedTextAttributes = [
            .backgroundColor: look.selectionBackground ?? look.foreground.withAlphaComponent(0.25),
            .foregroundColor: look.selectionForeground ?? look.foreground,
        ]
        prompt.font = look.font
        prompt.textColor = look.foreground.mixed(0.4, of: look.background)
        keysHint.textColor = dim
        targetHint.textColor = dim
        for attachment in attachments { styleAttachment(attachment) }
    }

    private func styleAttachment(_ attachment: Attachment) {
        attachment.view.style(border: look.foreground.mixed(0.75, of: look.background).cgColor,
                              fill: look.foreground.mixed(0.92, of: look.background).cgColor,
                              text: look.foreground.mixed(0.2, of: look.background))
    }

    /// 底部提示行：出错时标红，有进行中的事（等上传）时显示状态，否则显示按键说明
    private func refreshHint(error: String? = nil, status: String? = nil) {
        hintIsError = error != nil
        if let error {
            keysHint.textColor = .systemRed
            keysHint.stringValue = "⚠️ " + error
        } else {
            keysHint.textColor = look.foreground.mixed(0.55, of: look.background)
            if let status {
                keysHint.stringValue = status
            } else if panel.isVisible && !panel.isKeyWindow {
                keysHint.stringValue = "点一下继续输入 · Esc 收起（草稿保留）"
            } else if completion.isShown {
                keysHint.stringValue = "Tab 补全 · ↩ 发送 · ↑↓ 选择 · Esc 关闭列表"
            } else {
                keysHint.stringValue = "↩ 发送 · ⇧↩ 换行 · ↑ 历史 · / 命令 · ⌘V/拖入 图片和文件 · Esc 收起"
            }
        }
        targetHint.stringValue = targetName.isEmpty ? "" : "→ \(targetName)"
    }

    /// 贴到 Ghostty 窗口底部，高度按内容计算；跟随期间每 0.1 秒调用一次，没变化就不动
    private func layout() {
        let window = windowID.flatMap(GhosttyWindow.frame(of:))
        var frame = Layout.panelFrame(window: window, height: panel.frame.height)
        if frame.width != panel.frame.width {
            panel.setFrame(frame, display: false)
            card.layoutSubtreeIfNeeded()  // 先按新宽度排版，才能算出正确的文字高度
        }
        frame.size.height = contentHeight(max: Layout.maxHeight(window: window))
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func contentHeight(max maxHeight: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 100 }
        layoutManager.ensureLayout(for: container)
        let lineHeight = layoutManager.defaultLineHeight(for: look.font)
        let textHeight = Swift.max(layoutManager.usedRect(for: container).height, lineHeight * Layout.minLines)
        let images = attachments.isEmpty ? 0 : AttachmentView.size.height + Layout.attachmentsGap
        let chrome = Layout.padTop + images + Layout.hintGap + keysHint.intrinsicContentSize.height + Layout.padBottom
        return Swift.min(ceil(textHeight + chrome), maxHeight)
    }

    private func startFollowing() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    func textDidChange(_ notification: Notification) {
        if !showingHistory { historyIndex = nil }  // 翻到历史后自己改了，就以改过的内容为准
        completionDismissed = showingHistory  // 翻历史翻到命令不弹列表，不然 ↑ 就被列表接走了
        layout()
        updateCompletion()
        scheduleSave()
    }

    // MARK: 斜杠命令补全

    private func updateCompletion() {
        guard !textView.hasMarkedText() else { return }  // 输入法还在选字，先不动
        let wasShown = completion.isShown
        if textView.string.hasPrefix("/resume ") && Date().timeIntervalSince(sessionsFetched) > 20 { refreshSessions() }
        var catalog = commands
        if let resume = catalog.firstIndex(where: { $0.name == "resume" }) { catalog[resume].options = sessions }
        let items = completionDismissed ? [] : SlashCompleter.suggestions(for: textView.string, in: catalog, usage: commandUsage)
        if items.isEmpty { completion.hide() } else { completion.show(items, above: panel, look: look) }
        if wasShown != completion.isShown && !hintIsError { refreshHint() }
    }

    /// Tab 或点一行：把选中的那条填进输入框。命令有参数的话后面留个空格，接着列出它的选项
    private func pickSuggestion(_ index: Int) {
        guard completion.items.indices.contains(index) else { return }
        showText(completion.items[index].text, fromHistory: false)
        if panel.isVisible {
            panel.makeKey()
            panel.makeFirstResponder(textView)
        }
    }

    private func completeWithTab() -> Bool {
        if completion.isShown {
            pickSuggestion(completion.selectedIndex)
            return true
        }
        // 列表被 Esc 关了、或是翻历史带出来的命令：Tab 重新打开。以 / 开头时不插入制表符
        guard textView.string.hasPrefix("/") else { return false }
        completionDismissed = false
        updateCompletion()
        return true
    }

    /// 会话列表每次打开输入框都在后台取一次（很快），打到 /resume 时超过 20 秒没取也再取
    private func refreshSessions() {
        guard !fetchingSessions else { return }
        fetchingSessions = true
        Task.detached {
            let result = SessionList.fetch()
            await MainActor.run {
                self.fetchingSessions = false
                switch result {
                case .success(let sessions):
                    self.sessions = sessions
                    self.sessionsFetched = Date()
                    if self.textView.string.hasPrefix("/resume ") { self.updateCompletion() }
                case .failure(let error):
                    NSLog("sessions: %@", error.message)
                }
            }
        }
    }

    /// 命令表过期了（或从没取过）就在后台从 VPS 取一次，取到后马上换上
    private func refreshCommands() {
        guard CommandCatalog.isStale, !fetchingCommands else { return }
        fetchingCommands = true
        Task.detached {
            let result = CommandCatalog.fetch()
            await MainActor.run {
                self.fetchingCommands = false
                if case .failure(let error) = result { NSLog("commands: %@", error.message); return }
                self.commands = CommandCatalog.load()
                if self.completion.isShown { self.updateCompletion() }
            }
        }
    }

    // MARK: 发送与按键

    private func send(submit: Bool) {
        var text = textView.string
        while text.last?.isNewline == true { text.removeLast() }
        let hasText = !text.allSatisfy(\.isWhitespace)
        // 斜杠命令只发命令本身，附件留在输入框里等下一条：路径拼在前面的话 Claude Code 就不当它是命令了
        let command = hasText ? SlashCompleter.command(in: text, among: commands) : nil
        let attachments = command == nil ? self.attachments : []
        guard hasText || !attachments.isEmpty else { NSSound.beep(); return }
        if attachments.contains(where: \.isFailed) {
            refreshHint(error: "有附件上传失败（鼠标停在红点上看原因），点 × 删掉后再发")
            return
        }
        if attachments.contains(where: \.isUploading) {
            pendingSubmit = submit
            refreshHint(status: "附件还在上传，传完会自动发送…")
            return
        }

        // 图片路径单独粘贴一次（变成 [Image #N]）；文件路径一行一个写在文字前面
        let images = attachments.filter(\.isImage).compactMap(\.remotePath).joined(separator: " ")
        var message = attachments.filter { !$0.isImage }.compactMap(\.remotePath).joined(separator: "\n")
        if hasText { message += (message.isEmpty ? "" : "\n") + text }
        let body = message.isEmpty ? "" : (images.isEmpty ? message : " " + message)
        close()
        if let error = bridge.send(images: images, text: body, to: targetID, submit: submit) {
            refreshHint(error: error)
            isOpen = true
            panel.makeKeyAndOrderFront(nil)
            startFollowing()
            return
        }
        if hasText { remember(text) }
        if let command {
            commandUsage[command.name, default: 0] += 1
            Store.saveCommandUsage(commandUsage)
        }
        // 清空草稿但保留撤销记录：发错了可以 ⌘Z 找回文字（附件不会回来）
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: all, replacementString: "") {
            textView.replaceCharacters(in: all, with: "")
            textView.didChangeText()
        }
        if command == nil {
            self.attachments.forEach { $0.view.removeFromSuperview() }
            self.attachments.removeAll()
            attachmentsChanged()
        }
        historyIndex = nil
        historyStash = ""
        saveDraftNow()
        refreshHint()
    }

    // MARK: 历史（规则同 Claude Code：只记文字，连续重复的只记一条）

    private func remember(_ text: String) {
        if history.last != text { history.append(text) }
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        Store.saveHistory(history)
    }

    /// ↑/↓：光标在第一行（↑）或最后一行（↓）时翻历史，否则返回 false 照常移动光标。
    /// 翻过最新一条时回到开始翻之前正在写的内容
    private func browseHistory(up: Bool) -> Bool {
        guard textView.selectedRange().length == 0, !textView.hasMarkedText() else { return false }
        let lines = caretLines()
        if up {
            guard lines.first, !history.isEmpty else { return false }
            let index = (historyIndex ?? history.count) - 1
            guard index >= 0 else { return true }  // 已经是最早的一条
            if historyIndex == nil { historyStash = textView.string }
            historyIndex = index
            showText(history[index])
        } else {
            guard lines.last, let current = historyIndex else { return false }
            if current + 1 < history.count {
                historyIndex = current + 1
                showText(history[current + 1])
            } else {
                historyIndex = nil
                showText(historyStash)
            }
        }
        return true
    }

    /// 换上一段文字（可 ⌘Z 撤销），光标放到末尾
    private func showText(_ text: String, fromHistory: Bool = true) {
        showingHistory = fromHistory
        defer { showingHistory = false }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: all, replacementString: text) {
            textView.replaceCharacters(in: all, with: text)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// 光标是否在第一 / 最后一个显示行（自动换行也算一行）
    private func caretLines() -> (first: Bool, last: Bool) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return (true, true) }
        let length = (textView.string as NSString).length
        if length == 0 { return (true, true) }
        layoutManager.ensureLayout(for: container)
        let caret = textView.selectedRange().location
        let caretLine: NSRect
        if caret >= length && !layoutManager.extraLineFragmentRect.isEmpty {
            caretLine = layoutManager.extraLineFragmentRect  // 文字以换行结尾、光标在最后的空行上
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
            caretLine = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let firstLine = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let used = layoutManager.usedRect(for: container)
        return (caretLine.minY <= firstLine.minY + 0.5, caretLine.maxY >= used.maxY - 0.5)
    }

    // MARK: 草稿（文字和已传好的附件，存在硬盘上）

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDraftNow() }
        }
    }

    func saveDraftNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        let items = attachments.compactMap { attachment -> Store.Draft.Item? in
            guard let path = attachment.remotePath else { return nil }  // 还没传完的不存
            switch attachment.kind {
            case .image:
                return .init(kind: "image", remotePath: path, thumbnail: attachment.thumbnailFile, created: attachment.created)
            case .file(let name):
                return .init(kind: "file", remotePath: path, name: name, localPath: attachment.localURL?.path, created: attachment.created)
            }
        }
        // 翻历史时存的是开始翻之前自己写的内容，不是正显示的历史消息
        Store.saveDraft(.init(text: historyIndex == nil ? textView.string : historyStash, items: items))
        Store.pruneThumbnails(keeping: Set(attachments.compactMap(\.thumbnailFile)))
    }

    private func restoreDraft() {
        guard let draft = Store.loadDraft() else { return }
        textView.string = draft.text
        textView.setSelectedRange(NSRange(location: (draft.text as NSString).length, length: 0))
        for item in draft.items where Date().timeIntervalSince(item.created) < draftAttachmentMaxAge {
            let attachment: Attachment
            if item.kind == "file" {
                let name = item.name ?? (item.remotePath as NSString).lastPathComponent
                attachment = makeAttachment(.file(name: name), preview: fileIcon(name))
                attachment.localURL = item.localPath.map { URL(fileURLWithPath: $0) }
            } else {
                let preview = item.thumbnail.flatMap(Store.thumbnail)
                    ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
                attachment = makeAttachment(.image, preview: preview)
                attachment.thumbnailFile = item.thumbnail
            }
            attachment.created = item.created
            attachment.state = .uploaded(path: item.remotePath)
        }
    }

    // MARK: 附件：⌘V / 右键粘贴 / 拖进来的图片和文件

    func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || (pasteboard.string(forType: .string) == nil && NSImage.canInit(with: pasteboard))
    }

    func accept(_ pasteboard: NSPasteboard) -> Bool {
        let items = ImageUploader.items(from: pasteboard)
        if !items.isEmpty {
            add(items)
            return true
        }
        // “照片”“邮件”之类拖出来的是待生成的文件：先让对方写到临时目录，再当普通文件处理
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !promises.isEmpty else { return false }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cc-composer-drops/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { [weak self] url, error in
                MainActor.assumeIsolated {
                    if let error {
                        self?.refreshHint(error: "拿不到拖进来的文件：\(error.localizedDescription)")
                    } else {
                        self?.add([ImageUploader.item(forFile: url)])
                    }
                }
            }
        }
        return true
    }

    private func add(_ items: [Incoming]) {
        var folders: [String] = []
        for item in items {
            switch item {
            case .image(let image): addImage(image)
            case .file(let url): addFile(url)
            case .folder(let url): folders.append(url.lastPathComponent)
            }
        }
        if !folders.isEmpty { refreshHint(error: "暂不支持文件夹：\(folders.joined(separator: "、"))") }
        if panel.isVisible {
            panel.makeKey()
            panel.makeFirstResponder(textView)
        }
    }

    private func addImage(_ image: NSImage) {
        let attachment = makeAttachment(.image, preview: image)
        attachment.image = image
        Task.detached {
            let encoded = ImageUploader.encode(image)
            let saved = encoded.flatMap { Store.saveImage($0.data, ext: $0.ext) }  // 草稿恢复后显示和预览用
            let result = encoded.map { ImageUploader.upload($0.data, ext: $0.ext) }
                ?? .failure(UploadError(message: "读不了这张图片"))
            await MainActor.run {
                attachment.thumbnailFile = saved
                self.finishUpload(attachment, result)
            }
        }
    }

    private func addFile(_ url: URL) {
        let attachment = makeAttachment(.file(name: url.lastPathComponent), preview: NSWorkspace.shared.icon(forFile: url.path))
        attachment.localURL = url
        Task.detached {
            let result = ImageUploader.upload(file: url)
            await MainActor.run { self.finishUpload(attachment, result) }
        }
    }

    private func fileIcon(_ name: String) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
    }

    private func makeAttachment(_ kind: Attachment.Kind, preview: NSImage) -> Attachment {
        weak var weakAttachment: Attachment?  // 闭包里只弱引用，免得附件和自己的视图互相持有
        let attachment = Attachment(kind: kind, preview: preview) { [weak self] in
            if let attachment = weakAttachment { self?.removeAttachment(attachment) }
        }
        weakAttachment = attachment
        attachment.view.onClick = { [weak self] in
            if let attachment = weakAttachment { self?.preview(attachment) }
        }
        styleAttachment(attachment)
        attachments.append(attachment)
        attachmentsRow.addArrangedSubview(attachment.view)
        attachmentsChanged()
        return attachment
    }

    private func finishUpload(_ attachment: Attachment, _ result: Result<String, UploadError>) {
        guard attachments.contains(where: { $0 === attachment }) else { return }  // 传完前已经被删掉了
        switch result {
        case .success(let path):
            attachment.state = .uploaded(path: path)
            scheduleSave()
        case .failure(let error):
            attachment.state = .failed(error.message)
            pendingSubmit = nil
            refreshHint(error: "上传失败：\(error.message)")
        }
        if let submit = pendingSubmit, !attachments.contains(where: \.isUploading) {
            pendingSubmit = nil
            send(submit: submit)
        }
    }

    // MARK: 预览：图片放大看，其他文件用“快速查看”

    private func preview(_ attachment: Attachment) {
        switch attachment.kind {
        case .image:
            guard let image = attachment.image ?? attachment.thumbnailFile.flatMap(Store.thumbnail) else { return }
            let area = windowID.flatMap(GhosttyWindow.frame(of:)) ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            imagePreview.show(image, over: area)
            focusChanged()
        case .file(let name):
            guard let url = attachment.localURL, FileManager.default.fileExists(atPath: url.path) else {
                refreshHint(error: "原文件已不在 Mac 上了：\(name)")
                return
            }
            panel.quickLookURL = url
            panel.makeKey()  // 快速查看会从键盘焦点所在的窗口找文件，这里就是输入框
            guard let quickLook = QLPreviewPanel.shared() else { return }
            if quickLook.isVisible { quickLook.reloadData() } else { quickLook.makeKeyAndOrderFront(nil) }
        }
    }

    private func previewClosed() {
        guard isOpen, panel.isVisible else { return }
        panel.makeKey()
        focusChanged()
    }

    /// 快速查看会把本应用切到前台；用户在它上面按空格/Esc 关掉时，把前台还给 Ghostty、焦点放回输入框。
    /// 如果是点了别处导致它关掉的，就不抢焦点
    private func quickLookClosed() {
        guard isOpen, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        else { return }
        if !targetID.isEmpty { bridge.focus(targetID) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if self.isOpen && self.panel.isVisible { self.panel.makeKey() }
        }
    }

    private func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0 === attachment }
        attachment.view.removeFromSuperview()
        attachmentsChanged()
        scheduleSave()
        if !attachments.contains(where: \.isFailed) { refreshHint() }
        if let submit = pendingSubmit, !attachments.contains(where: \.isUploading) {
            pendingSubmit = nil
            send(submit: submit)
        }
        panel.makeFirstResponder(textView)
    }

    private func attachmentsChanged() {
        let hasImages = !attachments.isEmpty
        attachmentsRow.isHidden = !hasImages
        scrollBelowCard.isActive = !hasImages
        scrollBelowAttachments.isActive = hasImages
        layout()
    }

    private func insertNewline() {
        textView.insertText("\n", replacementRange: textView.selectedRange())
    }

    // 回车类按键走这里。输入法组字时的回车由输入法自己消化，不会走到这里
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewline()
            } else {
                let submit = !flags.contains(.command)
                // 列表开着：发的是选中的那条（和 Claude Code 里一样）。⌘↩ 只粘贴时保留结尾空格，方便接着在终端里写参数
                if let choice = completion.current {
                    showText(submit ? choice.text.trimmingCharacters(in: .whitespaces) : choice.text, fromHistory: false)
                }
                send(submit: submit)
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            return completeWithTab()
        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            insertNewline()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if completion.isShown {  // 先关列表，再按一次才收起输入框
                completionDismissed = true
                updateCompletion()
            } else {
                dismiss()
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if completion.isShown { completion.move(-1); return true }
            return browseHistory(up: true)
        case #selector(NSResponder.moveDown(_:)):
            if completion.isShown { completion.move(1); return true }
            return browseHistory(up: false)
        case #selector(NSResponder.deleteBackward(_:)):
            // 光标在最开头时退格，删掉最后一张图片
            guard textView.selectedRange() == NSRange(location: 0, length: 0), let last = attachments.last else { return false }
            removeAttachment(last)
            return true
        default:
            return false
        }
    }

    // MARK: 自检用（--selftest）

    func setTextForTest(_ text: String) {
        textView.string = text
        textView.didChangeText()
        moveCaretForTest(to: (text as NSString).length)
    }

    func typeForTest(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    var suggestionsForTest: [String] { completion.items.map(\.title) }

    func moveCaretForTest(to location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func commandForTest(_ selector: Selector) -> (handled: Bool, text: String) {
        let handled = textView(textView, doCommandBy: selector)
        return (handled, textView.string)
    }

    // 面板不激活应用，菜单栏的 ⌘ 快捷键不一定能送到这里，所以自己处理常用的几个
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !textView.hasMarkedText() else { return false }
        let shift = flags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: send(submit: false)
        case kVK_ANSI_W where !shift: dismiss()
        case kVK_ANSI_A where !shift: textView.selectAll(nil)
        case kVK_ANSI_C where !shift: textView.copy(nil)
        case kVK_ANSI_X where !shift: textView.cut(nil)
        case kVK_ANSI_V where !shift: textView.paste(nil)  // 附件判断在 ComposerTextView.paste 里
        case kVK_ANSI_Z: shift ? textView.undoManager?.redo() : textView.undoManager?.undo()
        default: return false
        }
        return true
    }
}

// MARK: - 应用

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let composer = Composer()
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!

    func applicationWillTerminate(_ notification: Notification) {
        composer.saveDraftNow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey(id: 1, keyCode: hotKeyCode, modifiers: hotKeyModifiers) { [unowned self] in self.composer.toggle() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "cc-composer")
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "打开输入框（在 Ghostty 里按 \(hotKeyLabel)）", action: #selector(openComposer), keyEquivalent: "")
        openItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updateHotKey(for: NSWorkspace.shared.frontmostApplication)

        composer.warmUp()
    }

    @objc private func openComposer() {
        composer.present()
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        updateHotKey(for: notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    /// 快捷键只在 Ghostty 处于前台时注册，其他应用里 ⌥Space 照常可用。
    /// 切到别的应用时输入框不收起（比如要从访达拖文件进来），由 Composer 调整层级
    private func updateHotKey(for app: NSRunningApplication?) {
        if app?.bundleIdentifier == ghosttyBundleID {
            let ok = hotKey.register()
            openItem.title = ok
                ? "打开输入框（在 Ghostty 里按 \(hotKeyLabel)）"
                : "打开输入框（\(hotKeyLabel) 被其他应用占用了）"
        } else if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            hotKey.unregister()
        }
        composer.frontAppChanged()
    }
}

/// --diagnose：不弹界面，打印读到的配色、字体和计算出的位置，方便远程排查
@MainActor
func diagnose() {
    _ = NSApplication.shared
    let look = GhosttyLook.load()
    func hex(_ c: NSColor?) -> String {
        guard let c = c?.usingColorSpace(.sRGB) else { return "-" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    print("background \(hex(look.background))  foreground \(hex(look.foreground))  opacity \(look.opacity)  dark \(look.isDark)")
    print("cursor \(hex(look.cursor))  selection \(hex(look.selectionBackground))/\(hex(look.selectionForeground))")
    print("font \(look.font.fontName) \(look.font.pointSize)pt")
    let id = GhosttyWindow.frontID()
    let window = id.flatMap(GhosttyWindow.frame(of:))
    print("ghostty window \(id.map(String.init) ?? "nil") \(window.map(NSStringFromRect) ?? "nil")")
    print("panel (2 lines) \(NSStringFromRect(Layout.panelFrame(window: window, height: 60)))  max height \(Layout.maxHeight(window: window))")
    for screen in NSScreen.screens { print("screen \(NSStringFromRect(screen.frame)) visible \(NSStringFromRect(screen.visibleFrame))") }
}

/// --upload <文件>：不弹界面，走一遍上传（图片先压缩，其他文件原样），方便远程排查
@MainActor
func uploadForTest(_ file: String) -> Int32 {
    let started = Date()
    let result: Result<String, UploadError>
    switch ImageUploader.item(forFile: URL(fileURLWithPath: file)) {
    case .image(let image):
        guard let encoded = ImageUploader.encode(image) else {
            print("读不了图片：\(file)")
            return 1
        }
        print("image, encoded \(encoded.ext) \(encoded.data.count) bytes")
        result = ImageUploader.upload(encoded.data, ext: encoded.ext)
    case .file(let url):
        print("file, uploading as is")
        result = ImageUploader.upload(file: url)
    case .folder:
        print("是文件夹，不支持")
        return 1
    }
    switch result {
    case .success(let path):
        print("uploaded \(path) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return 0
    case .failure(let error):
        print("failed: \(error.message)")
        return 1
    }
}

/// --selftest：不弹界面、不碰系统剪贴板，检查剪贴板识别、文件名清理、草稿和历史的存取、↑/↓ 翻历史
@MainActor
func selfTest() -> Int32 {
    _ = NSApplication.shared
    var failures = 0
    func check(_ ok: Bool, _ label: String) {
        print((ok ? "✓ " : "✗ ") + label)
        if !ok { failures += 1 }
    }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("cc-composer-selftest-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    // 测试素材：一张图片、一个 PDF、一个文件夹
    let png = tmp.appendingPathComponent("截图 1.png")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try? rep.representation(using: .png, properties: [:])?.write(to: png)
    let pdf = tmp.appendingPathComponent("report v2.pdf")
    try? Data("%PDF-1.4\n".utf8).write(to: pdf)
    let folder = tmp.appendingPathComponent("某个文件夹")
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

    // 独立命名的剪贴板，不影响系统剪贴板
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cc-composer-selftest"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([png, pdf, folder] as [NSURL])
    let items = ImageUploader.items(from: pasteboard)
    let kinds = items.map { item -> String in
        switch item {
        case .image: "image"
        case .file: "file"
        case .folder: "folder"
        }
    }
    check(kinds == ["image", "file", "folder"], "Finder 复制的图片 / PDF / 文件夹分别认成 \(kinds)")
    pasteboard.clearContents()
    pasteboard.setString("普通文字", forType: .string)
    check(ImageUploader.items(from: pasteboard).isEmpty, "纯文字按文字粘贴")
    pasteboard.clearContents()
    pasteboard.writeObjects([NSImage(contentsOf: png)!])
    if case .image = ImageUploader.items(from: pasteboard).first { check(true, "截图之类的图片数据当图片") } else { check(false, "截图之类的图片数据当图片") }

    check(ImageUploader.safeName("a b\"$`\\/c.txt") == "a_b_____c.txt", "文件名里的特殊字符换成 _：\(ImageUploader.safeName("a b\"$`\\/c.txt"))")
    check(ImageUploader.safeName("报告 2026.pdf") == "报告_2026.pdf", "中文文件名保留")

    // 草稿和历史存到临时目录
    Store.directory = tmp.appendingPathComponent("store")
    Store.saveDraft(.init(text: "草稿内容", items: [.init(kind: "file", remotePath: "/x/report.pdf", name: "report.pdf", created: Date())]))
    let draft = Store.loadDraft()
    check(draft?.text == "草稿内容" && draft?.items.first?.name == "report.pdf", "草稿存取")
    let saved = (try? Data(contentsOf: png)).flatMap { Store.saveImage($0, ext: "png") }
    check(saved.flatMap(Store.thumbnail) != nil, "草稿图片存取")

    // ↑/↓：历史两条（第二条有两行），正在写“正在写的草稿”
    Store.saveHistory(["第一条", "第二条\n第二行"])
    Store.saveDraft(.init(text: "", items: []))
    let composer = Composer()
    composer.setTextForTest("正在写的草稿")
    let up = #selector(NSResponder.moveUp(_:)), down = #selector(NSResponder.moveDown(_:))
    check(composer.commandForTest(up) == (true, "第二条\n第二行"), "↑ 翻到最近一条")
    check(composer.commandForTest(up).handled == false, "多行时光标不在首行：↑ 先移动光标，不翻")
    composer.moveCaretForTest(to: 0)
    check(composer.commandForTest(up) == (true, "第一条"), "光标到首行后 ↑ 继续往前翻")
    check(composer.commandForTest(up) == (true, "第一条"), "已经是最早的一条：停住")
    check(composer.commandForTest(down) == (true, "第二条\n第二行"), "↓ 往回翻")
    check(composer.commandForTest(down) == (true, "正在写的草稿"), "翻过最新一条：还原正在写的草稿")
    check(composer.commandForTest(down).handled == false, "不在翻历史时 ↓ 照常移动光标")

    // 配置文件
    let config = Config.parse("""
        # 注释
        ssh_host = myvps   # 行尾注释
        remote_dir = ~/uploads
        label.my-skill = 我的 skill
        """)
    check(config.sshHost == "myvps" && config.remoteDir == "$HOME/uploads" && config.labels == ["my-skill": "我的 skill"]
          && Config.parse("").remoteDir == "$HOME/.cache/cc-composer", "配置文件：ssh_host / remote_dir / label.xxx")

    // 斜杠命令：用一份假的 Claude Code 命令表
    let reported: [String: Any] = [
        "commands": [
            ["name": "compact", "description": "Free up context", "argumentHint": "<optional custom summarization instructions>"],
            ["name": "effort", "description": "Set effort level", "argumentHint": "<low|medium|high|xhigh|max|auto>"],
            ["name": "advisor", "description": "Consult a stronger model", "argumentHint": "[fable|opus|sonnet|off]"],
            ["name": "goal", "description": "Set a goal", "argumentHint": "[<condition> | clear]"],
            ["name": "model", "description": "Set the AI model", "argumentHint": "<model>"],
            ["name": "usage", "description": "Show usage", "argumentHint": ""],
            ["name": "my-skill", "description": "Does a thing. More details here. (user)", "argumentHint": ""],
            ["name": "__remote-workflow", "description": "internal", "argumentHint": ""],
            ["name": "agents", "description": "(removed) Ask Claude", "argumentHint": ""],
        ],
        "models": [
            ["value": "default", "displayName": "Default (recommended)", "description": "Opus 5.5 · Best for everyday"],
            ["value": "opus", "displayName": "Opus 5.5", "description": "x"],
            ["value": "claude-fable-5-1", "displayName": "Fable 5.1", "description": "x"],
        ],
        "available_output_styles": ["default", "Concise"],
    ]
    let catalog = CommandCatalog.build(response: reported, labels: ["my-skill": "我的 skill"])
    func suggest(_ text: String) -> [SlashSuggestion] { SlashCompleter.suggestions(for: text, in: catalog) }
    func titles(_ text: String) -> [String] { suggest(text).map(\.title) }
    check(suggest("/comp").first == SlashSuggestion(text: "/compact ", title: "/compact", hint: "[压缩要求]", label: "压缩对话"),
          "/comp → /compact（中文说明、参数格式，补全后留空格）")
    check(titles("/压缩") == ["/compact"], "中文也能搜：/压缩 → /compact")
    check(SlashCompleter.suggestions(for: "/压缩", in: CommandCatalog.build(response: nil)).map(\.title) == ["/compact", "/autocompact"],
          "说明开头就对上的排前面：/压缩 → /compact 在 /autocompact 前")
    check(titles("/cost") == ["/usage"], "别名：/cost → /usage")
    check(titles("/res").first == "/resume", "交互界面专用的命令也在：/res → \(titles("/res"))")
    check(titles("/my") == ["/my-skill"] && suggest("/my").first?.label == "我的 skill", "配置文件里的 label.xxx 给命令加说明")
    check(CommandCatalog.build(response: reported).first { $0.name == "my-skill" }?.label == "Does a thing", "没配说明的 skill 显示英文说明第一句")
    check(!titles("/").contains("/__remote-workflow") && !titles("/").contains("/agents"), "内部的、删掉的命令不显示")
    check(titles("/effort ") == ["low", "medium", "high", "xhigh", "max", "auto"], "/effort 后面列出选项：\(titles("/effort "))")
    check(suggest("/effort x").map(\.text) == ["/effort xhigh"] && suggest("/effort x").first?.label == "很高", "/effort x → xhigh（很高）")
    check(titles("/effort 最") == ["max"], "选项也能用中文搜：最 → max")
    check(suggest("/advisor ").map(\.label) == ["Fable 5.1", "Opus 5.5", "", "关"], "/advisor 的选项按模型列表起名：\(suggest("/advisor ").map(\.label))")
    check(titles("/goal ") == ["clear"], "[<condition> | clear] 只取 clear")
    check(titles("/model ") == ["default", "opus", "claude-fable-5-1"] && suggest("/model ").first?.label == "默认 · Opus 5.5",
          "/model 的选项来自模型列表")
    check(titles("/output-style ") == [] || titles("/output-style ") == ["default", "Concise"], "输出风格")
    check(titles("/effort high").isEmpty && titles("/compact 保留进度").isEmpty, "参数填好了、或是自由文字：不弹")
    check(titles("/tmp/a.txt").isEmpty && titles("看看 /tmp").isEmpty && titles("/comp\n第二行").isEmpty, "路径、普通文字、多行：不弹")
    check(CommandCatalog.optionValues("[reconnect|enable|disable [<server>|all]]") == ["reconnect", "enable", "disable"]
          && CommandCatalog.optionValues("[auto|<tokens>]") == ["auto"] && CommandCatalog.optionValues("[name]").isEmpty
          && CommandCatalog.optionValues("consent | revoke") == ["consent", "revoke"], "从参数格式取选项")

    // 常用的排前面；认出整段文字是不是命令
    let usage = ["usage": 5, "compact": 2]
    check(Array(SlashCompleter.suggestions(for: "/", in: catalog, usage: usage).map(\.title).prefix(2)) == ["/usage", "/compact"],
          "只打 /：用得多的排前面")
    check(SlashCompleter.suggestions(for: "/co", in: catalog, usage: ["compact": 1]).first?.title == "/compact"
          && SlashCompleter.suggestions(for: "/co", in: catalog, usage: ["usage": 9]).first?.title == "/compact",
          "打了字还是先按匹配程度（/co：名字开头的 compact 排在别名对上的 usage 前）")
    check(SlashCompleter.command(in: "/compact 保留进度", among: catalog)?.name == "compact"
          && SlashCompleter.command(in: "/COST", among: catalog)?.name == "usage"
          && SlashCompleter.command(in: "/tmp/a.txt 看看", among: catalog) == nil
          && SlashCompleter.command(in: "看看 /compact", among: catalog) == nil, "认出命令（发送时附件留着）")

    // /resume 后面列会话：显示时间，填进去的是会话 ID，也能按标题搜
    var noon = DateComponents()
    noon.year = 2026; noon.month = 10; noon.day = 4; noon.hour = 12
    let now = Calendar.current.date(from: noon)!
    let listed = Data("""
        [{"id": "aaa-1", "time": \(now.timeIntervalSince1970 - 30), "title": "刚聊的"},
         {"id": "bbb-2", "time": \(now.timeIntervalSince1970 - 3600 * 2.5), "title": "输入框命令补全"},
         {"id": "ccc-3", "time": \(now.timeIntervalSince1970 - 86400), "title": "SSH 连接检查"},
         {"id": "ddd-4", "time": \(now.timeIntervalSince1970 - 86400 * 3), "title": "旧的"}]
        """.utf8)
    let sessions = SessionList.parse(listed, now: now) ?? []
    check(sessions.map { $0.display ?? "" } == ["刚刚", "今天 09:30", "昨天 12:00", "10月1日 12:00"], "会话时间：\(sessions.map { $0.display ?? "" })")
    var withSessions = catalog
    if let index = withSessions.firstIndex(where: { $0.name == "resume" }) { withSessions[index].options = sessions }
    check(SlashCompleter.suggestions(for: "/resume 输入", in: withSessions)
            == [SlashSuggestion(text: "/resume bbb-2", title: "今天 09:30", label: "输入框命令补全")], "/resume 按标题搜，填进去的是会话 ID")
    check(SlashCompleter.suggestions(for: "/resume bbb-2", in: withSessions).isEmpty, "会话 ID 填好了：列表收起")

    // 输入框里：Tab 补全命令 → 接着列选项 → ↓ 选 → Tab 补全选项；Esc 先关列表
    Store.saveHistory(["/clear", "/compact"])
    let commander = Composer()
    commander.setTextForTest("")
    commander.typeForTest("/eff")
    check(commander.suggestionsForTest.first == "/effort", "打 /eff 弹出 /effort")
    let tab = #selector(NSResponder.insertTab(_:)), esc = #selector(NSResponder.cancelOperation(_:))
    check(commander.commandForTest(tab) == (true, "/effort "), "Tab 补全命令，后面留空格")
    check(commander.suggestionsForTest.first == "low", "接着列出选项：\(commander.suggestionsForTest)")
    _ = commander.commandForTest(down)
    check(commander.commandForTest(tab) == (true, "/effort medium") && commander.suggestionsForTest.isEmpty, "↓ 再 Tab：/effort medium，列表收起")
    commander.setTextForTest("")
    commander.typeForTest("/co")
    check(commander.commandForTest(esc).handled && commander.suggestionsForTest.isEmpty, "Esc 先关列表")
    check(commander.commandForTest(tab).handled && !commander.suggestionsForTest.isEmpty, "Tab 重新打开列表")
    commander.setTextForTest("")
    check(commander.commandForTest(up) == (true, "/compact") && commander.suggestionsForTest.isEmpty, "翻历史翻到命令：不弹列表")
    check(commander.commandForTest(up) == (true, "/clear"), "↑ 接着翻历史")

    print(failures == 0 ? "全部通过" : "\(failures) 项失败")
    return failures == 0 ? 0 : 1
}

/// --render-commands <文字> <png>：把这段文字对应的候选列表画成图片（用缓存的命令表和 Ghostty 配色），看排版用
@MainActor
func renderCommands(_ text: String, to path: String) -> Int32 {
    _ = NSApplication.shared
    let view = CompletionListView()
    view.look = GhosttyLook.load()
    view.items = SlashCompleter.suggestions(for: text, in: CommandCatalog.load())
    view.selected = min(1, view.items.count - 1)
    view.frame = NSRect(x: 0, y: 0, width: 760, height: view.preferredHeight)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.look.background.setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("\(view.items.count) 条，画到 \(path)")
    return 0
}

/// --commands：从 VPS 取一次命令表（会更新本地缓存）和 /resume 的会话列表，打印出来
func printCommands() -> Int32 {
    let started = Date()
    switch CommandCatalog.fetch() {
    case .success(let count):
        print("Claude Code 报了 \(count) 个命令，用时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    case .failure(let error):
        print("取不到命令表：\(error.message)（下面是缓存或自带的表）")
    }
    for command in CommandCatalog.load() {
        let options = command.options.map { $0.label.isEmpty ? $0.value : "\($0.value)(\($0.label))" }.joined(separator: " ")
        print("/\(command.name)  \(command.hint)  — \(command.label)" + (options.isEmpty ? "" : "\n      选项：\(options)"))
    }
    switch SessionList.fetch() {
    case .success(let sessions):
        print("/resume 能列的会话 \(sessions.count) 个（不含正在聊的）")
        for session in sessions { print("  \(session.display ?? "")  \(session.label)  \(session.value)") }
    case .failure(let error):
        print("取不到会话列表：\(error.message)")
    }
    return 0
}

signal(SIGPIPE, SIG_IGN)  // ssh 中途断开时写管道不能把整个应用带走

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--diagnose") {
        diagnose()
        exit(0)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--upload"), i + 1 < CommandLine.arguments.count {
        exit(uploadForTest(CommandLine.arguments[i + 1]))
    }
    if CommandLine.arguments.contains("--selftest") {
        exit(selfTest())
    }
    if CommandLine.arguments.contains("--commands") {
        exit(printCommands())
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render-commands"), i + 2 < CommandLine.arguments.count {
        exit(renderCommands(CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2]))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()  // NSApplication 只弱引用 delegate，app.run() 不返回，这里一直持有
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
