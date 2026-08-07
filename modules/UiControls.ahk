; Native control construction, owner drawing and DPI corrections.

AddUiButton(guiObj, options, text, scaleFactor := 1.0) {
    global UI_SINGLE_LINE_HEIGHT
    return guiObj.AddButton(
        options " h" Round(UI_SINGLE_LINE_HEIGHT * scaleFactor)
        . " -Wrap", text)
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
