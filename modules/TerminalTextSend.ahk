; Terminal-host detection, terminal-only text preparation and one-shot paste.
;
; This module deliberately classifies the top-level host window. The process
; running inside the terminal (cmd.exe, powershell.exe, pwsh.exe, an SSH
; client, a REPL, etc.) is neither queried nor treated as a safety signal.

DetectSupportedTerminalHost(windowHwnd) {
    if !windowHwnd || !DllCall("user32\IsWindow", "ptr", windowHwnd, "int")
        return false
    root := DllCall("user32\GetAncestor", "ptr", windowHwnd,
        "uint", 2, "ptr") ; GA_ROOT
    if !root
        root := windowHwnd
    try className := WinGetClass("ahk_id " root)
    catch
        return false
    try processName := StrLower(WinGetProcessName("ahk_id " root))
    catch
        return false

    if className = "CASCADIA_HOSTING_WINDOW_CLASS"
        && (processName = "windowsterminal.exe"
            || processName = "windowsterminalpreview.exe")
        return {Kind: "WindowsTerminal", Hwnd: root,
            ClassName: className, ProcessName: processName}

    if className = "ConsoleWindowClass"
        && (processName = "conhost.exe" || processName = "openconsole.exe")
        return {Kind: "ConsoleHost", Hwnd: root,
            ClassName: className, ProcessName: processName}
    return false
}

TerminalHostStillMatches(host) {
    if !IsObject(host)
        return false
    current := DetectSupportedTerminalHost(host.Hwnd)
    return IsObject(current) && current.Kind = host.Kind
        && current.Hwnd = host.Hwnd
        && current.ClassName = host.ClassName
        && current.ProcessName = host.ProcessName
}

NormalizeTerminalSendText(text) {
    ; Only newline tokens which touch the absolute string boundaries are
    ; removed. Ordinary spaces and indentation are never trimmed.
    return RegExReplace(text,
        "^(?:(?:\r\n)|\r|\n)+|(?:(?:\r\n)|\r|\n)+$")
}

TerminalTextHasMeaningfulContent(text) {
    ; Keep the original value untouched. This copy is used only to decide
    ; whether whitespace/separator-only input should be sent.
    meaningful := RegExReplace(text,
        "[\s\x{00A0}\x{2000}-\x{200B}\x{202F}\x{205F}\x{3000}\x{FEFF}]", "")
    return meaningful != ""
}

TerminalTextHasLineBreak(text) {
    return InStr(text, "`r") || InStr(text, "`n")
}

NormalizeTerminalTextForClassification(text) {
    return StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
}

CountTerminalPattern(text, pattern) {
    count := 0
    position := 1
    while RegExMatch(text, pattern, &match, position) {
        count += 1
        position := match.Pos + Max(1, match.Len)
    }
    return count
}

TerminalLineHasCommandStructure(line) {
    trimmed := Trim(line, " `t")
    if trimmed = ""
        return false

    ; Code fences, prompts, standalone paths/URLs/options/assignments and
    ; shell composition syntax are structural vetoes. This is intentionally
    ; small: it is a conservative natural-language rule, not a command
    ; dictionary or a security scanner.
    grave := Chr(96)
    if SubStr(trimmed, 1, 3) = grave grave grave
        || RegExMatch(trimmed, "^~~~")
        return true
    parsed := ParseTerminalNaturalLanguageLine(trimmed)
    analysis := parsed.Content
    if RegExMatch(analysis,
        "i)^(?:PS\s+[^>]*>|[A-Z]:\\[^>]*>|[$]\s+|"
        . "[^@\s]+@[^:\s]+:[^$#]*[$#]\s+)")
        return true
    if RegExMatch(analysis,
        "i)^(?:[A-Z]:[\\/]|\\\\|/(?:[^/\s]+/)+)\S*$")
        return true
    if RegExMatch(analysis, "i)^https?://\S+$")
        return true
    if RegExMatch(analysis, "i)^--?[A-Z][\w-]*(?:\s|=|$)")
        return true
    if RegExMatch(analysis, "^[A-Za-z_][A-Za-z0-9_]*\s*=")
        return true
    if RegExMatch(analysis, "^(?:[&.]\s+|@echo\s+)")
        return true
    if InStr(analysis, "&&") || InStr(analysis, "||")
        || InStr(analysis, "|") || InStr(analysis, "$(")
        || InStr(analysis, ";") || InStr(analysis, ">")
        || InStr(analysis, "<")
        return true

    ; A single balanced inline Markdown code token such as `README.md` is
    ; allowed in a Chinese sentence. Unbalanced spans or command-like spans
    ; containing whitespace/operators are not.
    backticks := CountTerminalPattern(analysis, grave)
    if backticks {
        if backticks != 2
            return true
        inlinePattern := grave "[^" grave "\s;&|<>$()]+" grave
        if !RegExMatch(analysis, inlinePattern)
            return true
    }
    return false
}

ParseTerminalNaturalLanguageLine(line) {
    content := Trim(line, " `t")
    if content = ""
        return {Blank: true, Heading: false, Content: ""}

    if RegExMatch(content, "^#{1,6}[ `t]+(.+)$", &heading)
        return {Blank: false, Heading: true, Content: heading[1]}

    ; Markdown quotes and list/task prefixes are accepted as structure, but
    ; their payload must still satisfy the Chinese natural-language rule.
    Loop 4 {
        changed := false
        if RegExMatch(content, "^>[ `t]?(.*)$", &quote) {
            content := Trim(quote[1], " `t")
            changed := true
        }
        if RegExMatch(content,
            "^(?:[-+*]|\d+[.)])[ `t]+(?:\[[ xX]\][ `t]+)?(.*)$", &item) {
            content := Trim(item[1], " `t")
            changed := true
        }
        if !changed
            break
    }
    return {Blank: false, Heading: false, Content: content}
}

IsHighConfidenceChineseNaturalLanguage(text) {
    normalized := NormalizeTerminalTextForClassification(text)
    hanCount := 0
    latinCount := 0
    contentLines := 0

    for rawLine in StrSplit(normalized, "`n") {
        if TerminalLineHasCommandStructure(rawLine)
            return false
        parsed := ParseTerminalNaturalLanguageLine(rawLine)
        if parsed.Blank
            continue
        if parsed.Content = ""
            return false

        lineHan := CountTerminalPattern(parsed.Content,
            "[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]")
        lineLatin := CountTerminalPattern(parsed.Content, "[A-Za-z]")
        ; English is accepted only when the line is explicitly a Markdown
        ; heading. A standalone English line such as "git status" vetoes the
        ; whole body even if other lines contain Chinese.
        if !parsed.Heading && lineHan = 0
            return false
        if !parsed.Heading
            contentLines += 1
        hanCount += lineHan
        if !parsed.Heading
            latinCount += lineLatin
    }

    if contentLines = 0 || hanCount < 4
        return false
    return hanCount * 100 >= (hanCount + latinCount) * 35
}

PasteTextToSupportedTerminal(host) {
    if !TerminalHostStillMatches(host)
        throw Error("终端宿主已改变。")
    foreground := DllCall("user32\GetForegroundWindow", "ptr")
    if foreground != host.Hwnd
        throw Error("终端窗口不再位于前台。")

    if host.Kind = "ConsoleHost" {
        messageResult := 0
        delivered := DllCall("user32\SendMessageTimeoutW",
            "ptr", host.Hwnd, "uint", 0x0302, ; WM_PASTE
            "ptr", 0, "ptr", 0, "uint", 0x3, "uint", 700,
            "ptr*", &messageResult, "ptr")
        if !delivered
            throw OSError(A_LastError, "Console Host 未接受粘贴消息")
        return true
    }

    if host.Kind = "WindowsTerminal" {
        ; Windows Terminal does not expose WM_PASTE. Dispatch its standard
        ; Shift+Insert paste action once. It remains a host paste gesture in
        ; raw/bracketed-input TUIs such as Claude Code, where Ctrl+V-family
        ; bindings may be consumed or unbound. Never follow it with a second
        ; key or right-click:
        ; SendInput cannot prove whether the first action pasted or opened the
        ; terminal's native warning, so retrying could duplicate the body.
        SendEvent("{Shift down}{Insert}{Shift up}")
        return true
    }
    throw Error("不支持的终端宿主。")
}
