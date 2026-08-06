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

PromptPanelRename(defaultName, defaultExtension := "", extensionEnabled := true) {
    global Panel

    BeginAutoHidePause()
    try {
        ownerOption := IsObject(Panel) ? "+Owner" Panel.Hwnd " " : ""
        dialog := Gui(ownerOption "-MaximizeBox -MinimizeBox", "重命名")
        dialog.MarginX := 16
        dialog.MarginY := 14
        dialog.SetFont("s9", "Microsoft YaHei UI")
        dialog.AddText("xm ym+5 w64", "文件名：")
        nameEdit := AddUiEdit(dialog, "x80 yp-5 w330", defaultName)
        dotLabel := dialog.AddText("x418 yp+5 w10", ".")
        extensionEdit := AddUiEdit(dialog, "x430 yp-5 w64", defaultExtension)
        if !extensionEnabled {
            dotLabel.Visible := false
            extensionEdit.Visible := false
            nameEdit.Move(,,, 414)
        }
        saveButton := AddUiButton(dialog, "x326 y58 w80 Default", "确定")
        cancelButton := AddUiButton(dialog, "x+8 yp w80", "取消")
        state := {Result: "Cancel", Name: defaultName,
            Extension: defaultExtension}
        saveButton.OnEvent("Click", PanelRenameDialogAccept.Bind(
            state, dialog, nameEdit, extensionEdit, extensionEnabled))
        cancelButton.OnEvent("Click", PanelRenameDialogCancel.Bind(
            state, dialog))
        dialog.OnEvent("Close", PanelRenameDialogCancel.Bind(state, dialog))
        dialog.OnEvent("Escape", PanelRenameDialogCancel.Bind(state, dialog))
        dialog.Show("w510 h105")
        nameEdit.Focus()
        DllCall("user32\SendMessageW", "ptr", nameEdit.Hwnd,
            "uint", 0x00B1, "ptr", 0, "ptr", -1) ; EM_SETSEL
        WinWaitClose("ahk_id " dialog.Hwnd)
        return state
    } finally {
        EndAutoHidePause()
    }
}

PanelRenameDialogAccept(state, dialog, nameEdit, extensionEdit,
    extensionEnabled, *) {
    state.Name := nameEdit.Value
    state.Extension := extensionEnabled ? extensionEdit.Value : ""
    state.Result := "OK"
    dialog.Destroy()
}

PanelRenameDialogCancel(state, dialog, *) {
    state.Result := "Cancel"
    dialog.Destroy()
}
