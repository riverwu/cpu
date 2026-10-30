import Foundation

/// What CPU knows about an app beyond its menus: layout and conventions that make the first
/// try right. Shortcuts come from the app's own menus (`BackgroundInput.menuCommands`), so
/// these stay structural. Users add or override them in ~/.config/cpu/hints/<bundle id>.md.
enum AppHints {
    static func tips(bundleId: String?) -> String? {
        guard let bundleId else {
            return nil
        }
        let file = Config.directory.appendingPathComponent("hints/\(bundleId).md")
        if let custom = try? String(contentsOf: file, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return builtIn[bundleId]
    }

    private static let browser = """
    - Prefer the open tool with a URL over clicking through pages. ⌘L focuses the address bar.
    - Web pages expose their links, buttons and fields to accessibility; use element targets.
    """

    private static let builtIn: [String: String] = [
        "com.tencent.xinWeChat": """
        - WeChat exposes almost nothing to accessibility: work from the recognized screen text \
        (click with target: "<text>") and the screenshot.
        - To open a chat, use 搜索 (⌘F), type the name, then click the matching result; or \
        click the name in the chat list on the left when it is visible.
        - The message box is the blank area at the bottom of the chat pane: click it before \
        typing. Return sends.
        """,
        "com.netease.game.popo": """
        - POPO exposes little to accessibility: work from the recognized screen text and the \
        screenshot.
        - To open a chat, use the search box at the top of the left column, type the name, then \
        click the matching result.
        - The message box is at the bottom of the chat pane: click it before typing.
        """,
        "com.apple.mail": """
        - In a new message, press return after each address in 收件人 so it becomes a token, \
        then fill 主题 and the body.
        - The message list rows carry sender and subject; select a row to read it.
        """,
        "com.apple.iCal": """
        - A new event opens an editor popover: type the title first, then set date, time and \
        invitees in the popover fields.
        """,
        "com.apple.Notes": """
        - The first line of a note becomes its title.
        """,
        "com.apple.finder": """
        - ⌘⇧G opens "Go to Folder": type a path such as ~/Downloads and press return.
        - In list view each file is a row; select rows by clicking them.
        - Moving files to the Trash deletes data: confirm first.
        """,
        "com.apple.Safari": browser,
        "com.google.Chrome": browser,
        "com.microsoft.edgemac": browser,
        "com.apple.systempreferences": """
        - Type the setting's name into the search field at the top of the sidebar and pick the \
        result; changing system settings needs the user's confirmation.
        """
    ]
}
