; PopDrop panel-owned dialogs and file picker helpers.

; 用 Owner 模式弹出 MsgBox，确保弹窗保持在置顶主面板之上
ShowPanelMsgBox(Text, Title?, Options?) {
    global Panel

    BeginAutoHidePause()

    try {
        ; 仅当面板可见时指定 Owner
        if IsObject(Panel)
            && DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int") {
            opts := Trim(Options " Owner" Panel.Hwnd)
            return MsgBox(Text, Title?, opts)
        }
        return MsgBox(Text, Title?, Options?)
    } finally {
        EndAutoHidePause()
    }
}

SelectPanelFile(options, rootDir := "", title := "", filter := "") {
    global Panel

    BeginAutoHidePause()
    try {
        ; +OwnDialogs is thread-local in AutoHotkey. Apply it immediately
        ; before FileSelect so an always-on-top panel cannot cover the picker.
        if IsObject(Panel)
            && DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
            Panel.Opt("+OwnDialogs")
        return FileSelect(options, rootDir, title, filter)
    } finally {
        EndAutoHidePause()
    }
}

PromptPanelInput(prompt, title, defaultValue := "", options := "w500 h150") {
    global Panel

    BeginAutoHidePause()
    try {
        ; InputBox observes the GUI thread's +OwnDialogs state. Apply it
        ; immediately before opening so the always-on-top panel cannot cover it.
        if IsObject(Panel)
            && DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
            Panel.Opt("+OwnDialogs")
        return InputBox(prompt, title, options, defaultValue)
    } finally {
        EndAutoHidePause()
    }
}
