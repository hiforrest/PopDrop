; Native control construction, owner drawing and DPI corrections.

AddUiButton(guiObj, options, text, scaleFactor := 1.0) {
    global UI_SINGLE_LINE_HEIGHT
    return guiObj.AddButton(
        options " h" Round(UI_SINGLE_LINE_HEIGHT * scaleFactor)
        . " -Wrap", text)
}

AddPanelIconButton(guiObj, options, imagePath, tooltipText, action,
    alternateImagePath := "", disabledImagePath := "") {
    global PanelIconButtons, PanelIconSubclassCallback
    EnsurePanelIconGraphics()
    fullPath := ResolvePanelAssetPath(imagePath)
    image := LoadPanelIconImage(fullPath)
    alternateImage := alternateImagePath != ""
        ? LoadPanelIconImage(ResolvePanelAssetPath(alternateImagePath)) : 0
    disabledImage := disabledImagePath != ""
        ? LoadPanelIconImage(ResolvePanelAssetPath(disabledImagePath)) : 0
    bitmap := 0
    alternateBitmap := 0
    disabledBitmap := 0
    try {
        bitmap := CreatePanelIconBitmap(image)
        alternateBitmap := alternateImage
            ? CreatePanelIconBitmap(alternateImage) : 0
        disabledBitmap := disabledImage
            ? CreatePanelIconBitmap(disabledImage) : 0
    } catch as err {
        DisposePanelIconBitmap(bitmap)
        DisposePanelIconBitmap(alternateBitmap)
        DisposePanelIconBitmap(disabledBitmap)
        DisposePanelIconImage(image)
        DisposePanelIconImage(alternateImage)
        DisposePanelIconImage(disabledImage)
        throw err
    }
    control := guiObj.AddText(options " +Tabstop +0x100", "") ; SS_NOTIFY
    state := {
        Control: control,
        Image: image,
        AlternateImage: alternateImage,
        DisabledImage: disabledImage,
        Bitmap: bitmap,
        AlternateBitmap: alternateBitmap,
        DisabledBitmap: disabledBitmap,
        UseAlternate: false,
        Tooltip: tooltipText,
        Action: action,
        Hovered: false,
        Pressed: false,
        Selected: false,
        Enabled: true
    }
    PanelIconButtons[control.Hwnd] := state
    if !PanelIconSubclassCallback
        PanelIconSubclassCallback := CallbackCreate(
            PanelIconButtonSubclass, "", 6)
    if !DllCall("comctl32\SetWindowSubclass",
        "ptr", control.Hwnd,
        "ptr", PanelIconSubclassCallback,
        "uptr", 0x50444942,
        "uptr", control.Hwnd,
        "int") {
        DisposePanelIconImage(image)
        DisposePanelIconImage(alternateImage)
        DisposePanelIconImage(disabledImage)
        DisposePanelIconBitmap(bitmap)
        DisposePanelIconBitmap(alternateBitmap)
        DisposePanelIconBitmap(disabledBitmap)
        PanelIconButtons.Delete(control.Hwnd)
        throw OSError(A_LastError, "无法创建图标工具栏按钮")
    }
    control.OnEvent("Click", InvokePanelIconButton.Bind(control.Hwnd))
    return control
}

ResolvePanelAssetPath(path) {
    if RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\)")
        return path
    return A_ScriptDir "\\" path
}

EnsurePanelIconGraphics() {
    global PanelIconGdipToken
    if PanelIconGdipToken
        return
    inputSize := A_PtrSize = 8 ? 24 : 16
    input := Buffer(inputSize, 0)
    NumPut("uint", 1, input, 0)
    token := 0
    status := DllCall("gdiplus\GdiplusStartup",
        "ptr*", &token, "ptr", input.Ptr, "ptr", 0, "uint")
    if status || !token
        throw Error("无法初始化 PNG 图标绘制组件（GDI+ 状态 " status "）。")
    PanelIconGdipToken := token
}

LoadPanelIconImage(path) {
    if !FileExist(path)
        throw Error("工具栏图标不存在：" path)
    image := 0
    status := DllCall("gdiplus\GdipCreateBitmapFromFile",
        "wstr", path, "ptr*", &image, "uint")
    if status || !image
        throw Error("无法加载工具栏图标：" path "（GDI+ 状态 " status "）")
    return image
}

CreatePanelIconBitmap(image) {
    if !image
        return 0
    bitmap := 0
    ; Convert the immutable PNG once. WM_PAINT then uses only GDI handles;
    ; repeatedly entering GDI+ from a subclass callback caused transient blank
    ; buttons and could amplify a failed paint into a message storm.
    status := DllCall("gdiplus\GdipCreateHBITMAPFromBitmap",
        "ptr", image, "ptr*", &bitmap, "uint", 0x00000000, "uint")
    if status || !bitmap
        throw Error("无法创建工具栏原生位图（GDI+ 状态 " status "）。")
    return bitmap
}

DisposePanelIconImage(image) {
    if image
        DllCall("gdiplus\GdipDisposeImage", "ptr", image, "uint")
}

DisposePanelIconBitmap(bitmap) {
    if bitmap
        DllCall("gdi32\DeleteObject", "ptr", bitmap)
}

InvokePanelIconButton(hwnd, *) {
    global PanelIconButtons
    if !PanelIconButtons.Has(hwnd)
        return
    state := PanelIconButtons[hwnd]
    if state.Enabled && IsObject(state.Action)
        state.Action.Call()
}

PanelIconButtonSubclass(hwnd, msg, wParam, lParam, subclassId, refData) {
    global PanelIconButtons, PanelIconHoverHwnd
    try {
        if msg = 0x000F { ; WM_PAINT
            ; Consume WM_PAINT only after BeginPaint/EndPaint succeeded. If
            ; BeginPaint transiently fails, DefSubclassProc validates the
            ; region instead of leaving an endless WM_PAINT pending.
            if DrawPanelIconButton(hwnd)
                return 0
        }
        if msg = 0x0014 ; WM_ERASEBKGND
            return 1
        if PanelIconButtons.Has(hwnd) {
            state := PanelIconButtons[hwnd]
            if msg = 0x0200 { ; WM_MOUSEMOVE
                if state.Enabled && !state.Hovered {
                    if PanelIconHoverHwnd && PanelIconHoverHwnd != hwnd
                        ClearPanelIconHover(PanelIconHoverHwnd)
                    state.Hovered := true
                    PanelIconHoverHwnd := hwnd
                    TrackPanelIconMouseLeave(hwnd)
                    InvalidatePanelIconButton(hwnd)
                    SchedulePanelIconTooltip(hwnd)
                } else if !state.Enabled && state.Hovered
                    ClearPanelIconHover(hwnd)
            } else if msg = 0x02A3 { ; WM_MOUSELEAVE
                ClearPanelIconHover(hwnd)
            } else if msg = 0x0201 { ; WM_LBUTTONDOWN
                if state.Enabled {
                    DllCall("user32\SetFocus", "ptr", hwnd, "ptr")
                    state.Pressed := true
                    InvalidatePanelIconButton(hwnd)
                }
            } else if msg = 0x0202 || msg = 0x0215 { ; UP / CAPTURECHANGED
                if state.Pressed {
                    state.Pressed := false
                    InvalidatePanelIconButton(hwnd)
                }
            } else if msg = 0x0087
                && (wParam = 13 || wParam = 32) { ; WM_GETDLGCODE
                return 0x0004 ; DLGC_WANTALLKEYS
            } else if msg = 0x0100
                && (wParam = 13 || wParam = 32) { ; WM_KEYDOWN
                if state.Enabled && !state.Pressed {
                    state.Pressed := true
                    InvalidatePanelIconButton(hwnd)
                }
                return 0
            } else if msg = 0x0101
                && (wParam = 13 || wParam = 32) { ; WM_KEYUP
                shouldInvoke := state.Enabled && state.Pressed
                state.Pressed := false
                InvalidatePanelIconButton(hwnd)
                if shouldInvoke
                    SetTimer(InvokePanelIconButton.Bind(hwnd), -1)
                return 0
            } else if msg = 0x0007 || msg = 0x0008 { ; FOCUS / KILLFOCUS
                InvalidatePanelIconButton(hwnd)
            } else if msg = 0x0082 { ; WM_NCDESTROY
                RemovePanelIconButton(hwnd, subclassId)
            }
        }
    }
    return DllCall("comctl32\DefSubclassProc",
        "ptr", hwnd, "uint", msg, "ptr", wParam, "ptr", lParam, "ptr")
}

TrackPanelIconMouseLeave(hwnd) {
    size := A_PtrSize = 8 ? 24 : 16
    tracking := Buffer(size, 0)
    NumPut("uint", size, tracking, 0)
    NumPut("uint", 0x00000002, tracking, 4) ; TME_LEAVE
    NumPut("ptr", hwnd, tracking, 8)
    DllCall("user32\TrackMouseEvent", "ptr", tracking.Ptr, "int")
}

ClearPanelIconHover(hwnd) {
    global PanelIconButtons, PanelIconHoverHwnd, PanelIconTooltipGeneration
    if PanelIconButtons.Has(hwnd) {
        state := PanelIconButtons[hwnd]
        state.Hovered := false
        state.Pressed := false
        InvalidatePanelIconButton(hwnd)
    }
    if PanelIconHoverHwnd = hwnd
        PanelIconHoverHwnd := 0
    PanelIconTooltipGeneration += 1
    ToolTip()
}

ResetPanelIconHover() {
    global PanelIconHoverHwnd, PanelIconTooltipGeneration
    if PanelIconHoverHwnd
        ClearPanelIconHover(PanelIconHoverHwnd)
    else {
        PanelIconTooltipGeneration += 1
        ToolTip()
    }
}

SchedulePanelIconTooltip(hwnd) {
    global PanelIconTooltipGeneration
    PanelIconTooltipGeneration += 1
    generation := PanelIconTooltipGeneration
    SetTimer(ShowPanelIconTooltip.Bind(hwnd, generation), -450)
}

ShowPanelIconTooltip(hwnd, generation) {
    global PanelIconButtons, PanelIconHoverHwnd, PanelIconTooltipGeneration
    if generation != PanelIconTooltipGeneration
        || PanelIconHoverHwnd != hwnd || !PanelIconButtons.Has(hwnd)
        return
    state := PanelIconButtons[hwnd]
    if !state.Hovered || state.Tooltip = ""
        return
    previousMouseMode := A_CoordModeMouse
    previousToolTipMode := A_CoordModeToolTip
    try {
        CoordMode("Mouse", "Screen")
        CoordMode("ToolTip", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        ToolTip(state.Tooltip, mouseX + 16, mouseY + 20)
    } finally {
        CoordMode("Mouse", previousMouseMode)
        CoordMode("ToolTip", previousToolTipMode)
    }
}

DrawPanelIconButton(hwnd) {
    global PanelIconButtons
    if !PanelIconButtons.Has(hwnd)
        return
    state := PanelIconButtons[hwnd]
    paint := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("user32\BeginPaint", "ptr", hwnd,
        "ptr", paint.Ptr, "ptr")
    if !hdc
        return false
    try {
        rect := Buffer(16, 0)
        DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", rect.Ptr)
        width := NumGet(rect, 8, "int")
        height := NumGet(rect, 12, "int")
        active := state.Enabled && (state.Hovered || state.Selected)
        if active {
            fillColor := state.Pressed ? 0xFFE8CC : 0xFFF3E5
            brush := DllCall("gdi32\CreateSolidBrush",
                "uint", fillColor, "ptr")
            DllCall("user32\FillRect", "ptr", hdc,
                "ptr", rect.Ptr, "ptr", brush)
            DllCall("gdi32\DeleteObject", "ptr", brush)
            border := DllCall("gdi32\CreateSolidBrush",
                "uint", 0xE9AF66, "ptr")
            DllCall("user32\FrameRect", "ptr", hdc,
                "ptr", rect.Ptr, "ptr", border)
            DllCall("gdi32\DeleteObject", "ptr", border)
        } else {
            DllCall("user32\FillRect", "ptr", hdc,
                "ptr", rect.Ptr,
                "ptr", DllCall("user32\GetSysColorBrush",
                    "int", 15, "ptr")) ; COLOR_BTNFACE
        }
        bitmap := !state.Enabled && state.DisabledBitmap
            ? state.DisabledBitmap
            : state.UseAlternate && state.AlternateBitmap
                ? state.AlternateBitmap : state.Bitmap
        if bitmap
            DrawPanelIconNativeBitmap(hdc, bitmap, width, height)
        if state.Enabled && DllCall("user32\GetFocus", "ptr") = hwnd {
            focusRect := Buffer(16, 0)
            NumPut("int", 3, focusRect, 0)
            NumPut("int", 3, focusRect, 4)
            NumPut("int", Max(3, width - 3), focusRect, 8)
            NumPut("int", Max(3, height - 3), focusRect, 12)
            DllCall("user32\DrawFocusRect", "ptr", hdc,
                "ptr", focusRect.Ptr, "int")
        }
    } finally {
        DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    }
    return true
}

DrawPanelIconNativeBitmap(hdc, bitmap, width, height) {
    if !hdc || !bitmap || width <= 0 || height <= 0
        return false
    bitmapInfo := Buffer(A_PtrSize = 8 ? 32 : 24, 0)
    if !DllCall("gdi32\GetObjectW", "ptr", bitmap,
        "int", bitmapInfo.Size, "ptr", bitmapInfo.Ptr, "int")
        return false
    sourceWidth := NumGet(bitmapInfo, 4, "int")
    sourceHeight := Abs(NumGet(bitmapInfo, 8, "int"))
    if sourceWidth <= 0 || sourceHeight <= 0
        return false
    sourceDc := DllCall("gdi32\CreateCompatibleDC", "ptr", hdc, "ptr")
    if !sourceDc
        return false
    oldBitmap := DllCall("gdi32\SelectObject", "ptr", sourceDc,
        "ptr", bitmap, "ptr")
    drawn := false
    try {
        ; AC_SRC_ALPHA with a pre-rendered 32-bit bitmap preserves the PNG's
        ; transparent background while native GDI owns every paint operation.
        blendFunction := 0x01FF0000
        drawn := !!DllCall("msimg32\AlphaBlend",
            "ptr", hdc, "int", 0, "int", 0,
            "int", width, "int", height,
            "ptr", sourceDc, "int", 0, "int", 0,
            "int", sourceWidth, "int", sourceHeight,
            "uint", blendFunction, "int")
        if !drawn
            drawn := !!DllCall("gdi32\StretchBlt",
                "ptr", hdc, "int", 0, "int", 0,
                "int", width, "int", height,
                "ptr", sourceDc, "int", 0, "int", 0,
                "int", sourceWidth, "int", sourceHeight,
                "uint", 0x00CC0020, "int") ; SRCCOPY
    } finally {
        if oldBitmap
            DllCall("gdi32\SelectObject", "ptr", sourceDc,
                "ptr", oldBitmap, "ptr")
        DllCall("gdi32\DeleteDC", "ptr", sourceDc)
    }
    return drawn
}

InvalidatePanelIconButton(hwnd) {
    DllCall("user32\InvalidateRect", "ptr", hwnd,
        "ptr", 0, "int", 0)
}

ResetPanelIconVisualState(repaintNow := false) {
    global PanelIconButtons, PanelIconHoverHwnd, PanelIconTooltipGeneration
    PanelIconHoverHwnd := 0
    PanelIconTooltipGeneration += 1
    ToolTip()
    redrawFlags := 0x0001 ; RDW_INVALIDATE
    if repaintNow
        redrawFlags |= 0x0100 ; RDW_UPDATENOW
    for hwnd, state in PanelIconButtons {
        state.Hovered := false
        state.Pressed := false
        ; RedrawWindow invalidates even a previously validated child window.
        ; RDW_UPDATENOW then dispatches WM_PAINT before the caller returns, so
        ; a button cannot remain blank until the mouse happens to enter it.
        DllCall("user32\RedrawWindow", "ptr", hwnd,
            "ptr", 0, "ptr", 0, "uint", redrawFlags, "int")
    }
    return true
}

SetPanelIconButtonHovered(control, hovered) {
    global PanelIconButtons
    if !IsObject(control) || !PanelIconButtons.Has(control.Hwnd)
        return
    PanelIconButtons[control.Hwnd].Hovered := !!hovered
    InvalidatePanelIconButton(control.Hwnd)
}

SetPanelIconButtonSelected(control, selected) {
    global PanelIconButtons
    if !IsObject(control) || !PanelIconButtons.Has(control.Hwnd)
        return
    PanelIconButtons[control.Hwnd].Selected := !!selected
    InvalidatePanelIconButton(control.Hwnd)
}

SetPanelIconButtonAlternate(control, useAlternate) {
    global PanelIconButtons
    if !IsObject(control) || !PanelIconButtons.Has(control.Hwnd)
        return
    PanelIconButtons[control.Hwnd].UseAlternate := !!useAlternate
    InvalidatePanelIconButton(control.Hwnd)
}

SetPanelIconButtonTooltip(control, text) {
    global PanelIconButtons
    if IsObject(control) && PanelIconButtons.Has(control.Hwnd)
        PanelIconButtons[control.Hwnd].Tooltip := text
}

SetPanelIconButtonEnabled(control, enabled) {
    global PanelIconButtons, PanelIconHoverHwnd, PanelIconTooltipGeneration
    if !IsObject(control) || !PanelIconButtons.Has(control.Hwnd)
        return
    state := PanelIconButtons[control.Hwnd]
    enabled := !!enabled
    if state.Enabled = enabled
        return
    state.Enabled := enabled
    state.Control.Enabled := enabled
    if !enabled {
        state.Hovered := false
        state.Pressed := false
        if PanelIconHoverHwnd = control.Hwnd
            PanelIconHoverHwnd := 0
        PanelIconTooltipGeneration += 1
        ToolTip()
    }
    InvalidatePanelIconButton(control.Hwnd)
}

RemovePanelIconButton(hwnd, subclassId := 0x50444942) {
    global PanelIconButtons, PanelIconSubclassCallback
    if !PanelIconButtons.Has(hwnd)
        return
    state := PanelIconButtons[hwnd]
    if PanelIconSubclassCallback
        DllCall("comctl32\RemoveWindowSubclass",
            "ptr", hwnd, "ptr", PanelIconSubclassCallback,
            "uptr", subclassId, "int")
    DisposePanelIconImage(state.Image)
    DisposePanelIconImage(state.AlternateImage)
    DisposePanelIconImage(state.DisabledImage)
    DisposePanelIconBitmap(state.Bitmap)
    DisposePanelIconBitmap(state.AlternateBitmap)
    DisposePanelIconBitmap(state.DisabledBitmap)
    PanelIconButtons.Delete(hwnd)
}

CleanupPanelIconButtons() {
    global PanelIconButtons, PanelIconSubclassCallback, PanelIconGdipToken
    global PanelIconTooltipGeneration, PanelIconHoverHwnd
    PanelIconTooltipGeneration += 1
    PanelIconHoverHwnd := 0
    ToolTip()
    handles := []
    for hwnd in PanelIconButtons
        handles.Push(hwnd)
    for hwnd in handles
        RemovePanelIconButton(hwnd)
    if PanelIconSubclassCallback
        CallbackFree(PanelIconSubclassCallback)
    PanelIconSubclassCallback := 0
    if PanelIconGdipToken
        DllCall("gdiplus\GdiplusShutdown", "ptr", PanelIconGdipToken)
    PanelIconGdipToken := 0
}

AddPanelSolidRule(guiObj, options, colorRef) {
    global PanelSolidRuleControls, PanelSolidRuleSubclassCallback
    control := guiObj.AddText(options, "")
    PanelSolidRuleControls[control.Hwnd] := colorRef
    if !PanelSolidRuleSubclassCallback
        PanelSolidRuleSubclassCallback := CallbackCreate(
            PanelSolidRuleSubclass, "", 6)
    if !DllCall("comctl32\SetWindowSubclass",
        "ptr", control.Hwnd,
        "ptr", PanelSolidRuleSubclassCallback,
        "uptr", 0x50445352,
        "uptr", 0,
        "int") {
        PanelSolidRuleControls.Delete(control.Hwnd)
        throw OSError(A_LastError, "无法创建 Tab 分界线")
    }
    return control
}

PanelSolidRuleSubclass(hwnd, msg, wParam, lParam, subclassId, refData) {
    global PanelSolidRuleControls, PanelSolidRuleSubclassCallback
    try {
        if msg = 0x000F { ; WM_PAINT
            if DrawPanelSolidRule(hwnd)
                return 0
        }
        if msg = 0x0014 ; WM_ERASEBKGND
            return 1
        if msg = 0x0082 { ; WM_NCDESTROY
            DllCall("comctl32\RemoveWindowSubclass",
                "ptr", hwnd, "ptr", PanelSolidRuleSubclassCallback,
                "uptr", subclassId, "int")
            if PanelSolidRuleControls.Has(hwnd)
                PanelSolidRuleControls.Delete(hwnd)
        }
    }
    return DllCall("comctl32\DefSubclassProc",
        "ptr", hwnd, "uint", msg, "ptr", wParam, "ptr", lParam, "ptr")
}

DrawPanelSolidRule(hwnd) {
    global PanelSolidRuleControls
    paint := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("user32\BeginPaint", "ptr", hwnd,
        "ptr", paint.Ptr, "ptr")
    if !hdc
        return false
    try {
        rect := Buffer(16, 0)
        DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", rect.Ptr)
        colorRef := PanelSolidRuleControls.Has(hwnd)
            ? PanelSolidRuleControls[hwnd] : 0x00908782
        brush := DllCall("gdi32\CreateSolidBrush",
            "uint", colorRef, "ptr")
        DllCall("user32\FillRect", "ptr", hdc,
            "ptr", rect.Ptr, "ptr", brush)
        DllCall("gdi32\DeleteObject", "ptr", brush)
    } finally {
        DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    }
    return true
}

CleanupPanelSolidRules() {
    global PanelSolidRuleControls, PanelSolidRuleSubclassCallback
    if PanelSolidRuleSubclassCallback {
        handles := []
        for hwnd in PanelSolidRuleControls
            handles.Push(hwnd)
        for hwnd in handles {
            if DllCall("user32\IsWindow", "ptr", hwnd, "int")
                DllCall("comctl32\RemoveWindowSubclass",
                    "ptr", hwnd, "ptr", PanelSolidRuleSubclassCallback,
                    "uptr", 0x50445352, "int")
        }
        CallbackFree(PanelSolidRuleSubclassCallback)
    }
    PanelSolidRuleSubclassCallback := 0
    PanelSolidRuleControls.Clear()
}

AddPanelDashedSeparator(guiObj, options) {
    global PanelSeparatorControls, PanelSeparatorSubclassCallback
    control := guiObj.AddText(options, "")
    PanelSeparatorControls[control.Hwnd] := true
    if !PanelSeparatorSubclassCallback
        PanelSeparatorSubclassCallback := CallbackCreate(
            PanelDashedSeparatorSubclass, "", 6)
    if !DllCall("comctl32\SetWindowSubclass",
        "ptr", control.Hwnd,
        "ptr", PanelSeparatorSubclassCallback,
        "uptr", 0x50445350,
        "uptr", 0,
        "int") {
        PanelSeparatorControls.Delete(control.Hwnd)
        throw OSError(A_LastError, "无法创建工具栏分割线")
    }
    return control
}

PanelDashedSeparatorSubclass(hwnd, msg, wParam, lParam, subclassId, refData) {
    global PanelSeparatorControls, PanelSeparatorSubclassCallback
    try {
        if msg = 0x000F { ; WM_PAINT
            if DrawPanelDashedSeparator(hwnd)
                return 0
        }
        if msg = 0x0014 ; WM_ERASEBKGND
            return 1
        if msg = 0x0082 { ; WM_NCDESTROY
            DllCall("comctl32\RemoveWindowSubclass",
                "ptr", hwnd, "ptr", PanelSeparatorSubclassCallback,
                "uptr", subclassId, "int")
            if PanelSeparatorControls.Has(hwnd)
                PanelSeparatorControls.Delete(hwnd)
        }
    }
    return DllCall("comctl32\DefSubclassProc",
        "ptr", hwnd, "uint", msg, "ptr", wParam, "ptr", lParam, "ptr")
}

DrawPanelDashedSeparator(hwnd) {
    paint := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("user32\BeginPaint", "ptr", hwnd,
        "ptr", paint.Ptr, "ptr")
    if !hdc
        return false
    try {
        rect := Buffer(16, 0)
        DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", rect.Ptr)
        width := NumGet(rect, 8, "int")
        height := NumGet(rect, 12, "int")
        DllCall("user32\FillRect", "ptr", hdc, "ptr", rect.Ptr,
            "ptr", DllCall("user32\GetSysColorBrush",
                "int", 15, "ptr")) ; COLOR_BTNFACE
        if width > 0 && height > 0 {
            ; Literal 1-device-pixel dashes are reliable across fractional DPI
            ; and don't depend on PS_DASH rendering behavior.
            lineY := Floor((height - 1) / 2)
            dashBrush := DllCall("gdi32\CreateSolidBrush",
                "uint", 0x00686868, "ptr") ; RGB(104,104,104)
            dashWidth := 4
            dashGap := 3
            dashX := 0
            while dashX < width {
                dashRect := Buffer(16, 0)
                NumPut("int", dashX, dashRect, 0)
                NumPut("int", lineY, dashRect, 4)
                NumPut("int", Min(width, dashX + dashWidth), dashRect, 8)
                NumPut("int", lineY + 1, dashRect, 12)
                DllCall("user32\FillRect", "ptr", hdc,
                    "ptr", dashRect.Ptr, "ptr", dashBrush)
                dashX += dashWidth + dashGap
            }
            DllCall("gdi32\DeleteObject", "ptr", dashBrush)
        }
    } finally {
        DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    }
    return true
}

CleanupPanelDashedSeparators() {
    global PanelSeparatorControls, PanelSeparatorSubclassCallback
    if PanelSeparatorSubclassCallback {
        handles := []
        for hwnd in PanelSeparatorControls
            handles.Push(hwnd)
        for hwnd in handles {
            if DllCall("user32\IsWindow", "ptr", hwnd, "int")
                DllCall("comctl32\RemoveWindowSubclass",
                    "ptr", hwnd, "ptr", PanelSeparatorSubclassCallback,
                    "uptr", 0x50445350, "int")
        }
        CallbackFree(PanelSeparatorSubclassCallback)
    }
    PanelSeparatorSubclassCallback := 0
    PanelSeparatorControls.Clear()
}

AddUiEdit(guiObj, options, text := "") {
    global UI_SINGLE_LINE_HEIGHT
    isMultiLine := RegExMatch(options, "i)(^|\s)Multi(\s|$)")
    if !RegExMatch(options, "i)(^|\s)(h\d+|r\d+)(\s|$)")
        options .= " h" UI_SINGLE_LINE_HEIGHT
    if !isMultiLine {
        ; EM_SETRECT is intentionally limited by Windows to multiline Edit
        ; controls. ES_WANTRETURN stays off, so Enter still activates the
        ; dialog's default button; ES_AUTOHSCROLL preserves single-line input.
        options .= " Multi -WantReturn +0x80"
    }
    control := guiObj.AddEdit(options, text)
    if !isMultiLine
        CenterUiEditText(control)
    return control
}

AddUiDropDownList(guiObj, options, items, scaleFactor := 1.0) {
    global UI_DROPDOWN_FIELD_HEIGHT, UI_DROPDOWN_Y_OFFSET_PX
        , UiDropDownTextItems, UiDropDownScaleFactors
    ; CBS_OWNERDRAWFIXED | CBS_HASSTRINGS lets WM_DRAWITEM center only the text.
    ; Windows continues to own the combo frame, arrow, popup and input behavior.
    control := guiObj.AddDropDownList(options " +0x210", items)
    UiDropDownTextItems[control.Hwnd] := items.Clone()
    UiDropDownScaleFactors[control.Hwnd] := scaleFactor
    EnsureUiDropDownOwnerMessages(guiObj, control)
    ; CB_SETITEMHEIGHT(-1) adjusts only the native selection field. Unlike the
    ; H option it does not collapse the popup list to one row. The native frame
    ; adds roughly four logical pixels around this field. Windows vertically
    ; centers the text inside the resulting selection field.
    fieldHeight := Round(UI_DROPDOWN_FIELD_HEIGHT * scaleFactor
        * A_ScreenDPI / 96)
    DllCall("user32\SendMessageW", "ptr", control.Hwnd,
        "uint", 0x0153, "ptr", -1, "ptr", fieldHeight, "ptr")
    DllCall("user32\SendMessageW", "ptr", control.Hwnd,
        "uint", 0x0153, "ptr", 0, "ptr", fieldHeight, "ptr")
    if UI_DROPDOWN_Y_OFFSET_PX
        OffsetGuiControlYPhysical(control, UI_DROPDOWN_Y_OFFSET_PX)
    return control
}

PanelScale(value) {
    global PanelUiScaleFactor
    return Round(value * PanelUiScaleFactor)
}

PanelPixelsToGui(value, hwnd := 0) {
    dpi := hwnd
        ? DllCall("user32\GetDpiForWindow", "ptr", hwnd, "uint")
        : A_ScreenDPI
    if !dpi
        dpi := 96
    ; Gui.Add/Move applies monitor DPI afterwards. Keep this floating-point so
    ; the final Win32 rounding happens only once.
    return value * 96.0 / dpi
}

PanelPhysicalScale(value, hwnd := 0) {
    dpi := hwnd
        ? DllCall("user32\GetDpiForWindow", "ptr", hwnd, "uint")
        : A_ScreenDPI
    if !dpi
        dpi := 96
    return DllCall("kernel32\MulDiv", "int", PanelScale(value),
        "int", dpi, "int", 96, "int")
}

ScalePanelGuiOptions(options) {
    scaled := []
    for token in StrSplit(options, A_Space) {
        if RegExMatch(token,
            "i)^([xywh](?:p|m)?)([+-]?)(\d+(?:\.\d+)?)(.*)$", &match) {
            token := match[1] match[2]
                . PanelScale(match[3] + 0) match[4]
        }
        scaled.Push(token)
    }
    return JoinArray(scaled, " ")
}

MovePanelControl(control, x, y, width, height) {
    control.Move(PanelScale(x), PanelScale(y),
        PanelScale(width), PanelScale(height))
}

ReplaceUiDropDownItems(control, items) {
    global UiDropDownTextItems
    control.Delete()
    UiDropDownTextItems[control.Hwnd] := items.Clone()
    control.Add(items)
}

EnsureUiDropDownOwnerMessages(guiObj, control) {
    global UiDropDownParentSubclassCallback, UiDropDownSubclassedParents
    parentHwnd := DllCall("user32\GetParent", "ptr", control.Hwnd, "ptr")
    if !parentHwnd || parentHwnd = guiObj.Hwnd
        return
    if UiDropDownSubclassedParents.Has(parentHwnd)
        return
    if !UiDropDownParentSubclassCallback
        UiDropDownParentSubclassCallback := CallbackCreate(
            UiDropDownParentSubclass, "", 6)
    if DllCall("comctl32\SetWindowSubclass",
        "ptr", parentHwnd,
        "ptr", UiDropDownParentSubclassCallback,
        "uptr", 0x50445044,
        "uptr", 0,
        "int")
        UiDropDownSubclassedParents[parentHwnd] := true
}

UiDropDownParentSubclass(parentHwnd, msg, wParam, lParam, subclassId, refData) {
    global UiDropDownParentSubclassCallback, UiDropDownSubclassedParents
    try {
        if msg = 0x002B { ; WM_DRAWITEM
            result := DrawUiDropDownItem(wParam, lParam, msg, parentHwnd)
            if result != ""
                return result
        } else if msg = 0x002C { ; WM_MEASUREITEM
            result := MeasureUiDropDownItem(wParam, lParam, msg, parentHwnd)
            if result != ""
                return result
        } else if msg = 0x0082 { ; WM_NCDESTROY
            DllCall("comctl32\RemoveWindowSubclass",
                "ptr", parentHwnd,
                "ptr", UiDropDownParentSubclassCallback,
                "uptr", subclassId,
                "int")
            if UiDropDownSubclassedParents.Has(parentHwnd)
                UiDropDownSubclassedParents.Delete(parentHwnd)
        }
    }
    return DllCall("comctl32\DefSubclassProc",
        "ptr", parentHwnd,
        "uint", msg,
        "ptr", wParam,
        "ptr", lParam,
        "ptr")
}

CenterUiEditText(control) {
    global UI_EDIT_TEXT_Y_OFFSET_PX
    clientRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", control.Hwnd,
        "ptr", clientRect.Ptr, "int")
        return
    clientHeight := NumGet(clientRect, 12, "int")
    if clientHeight <= 0
        return

    textHeight := 0
    hdc := DllCall("user32\GetDC", "ptr", control.Hwnd, "ptr")
    if hdc {
        hFont := DllCall("user32\SendMessageW", "ptr", control.Hwnd,
            "uint", 0x0031, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
        oldFont := hFont
            ? DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", hFont, "ptr")
            : 0
        metrics := Buffer(64, 0)
        if DllCall("gdi32\GetTextMetricsW", "ptr", hdc,
            "ptr", metrics.Ptr, "int")
            textHeight := NumGet(metrics, 0, "int")
                + NumGet(metrics, 16, "int")
        if oldFont
            DllCall("gdi32\SelectObject", "ptr", hdc,
                "ptr", oldFont, "ptr")
        DllCall("user32\ReleaseDC", "ptr", control.Hwnd, "ptr", hdc)
    }
    if textHeight <= 0
        textHeight := Max(1, Round(12 * A_ScreenDPI / 96))

    formatRect := Buffer(16, 0)
    DllCall("user32\SendMessageW", "ptr", control.Hwnd,
        "uint", 0x00B2, "ptr", 0, "ptr", formatRect.Ptr, "ptr") ; EM_GETRECT
    top := Max(0, Floor((clientHeight - textHeight) / 2)
        + UI_EDIT_TEXT_Y_OFFSET_PX)
    bottom := Min(clientHeight, top + textHeight)
    if bottom <= top
        bottom := Min(clientHeight, top + 1)
    NumPut("int", top, formatRect, 4)
    NumPut("int", bottom, formatRect, 12)
    DllCall("user32\SendMessageW", "ptr", control.Hwnd,
        "uint", 0x00B3, "ptr", 0, "ptr", formatRect.Ptr, "ptr") ; EM_SETRECT
}

DrawUiDropDownItem(wParam, lParam, msg, ownerHwnd) {
    global UI_DROPDOWN_TEXT_Y_OFFSET_PX, UiDropDownTextItems
    global UiDropDownScaleFactors
    if !lParam
        return
    if NumGet(lParam, 0, "uint") = 5 ; ODT_STATIC
        return DrawFooterTextItem(lParam)
    if NumGet(lParam, 0, "uint") != 3 ; ODT_COMBOBOX
        return

    itemId := NumGet(lParam, 8, "uint")
    itemState := NumGet(lParam, 16, "uint")
    handleOffset := A_PtrSize = 8 ? 24 : 20
    comboHwnd := NumGet(lParam, handleOffset, "ptr")
    hdc := NumGet(lParam, handleOffset + A_PtrSize, "ptr")
    rectOffset := handleOffset + A_PtrSize * 2
    if !comboHwnd || !hdc
        return
    scaleFactor := UiDropDownScaleFactors.Has(comboHwnd)
        ? UiDropDownScaleFactors[comboHwnd] : 1.0

    textItemId := itemId
    if textItemId = 0xFFFFFFFF
        textItemId := DllCall("user32\SendMessageW", "ptr", comboHwnd,
            "uint", 0x0147, "ptr", 0, "ptr", 0, "int") ; CB_GETCURSEL
    itemText := ""
    if textItemId >= 0 {
        length := DllCall("user32\SendMessageW", "ptr", comboHwnd,
            "uint", 0x0149, "ptr", textItemId, "ptr", 0,
            "int") ; CB_GETLBTEXTLEN
        if length >= 0 {
            textBuffer := Buffer((length + 1) * 2, 0)
            copied := DllCall("user32\SendMessageW", "ptr", comboHwnd,
                "uint", 0x0148, "ptr", textItemId,
                "ptr", textBuffer.Ptr, "int") ; CB_GETLBTEXT
            if copied >= 0
                itemText := StrGet(textBuffer.Ptr, copied, "UTF-16")
        }
    }
    if itemText = "" && textItemId >= 0
        && UiDropDownTextItems.Has(comboHwnd)
        && textItemId < UiDropDownTextItems[comboHwnd].Length
        itemText := UiDropDownTextItems[comboHwnd][textItemId + 1]
    if itemText = "" && itemId = 0xFFFFFFFF {
        windowTextLength := DllCall("user32\GetWindowTextLengthW",
            "ptr", comboHwnd, "int")
        if windowTextLength > 0 {
            windowTextBuffer := Buffer((windowTextLength + 1) * 2, 0)
            copied := DllCall("user32\GetWindowTextW", "ptr", comboHwnd,
                "ptr", windowTextBuffer.Ptr, "int", windowTextLength + 1,
                "int")
            if copied > 0
                itemText := StrGet(windowTextBuffer.Ptr, copied, "UTF-16")
        }
    }

    drawRect := Buffer(16, 0)
    Loop 4
        NumPut("int", NumGet(lParam, rectOffset + (A_Index - 1) * 4, "int"),
            drawRect, (A_Index - 1) * 4)
    isSelectionField := !!(itemState & 0x1000) ; ODS_COMBOBOXEDIT
    isSelected := !!(itemState & 0x0001) && !isSelectionField
    isDisabled := !!(itemState & 0x0004)

    backgroundDrawn := false
    if isSelectionField {
        theme := DllCall("uxtheme\OpenThemeData", "ptr", comboHwnd,
            "wstr", "COMBOBOX", "ptr")
        if theme {
            backgroundDrawn := DllCall("uxtheme\DrawThemeBackground",
                "ptr", theme, "ptr", hdc, "int", 2, "int", 0,
                "ptr", drawRect.Ptr, "ptr", 0, "int") = 0 ; CP_BACKGROUND
            DllCall("uxtheme\CloseThemeData", "ptr", theme)
        }
    }
    if !backgroundDrawn {
        colorIndex := isSelected ? 13 : 5 ; COLOR_HIGHLIGHT / COLOR_WINDOW
        brush := DllCall("user32\GetSysColorBrush", "int", colorIndex, "ptr")
        DllCall("user32\FillRect", "ptr", hdc,
            "ptr", drawRect.Ptr, "ptr", brush)
    }

    textRect := Buffer(16, 0)
    Loop 4
        NumPut("int", NumGet(drawRect, (A_Index - 1) * 4, "int"),
            textRect, (A_Index - 1) * 4)
    NumPut("int", NumGet(textRect, 0, "int")
        + Max(2, Round(4 * scaleFactor * A_ScreenDPI / 96)), textRect, 0)
    NumPut("int", NumGet(textRect, 4, "int")
        + UI_DROPDOWN_TEXT_Y_OFFSET_PX, textRect, 4)
    NumPut("int", NumGet(textRect, 12, "int")
        + UI_DROPDOWN_TEXT_Y_OFFSET_PX, textRect, 12)

    textColorIndex := isDisabled ? 17
        : (isSelected ? 14 : 8) ; GRAYTEXT / HIGHLIGHTTEXT / WINDOWTEXT
    oldTextColor := DllCall("gdi32\SetTextColor", "ptr", hdc,
        "uint", DllCall("user32\GetSysColor", "int", textColorIndex, "uint"),
        "uint")
    oldBkMode := DllCall("gdi32\SetBkMode", "ptr", hdc,
        "int", 1, "int") ; TRANSPARENT
    hFont := DllCall("user32\SendMessageW", "ptr", comboHwnd,
        "uint", 0x0031, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
    oldFont := hFont
        ? DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", hFont, "ptr")
        : 0
    DllCall("user32\DrawTextW", "ptr", hdc, "wstr", itemText, "int", -1,
        "ptr", textRect.Ptr,
        "uint", 0x0004 | 0x0020 | 0x0800 | 0x8000, "int")
    if oldFont
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldFont, "ptr")
    DllCall("gdi32\SetBkMode", "ptr", hdc, "int", oldBkMode)
    DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", oldTextColor)
    if itemState & 0x0010 ; ODS_FOCUS
        DllCall("user32\DrawFocusRect", "ptr", hdc, "ptr", drawRect.Ptr)
    return 1
}

DrawFooterTextItem(drawItemPtr) {
    global StatusText, TransferStatusText
    handleOffset := A_PtrSize = 8 ? 24 : 20
    controlHwnd := NumGet(drawItemPtr, handleOffset, "ptr")
    if (!IsObject(StatusText) || controlHwnd != StatusText.Hwnd)
        && (!IsObject(TransferStatusText)
            || controlHwnd != TransferStatusText.Hwnd)
        return
    hdc := NumGet(drawItemPtr, handleOffset + A_PtrSize, "ptr")
    if !hdc
        return
    rectOffset := handleOffset + A_PtrSize * 2
    drawRect := Buffer(16, 0)
    Loop 4
        NumPut("int",
            NumGet(drawItemPtr, rectOffset + (A_Index - 1) * 4, "int"),
            drawRect, (A_Index - 1) * 4)

    brush := DllCall("user32\GetSysColorBrush", "int", 15, "ptr")
    DllCall("user32\FillRect", "ptr", hdc, "ptr", drawRect.Ptr,
        "ptr", brush, "int")

    textLength := DllCall("user32\GetWindowTextLengthW",
        "ptr", controlHwnd, "int")
    textBuffer := Buffer((Max(0, textLength) + 1) * 2, 0)
    if textLength > 0
        DllCall("user32\GetWindowTextW", "ptr", controlHwnd,
            "ptr", textBuffer.Ptr, "int", textLength + 1, "int")
    text := textLength > 0
        ? StrGet(textBuffer.Ptr, textLength, "UTF-16") : ""

    hFont := DllCall("user32\SendMessageW", "ptr", controlHwnd,
        "uint", 0x0031, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
    oldFont := hFont
        ? DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", hFont, "ptr")
        : 0
    metrics := Buffer(64, 0)
    lineHeight := DllCall("gdi32\GetTextMetricsW",
        "ptr", hdc, "ptr", metrics.Ptr, "int")
        ? Max(1, NumGet(metrics, 0, "int"))
        : Max(1, Round(15 * A_ScreenDPI / 96))

    top := NumGet(drawRect, 4, "int")
    bottom := NumGet(drawRect, 12, "int")
    bandHeight := Max(1, bottom - top)
    twoLineHeight := Min(bandHeight, lineHeight * 2)
    textTop := top + Floor((bandHeight - twoLineHeight) / 2)
    NumPut("int", textTop, drawRect, 4)
    NumPut("int", textTop + twoLineHeight, drawRect, 12)

    oldTextColor := DllCall("gdi32\SetTextColor", "ptr", hdc,
        "uint", DllCall("user32\GetSysColor", "int", 8, "uint"), "uint")
    oldBkMode := DllCall("gdi32\SetBkMode", "ptr", hdc,
        "int", 1, "int") ; TRANSPARENT
    if IsObject(TransferStatusText)
        && controlHwnd = TransferStatusText.Hwnd
        flags := 0x0002 | 0x0020 | 0x0800 ; RIGHT|SINGLELINE|NOPREFIX
    else
        ; DT_EDITCONTROL prevents a partially visible third line.
        flags := 0x0010 | 0x2000 | 0x0800 ; WORDBREAK|EDITCONTROL|NOPREFIX
    DllCall("user32\DrawTextW", "ptr", hdc, "wstr", text, "int", -1,
        "ptr", drawRect.Ptr, "uint", flags, "int")
    DllCall("gdi32\SetBkMode", "ptr", hdc, "int", oldBkMode)
    DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", oldTextColor)
    if oldFont
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldFont, "ptr")
    return 1
}

RedrawFooterTextControls(*) {
    global StatusText, TransferStatusText
    for control in [StatusText, TransferStatusText] {
        if !IsObject(control)
            continue
        DllCall("user32\InvalidateRect", "ptr", control.Hwnd,
            "ptr", 0, "int", 1)
        DllCall("user32\UpdateWindow", "ptr", control.Hwnd)
    }
}

MeasureUiDropDownItem(wParam, lParam, msg, ownerHwnd) {
    global UI_DROPDOWN_FIELD_HEIGHT, UiDropDownScaleFactors
    if !lParam || NumGet(lParam, 0, "uint") != 3 ; ODT_COMBOBOX
        return
    controlId := NumGet(lParam, 4, "uint")
    controlHwnd := DllCall("user32\GetDlgItem", "ptr", ownerHwnd,
        "int", controlId, "ptr")
    scaleFactor := controlHwnd && UiDropDownScaleFactors.Has(controlHwnd)
        ? UiDropDownScaleFactors[controlHwnd] : 1.0
    NumPut("uint", Round(UI_DROPDOWN_FIELD_HEIGHT * scaleFactor
        * A_ScreenDPI / 96),
        lParam, 16)
    return 1
}

OffsetGuiControlYPhysical(control, offsetPx) {
    rect := Buffer(16, 0)
    DllCall("user32\GetWindowRect", "ptr", control.Hwnd, "ptr", rect)
    parentHwnd := DllCall("user32\GetParent", "ptr", control.Hwnd, "ptr")
    point := Buffer(8, 0)
    NumPut("int", NumGet(rect, 0, "int"), point, 0)
    NumPut("int", NumGet(rect, 4, "int"), point, 4)
    DllCall("user32\ScreenToClient", "ptr", parentHwnd, "ptr", point)
    DllCall("user32\SetWindowPos", "ptr", control.Hwnd, "ptr", 0,
        "int", NumGet(point, 0, "int"),
        "int", NumGet(point, 4, "int") + offsetPx,
        "int", 0, "int", 0,
        "uint", 0x0001 | 0x0004 | 0x0010)
}
