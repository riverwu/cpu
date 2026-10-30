import Foundation

/// Sorts code the model wants to run into the agreed tiers before it runs: run it, ask the
/// user first (it sends, changes many things in an app, changes the system, installs,
/// deletes, quits), or refuse (sudo, simulated keyboard and mouse, wiping disks). Deleting
/// with `rm` needs no tier: CPU's `rm` moves files to the Trash. Existing files the code names
/// are backed up before it runs, so 撤销 can put them back.
public enum CodeSafety {
    public enum Verdict: Equatable {
        case run
        /// Plain-language reasons for the confirmation card ("发送邮件或消息").
        case confirm([String])
        case refuse(String)
    }

    private struct Rule {
        let pattern: String
        let reason: String
        var requires: String?
    }

    /// Where a shell command starts: a line, after ; | & ( or a quote (`do shell script "…"`).
    private static let command = #"(?m)(^\s*|[;|&("`]\s*)"#

    private static let refusals: [Rule] = [
        Rule(pattern: command + #"sudo\s"#, reason: "sudo needs the user's password, and CPU never runs it. Do it another way or tell the user what to run."),
        Rule(pattern: #"\b(keystroke|key code|click at)\b"#, reason: "Simulated keyboard and mouse input through System Events fights the user for their keyboard and mouse. Use act for UI actions.", requires: #"System Events"#),
        Rule(pattern: #"\.(keystroke|keyCode)\("#, reason: "Simulated keyboard input through System Events fights the user for their keyboard. Use act for UI actions."),
        Rule(pattern: command + #"cliclick\b"#, reason: "Simulated mouse input fights the user for their mouse. Use act for UI actions."),
        Rule(pattern: command + #"(diskutil\s+(erase|partition|zero|secureErase)|mkfs\b|dd\s[^\n]*\bof=/dev/)"#, reason: "This erases a disk."),
        Rule(pattern: command + #"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+(/|~|\$HOME|/Users/[^/\s]+)/?\s*($|[;&|"])"#, reason: "This removes a whole home folder or the system."),
        Rule(pattern: command + #"(shutdown|reboot|halt)\b"#, reason: "This shuts down or restarts the Mac.")
    ]

    private static let confirmations: [Rule] = [
        Rule(pattern: #"\bsend\b"#, reason: "发送邮件或消息", requires: #"application\s+"?(Mail|Messages|信息|邮件|Microsoft Outlook|WeChat|微信)|Application\(['"](Mail|Messages)"#),
        Rule(pattern: #"\bsmtplib\b|\bsendmail\b|"# + command + #"mail\s+-s\s"#, reason: "发送邮件"),
        Rule(pattern: #"\bcurl\b[^\n]*(\s-d\b|\s--data|\s-F\b|\s--form|\s-T\b|--upload-file|-X\s*['"]?(POST|PUT|PATCH|DELETE))|\bwget\b[^\n]*--post|\brequests\.(post|put|patch|delete)\(|method:\s*['"](POST|PUT|PATCH|DELETE)"#, reason: "向网络发送或上传数据"),
        Rule(pattern: command + #"(scp|sftp|ssh)\s|\brsync\b[^\n]*\S:|\bgit\s+push\b"#, reason: "连接或上传到其他电脑"),
        Rule(pattern: #"\bdefaults\s+(write|delete)\b|"# + command + #"(launchctl|networksetup|systemsetup|pmset|scutil|tccutil|csrutil|nvram|crontab)\b|/Library/Launch(Agents|Daemons)"#, reason: "修改系统设置"),
        Rule(pattern: #"\bbrew\s+(install|uninstall|reinstall|upgrade)\b|\bpip3?\s+install\b|\bnpm\s+(install|i)\s+(-g|--global)\b|\bgem\s+install\b|\bsoftwareupdate\b|"# + command + #"installer\s"#, reason: "安装或卸载软件"),
        Rule(pattern: #"\bos\.(remove|unlink|rmdir)\(|\bshutil\.rmtree\(|\.unlink\(|/bin/rm\s|"# + command + #"unlink\s"#, reason: "删除文件"),
        Rule(pattern: #"\bempty\s+(the\s+)?trash\b"#, reason: "清空废纸篓（不能撤销）"),
        // The clipboard is the user's; reading it (pbpaste) is fine.
        Rule(pattern: command + #"pbcopy\b|\bset\s+the\s+clipboard\s+to\b|\.setTheClipboardTo\(|NSPasteboard[^\n]*\b(setString|setData|writeObjects|clearContents|declareTypes)\b|\bpyperclip\.copy\("#, reason: "写入剪贴板（会替换你复制的内容）"),
        Rule(pattern: command + #"(kill|killall|pkill)\s|tell\s+application\s+"[^"]*"\s+to\s+quit\b|(?m)^\s*quit(\s+saving\s+\w+)?\s*$|\.quit\(\)"#, reason: "退出应用或结束进程（未保存的内容可能丢失）"),
        // Changing many objects of an app at once: every/whose or a loop, together with a change.
        // `set x to … every …` only reads; `set <property> of … to …` writes.
        Rule(pattern: #"\b(delete|move|duplicate)\b[^\n]*\b(every|whose)\b|\bset\s+(?!\w+\s+to\b)[^\n]*\bof\b[^\n]*\b(every|whose)\b[^\n]*\bto\b"#, reason: "批量修改应用里的数据", requires: #"tell\s+application"#),
        Rule(pattern: #"\brepeat\s+with\b[\s\S]*(\bdelete\b|\bmove\b|\bset\s+(?!\w+\s+to\b)[^\n]*\bof\b[^\n]*\bto\b)"#, reason: "批量修改应用里的数据", requires: #"tell\s+application"#),
        Rule(pattern: #"\.whose\([\s\S]*(\.delete\(|\.move\(|\s=\s)|\.forEach\([\s\S]*(\.delete\(|\.move\()"#, reason: "批量修改应用里的数据", requires: #"Application\("#)
    ]

    public static func check(language: String, code: String) -> Verdict {
        for rule in refusals where matches(rule, code) {
            return .refuse(rule.reason)
        }
        var reasons: [String] = []
        for rule in confirmations where matches(rule, code) && !reasons.contains(rule.reason) {
            reasons.append(rule.reason)
        }
        return reasons.isEmpty ? .run : .confirm(reasons)
    }

    // MARK: - Scripts in a browser tab

    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.brave.Browser"]

    /// A page script reads what the page shows (the user may be logged in there); acting on
    /// the page goes through act, where the user can see it.
    static func pageRefusal(_ code: String) -> String? {
        let acting = #"\.(click|submit|focus|requestSubmit)\(|dispatchEvent\(|\.value\s*=[^=]|innerHTML\s*=[^=]|textContent\s*=[^=]|location(\.href)?\s*=[^=]|\bfetch\(|XMLHttpRequest|document\.cookie|localStorage|sessionStorage|window\.open\("#
        guard code.range(of: acting, options: .regularExpression) != nil else {
            return nil
        }
        return "a page script may only read the page (no clicks, typing, navigation, requests, cookies or storage). Act on the page with act."
    }

    /// The model's code as one script whose value comes back as JSON: an expression, or a
    /// function body when it says `return`.
    static func pageScript(_ code: String) -> String {
        let body = code.range(of: #"\breturn\b"#, options: .regularExpression) != nil ? code : "return (\n\(code)\n);"
        return "JSON.stringify((() => {\n\(body)\n})(), null, 1)"
    }

    /// AppleScript that runs the script file in the tab whose title matches (else the front
    /// window's tab) of Chrome-family browsers or Safari.
    static func browserScript(bundleId: String, title: String, scriptFile: String) -> String {
        let name = title.replacingOccurrences(of: #" - (Google Chrome|Microsoft Edge|Brave)$"#, with: "", options: .regularExpression)
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let read = "set js to read (POSIX file ((system attribute \"CPU_WORK\") & \"/\(scriptFile)\")) as «class utf8»"
        if bundleId == "com.apple.Safari" {
            return """
            \(read)
            tell application id "com.apple.Safari"
              set target to front window
              repeat with w in windows
                if name of current tab of w is "\(quoted)" then set target to w
              end repeat
              return do JavaScript js in current tab of target
            end tell
            """
        }
        return """
        \(read)
        tell application id "\(bundleId)"
          set target to front window
          repeat with w in windows
            if title of active tab of w is "\(quoted)" then set target to w
          end repeat
          return execute (active tab of target) javascript js
        end tell
        """
    }

    private static func matches(_ rule: Rule, _ code: String) -> Bool {
        if let requires = rule.requires, code.range(of: requires, options: [.regularExpression, .caseInsensitive]) == nil {
            return false
        }
        return code.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
