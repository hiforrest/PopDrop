; PopDrop external-content transfer integration.
; The UI process performs only FORMATETC probing during DragEnter/DragOver.
; Actual IDataObject extraction is delegated after Drop to PopDropTransfer.exe.

global DROP_ADAPTER_HDROP := "HDrop"
global DROP_ADAPTER_VIRTUAL := "VirtualFiles"
global DROP_ADAPTER_PNG := "Png"
global DROP_ADAPTER_DIBV5 := "DibV5"
global DROP_ADAPTER_DIB := "Dib"
global DROP_ADAPTER_URL := "Url"
global DROP_ADAPTER_UNSUPPORTED := "Unsupported"

global TransferBatches := Map()
global TransferHistory := []
global TransferStatusText := 0
global TransferCenter := 0
global TransferCenterRows := Map()
global TransferPollRunning := false
global TransferRefreshSources := Map()
global TransferInspectEnabled := false
global TransferInspectLog := ""
global TransferUrlFallbackEnabled := true
global TransferAllowHttp := false
global TransferMaxConcurrent := 3
global TransferShowNotifications := true
global TransferLastOrphanCleanup := 0

InitExternalDrop() {
    global TransferInspectEnabled, TransferInspectLog
    TransferInspectEnabled := HasCommandLineSwitch("--inspect-drop")
    if TransferInspectEnabled {
        TransferInspectLog := A_Temp "\PopDrop-drop-formats-"
            . DllCall("kernel32\GetCurrentProcessId", "uint") ".log"
        try FileDelete(TransferInspectLog)
    }
    CleanupOrphanedTransferArtifacts()
    SetTimer(PollTransferJobs, 250)
    SetTimer(CleanupOldTransferArtifacts, 60000)
}

HasCommandLineSwitch(name) {
    for value in A_Args {
        if StrLower(value) = StrLower(name)
            return true
    }
    return false
}

LoadExternalTransferSettings() {
    global ConfigPath, TransferUrlFallbackEnabled, TransferAllowHttp
    global TransferMaxConcurrent, TransferShowNotifications
    TransferUrlFallbackEnabled := ReadConfigBoolean(
        "ExternalTransfer", "EnablePublicUrlFallback", true)
    TransferAllowHttp := ReadConfigBoolean(
        "ExternalTransfer", "AllowHttp", false)
    TransferShowNotifications := ReadConfigBoolean(
        "ExternalTransfer", "ShowCompletionNotifications", true)
    try TransferMaxConcurrent := Integer(IniRead(
        ConfigPath, "ExternalTransfer", "MaxConcurrent", "3"))
    catch
        TransferMaxConcurrent := 3
    TransferMaxConcurrent := Max(1, Min(TransferMaxConcurrent, 6))
}

GetDropClipboardFormats() {
    static formats := 0
    if IsObject(formats)
        return formats
    formats := {
        FileDescriptorW: DllCall("user32\RegisterClipboardFormatW",
            "wstr", "FileGroupDescriptorW", "ushort"),
        FileContents: DllCall("user32\RegisterClipboardFormatW",
            "wstr", "FileContents", "ushort"),
        Png: DllCall("user32\RegisterClipboardFormatW",
            "wstr", "PNG", "ushort"),
        InetUrlW: DllCall("user32\RegisterClipboardFormatW",
            "wstr", "UniformResourceLocatorW", "ushort"),
        InetUrlA: DllCall("user32\RegisterClipboardFormatW",
            "wstr", "UniformResourceLocator", "ushort"),
        UriList: DllCall("user32\RegisterClipboardFormatW",
            "wstr", "text/uri-list", "ushort")
    }
    return formats
}

ClassifyDataObject(dataObject) {
    global DROP_ADAPTER_HDROP, DROP_ADAPTER_VIRTUAL
    global DROP_ADAPTER_PNG, DROP_ADAPTER_DIBV5, DROP_ADAPTER_DIB
    global DROP_ADAPTER_URL, DROP_ADAPTER_UNSUPPORTED
    formats := GetDropClipboardFormats()
    available := Map(
        "HDrop", DataObjectSupportsFormat(dataObject, 15, 1, -1),
        "FileDescriptor", DataObjectSupportsFormat(
            dataObject, formats.FileDescriptorW, 1, -1),
        "FileContents", DataObjectSupportsFormat(
            dataObject, formats.FileContents, 5, 0),
        "Png", DataObjectSupportsFormat(dataObject, formats.Png, 1, -1),
        "DibV5", DataObjectSupportsFormat(dataObject, 17, 1, -1),
        "Dib", DataObjectSupportsFormat(dataObject, 8, 1, -1),
        "Url", DataObjectSupportsFormat(dataObject, formats.InetUrlW, 1, -1)
            || DataObjectSupportsFormat(dataObject, formats.InetUrlA, 1, -1)
            || DataObjectSupportsFormat(dataObject, formats.UriList, 1, -1))
    decision := ClassifyAvailableDropFormats(available)

    if TransferInspectEnabled {
        decision.Formats := EnumerateDataObjectFormats(dataObject)
        WriteDropInspection(decision, dataObject)
    }
    return decision
}

ClassifyAvailableDropFormats(available) {
    global DROP_ADAPTER_HDROP, DROP_ADAPTER_VIRTUAL
    global DROP_ADAPTER_PNG, DROP_ADAPTER_DIBV5, DROP_ADAPTER_DIB
    global DROP_ADAPTER_URL, DROP_ADAPTER_UNSUPPORTED
    if available.Has("HDrop") && available["HDrop"]
        adapter := DROP_ADAPTER_HDROP
    else if available.Has("FileDescriptor") && available["FileDescriptor"]
        && available.Has("FileContents") && available["FileContents"]
        adapter := DROP_ADAPTER_VIRTUAL
    else if available.Has("Png") && available["Png"]
        adapter := DROP_ADAPTER_PNG
    else if available.Has("DibV5") && available["DibV5"]
        adapter := DROP_ADAPTER_DIBV5
    else if available.Has("Dib") && available["Dib"]
        adapter := DROP_ADAPTER_DIB
    else if available.Has("Url") && available["Url"]
        adapter := DROP_ADAPTER_URL
    else
        adapter := DROP_ADAPTER_UNSUPPORTED
    return {
        Adapter: adapter,
        Formats: [],
        Reason: adapter = DROP_ADAPTER_UNSUPPORTED
            ? "来源没有提供 PopDrop 支持的标准 Windows 拖放格式。" : ""
    }
}

DataObjectSupportsFormat(dataObject, clipFormat, tymed, itemIndex := -1) {
    if !dataObject || !clipFormat
        return false
    formatSize := A_PtrSize = 8 ? 32 : 20
    formatEtc := Buffer(formatSize, 0)
    FillFormatEtc(formatEtc.Ptr, clipFormat, tymed, itemIndex)
    try return HResultSucceeded(
        ComCall(5, dataObject, "ptr", formatEtc.Ptr, "int"))
    catch
        return false
}

FillFormatEtc(formatEtc, clipFormat, tymed, itemIndex := -1) {
    aspectOffset := A_PtrSize = 8 ? 16 : 8
    indexOffset := A_PtrSize = 8 ? 20 : 12
    tymedOffset := A_PtrSize = 8 ? 24 : 16
    NumPut("ushort", clipFormat, formatEtc, 0)
    NumPut("uint", 1, formatEtc, aspectOffset)
    NumPut("int", itemIndex, formatEtc, indexOffset)
    NumPut("uint", tymed, formatEtc, tymedOffset)
}

EnumerateDataObjectFormats(dataObject) {
    result := []
    enumerator := 0
    try {
        hr := ComCall(8, dataObject, "uint", 1, "ptr*", &enumerator, "int")
        if !HResultSucceeded(hr) || !enumerator
            return result
        formatSize := A_PtrSize = 8 ? 32 : 20
        formatEtc := Buffer(formatSize, 0)
        fetched := 0
        Loop 256 {
            formatEtc := Buffer(formatSize, 0)
            fetched := 0
            hr := ComCall(3, enumerator, "uint", 1, "ptr", formatEtc.Ptr,
                "uint*", &fetched, "int")
            if hr != 0 || fetched != 1
                break
            aspectOffset := A_PtrSize = 8 ? 16 : 8
            indexOffset := A_PtrSize = 8 ? 20 : 12
            tymedOffset := A_PtrSize = 8 ? 24 : 16
            id := NumGet(formatEtc, 0, "ushort")
            result.Push({
                Id: id,
                Name: ClipboardFormatName(id),
                Aspect: NumGet(formatEtc, aspectOffset, "uint"),
                Index: NumGet(formatEtc, indexOffset, "int"),
                Tymed: NumGet(formatEtc, tymedOffset, "uint")
            })
            ptdOffset := A_PtrSize = 8 ? 8 : 4
            ptd := NumGet(formatEtc, ptdOffset, "ptr")
            if ptd
                DllCall("ole32\CoTaskMemFree", "ptr", ptd)
        }
    } catch {
        return result
    } finally {
        if enumerator
            ObjRelease(enumerator)
    }
    return result
}

ClipboardFormatName(id) {
    static standard := Map(1, "CF_TEXT", 2, "CF_BITMAP", 8, "CF_DIB",
        13, "CF_UNICODETEXT", 15, "CF_HDROP", 17, "CF_DIBV5")
    if standard.Has(id)
        return standard[id]
    buffer := Buffer(512 * 2, 0)
    length := DllCall("user32\GetClipboardFormatNameW", "uint", id,
        "ptr", buffer.Ptr, "int", 512, "int")
    return length ? StrGet(buffer, length) : "Format#" id
}

TymedDisplay(value) {
    names := []
    for pair in [{Bit: 1, Name: "HGLOBAL"}, {Bit: 2, Name: "FILE"},
        {Bit: 4, Name: "ISTREAM"}, {Bit: 8, Name: "ISTORAGE"},
        {Bit: 16, Name: "GDI"}, {Bit: 32, Name: "MFPICT"},
        {Bit: 64, Name: "ENHMF"}] {
        if value & pair.Bit
            names.Push(pair.Name)
    }
    return names.Length ? JoinArray(names, "|") : Format("0x{:X}", value)
}

WriteDropInspection(decision, dataObject) {
    global TransferInspectLog
    async := DataObjectAsyncMode(dataObject)
    text := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        . " adapter=" decision.Adapter
        . " async=" (async.Supported ? (async.Enabled ? "enabled" : "available") : "no")
        . "`r`n"
    for item in decision.Formats
        text .= "  " item.Name " (" item.Id ") TYMED="
            . TymedDisplay(item.Tymed) " lIndex=" item.Index "`r`n"
    try FileAppend(text, TransferInspectLog, "UTF-8")
}

DataObjectAsyncMode(dataObject) {
    static iidAsync := GuidBuffer("{3D8B0590-F691-11D2-8EA9-006097DF5BD4}")
    asyncPtr := 0
    try {
        hr := ComCall(0, dataObject, "ptr", iidAsync.Ptr,
            "ptr*", &asyncPtr, "int")
        if !HResultSucceeded(hr) || !asyncPtr
            return {Supported: false, Enabled: false}
        enabled := 0
        hr := ComCall(4, asyncPtr, "int*", &enabled, "int")
        return {Supported: HResultSucceeded(hr), Enabled: !!enabled}
    } catch {
        return {Supported: false, Enabled: false}
    } finally {
        if asyncPtr
            ObjRelease(asyncPtr)
    }
}

HDropRequiresAsyncTakeover(paths, asyncInfo) {
    if !asyncInfo.Supported
        return false
    tempRoot := RTrim(NormalizePath(A_Temp), "\")
    for path in paths {
        if IsSameOrDescendantPath(path, tempRoot)
            return true
    }
    return false
}

ExternalAdapterAllowedAtTarget(adapter, target) {
    global DROP_ADAPTER_HDROP
    if adapter = DROP_ADAPTER_HDROP
        return true
    return IsObject(target) && target.Type = "Files"
}

ExternalAdapterTargetReason(adapter, target) {
    global DROP_ADAPTER_HDROP
    if adapter = DROP_ADAPTER_HDROP
        return ""
    if !IsObject(target)
        return "此区域不能接收外部内容。"
    if target.Type = "Launcher"
        return "网络或虚拟内容不能直接投放到启动器分组，请拖到普通文件夹。"
    if target.Type = "Pinned"
        return "虚拟或网络内容必须先保存到普通文件夹，不能直接加入固定项。"
    if target.Type != "Files"
        return "此区域不能接收外部内容。"
    return ""
}

CreateExternalTransfer(dataObject, adapter, target) {
    global DROP_ADAPTER_URL, TransferUrlFallbackEnabled
    global TransferAllowHttp, TransferMaxConcurrent, TransferShowNotifications
    global TransferBatches
    if adapter = DROP_ADAPTER_URL && !TransferUrlFallbackEnabled
        throw Error("公开 URL 兜底已在设置中关闭。")
    helper := ResolveTransferHelper()
    if helper = ""
        throw Error("缺少 PopDropTransfer.exe。请运行 native\build.ps1 构建传输组件。")
    root := EnsureTransferRuntimeDirectory()
    batchId := CreateTransferId("batch")
    batchDir := root "\" batchId
    DirCreate(batchDir)
    marshalPath := batchDir "\data-object.bin"
    requestPath := batchDir "\request.ini"
    statePath := batchDir "\state.ini"
    cancelPath := batchDir "\cancel"
    readyPath := batchDir "\ready"
    retryPath := batchDir "\url-retry.dpapi"
    try MarshalDataObjectToFile(dataObject, marshalPath)
    catch as err {
        try DirDelete(batchDir, true)
        throw err
    }
    request :=
    (
    "[Transfer]`r`n"
    "Protocol=2`r`n"
    "BatchId=" batchId "`r`n"
    "Adapter=" adapter "`r`n"
    "TargetPath=" target.Path "`r`n"
    "TargetSourceId=" target.SourceId "`r`n"
    "TargetName=" target.Name "`r`n"
    "MarshalPath=" marshalPath "`r`n"
    "StatePath=" statePath "`r`n"
    "CancelPath=" cancelPath "`r`n"
    "ReadyPath=" readyPath "`r`n"
    "RetryPath=" retryPath "`r`n"
    "AllowHttp=" (TransferAllowHttp ? "1" : "0") "`r`n"
    "MaxConcurrent=" TransferMaxConcurrent "`r`n"
    "ShowNotifications=" (TransferShowNotifications ? "1" : "0") "`r`n"
    )
    FileAppend(request, requestPath, "UTF-16")
    command := QuoteWindowsArgument(helper) " --request "
        . QuoteWindowsArgument(requestPath)
    try Run(command, A_ScriptDir, "Hide", &pid)
    catch as err {
        ReleaseMarshaledDataFile(marshalPath)
        try DirDelete(batchDir, true)
        throw err
    }
    batch := {
        Id: batchId, Adapter: adapter, TargetPath: target.Path,
        TargetSourceId: target.SourceId, TargetName: target.Name,
        Directory: batchDir, RequestPath: requestPath, StatePath: statePath,
        CancelPath: cancelPath, ReadyPath: readyPath, MarshalPath: marshalPath,
        RetryPath: retryPath,
        Pid: pid, Status: "Preparing", Items: [], Created: A_Now,
        Completed: false, RefreshQueued: false, LastUpdate: A_TickCount
    }
    TransferBatches[batchId] := batch
    try WaitForTransferHandshake(batch, 1200)
    catch as err {
        TransferBatches.Delete(batchId)
        ; A terminated helper either never consumed the marshal packet or
        ; already released it while exiting. CoReleaseMarshalData safely
        ; reports the latter and avoids leaking the former.
        ReleaseMarshaledDataFile(marshalPath)
        try DirDelete(batchDir, true)
        throw err
    }
    UpdateTransferUi()
    return batch
}

MarshalDataObjectToFile(dataObject, path) {
    static iidDataObject := GuidBuffer("{0000010E-0000-0000-C000-000000000046}")
    stream := 0
    hGlobal := 0
    memory := 0
    marshaled := false
    persisted := false
    try {
        hr := DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0,
            "int", 1, "ptr*", &stream, "int")
        if !HResultSucceeded(hr) || !stream
            throw Error("无法创建 COM marshaling 流。")
        hr := DllCall("ole32\CoMarshalInterface", "ptr", stream,
            "ptr", iidDataObject.Ptr, "ptr", dataObject,
            "uint", 0, "ptr", 0, "uint", 0, "int")
        if !HResultSucceeded(hr)
            throw Error("来源数据对象不能安全跨进程 marshaling（HRESULT "
                . Format("0x{:08X}", hr & 0xFFFFFFFF) "）。")
        marshaled := true
        hr := DllCall("ole32\GetHGlobalFromStream", "ptr", stream,
            "ptr*", &hGlobal, "int")
        if !HResultSucceeded(hr) || !hGlobal
            throw Error("无法读取 COM marshaling 数据。")
        size := DllCall("kernel32\GlobalSize", "ptr", hGlobal, "uptr")
        memory := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
        if !size || !memory
            throw Error("COM marshaling 数据无效。")
        raw := Buffer(size, 0)
        DllCall("kernel32\RtlMoveMemory", "ptr", raw.Ptr,
            "ptr", memory, "uptr", size)
        file := FileOpen(path, "w")
        if !IsObject(file)
            throw Error("无法创建受控 marshaling 临时文件。")
        try file.RawWrite(raw)
        finally file.Close()
        persisted := true
    } catch as err {
        if marshaled && !persisted && stream {
            try ComCall(5, stream, "int64", 0, "uint", 0,
                "ptr", 0, "int")
            try DllCall("ole32\CoReleaseMarshalData",
                "ptr", stream, "int")
        }
        throw err
    } finally {
        if memory
            DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        if stream
            ObjRelease(stream)
    }
}

ReleaseMarshaledDataFile(path) {
    if !FileExist(path)
        return
    stream := 0
    hGlobal := 0
    memory := 0
    try {
        file := FileOpen(path, "r")
        if !IsObject(file)
            return
        size := file.Length
        if size <= 0 {
            file.Close()
            return
        }
        raw := Buffer(size, 0)
        file.RawRead(raw)
        file.Close()
        hGlobal := DllCall("kernel32\GlobalAlloc",
            "uint", 0x2, "uptr", size, "ptr")
        if !hGlobal
            return
        memory := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
        if !memory
            return
        DllCall("kernel32\RtlMoveMemory", "ptr", memory,
            "ptr", raw.Ptr, "uptr", size)
        DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        memory := 0
        hr := DllCall("ole32\CreateStreamOnHGlobal", "ptr", hGlobal,
            "int", 1, "ptr*", &stream, "int")
        if HResultSucceeded(hr) && stream {
            hGlobal := 0
            DllCall("ole32\CoReleaseMarshalData", "ptr", stream, "int")
        }
    } finally {
        if memory
            DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        if stream
            ObjRelease(stream)
        else if hGlobal
            DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        try FileDelete(path)
    }
}

ResolveTransferHelper() {
    candidates := [
        A_ScriptDir "\PopDropTransfer.exe",
        A_ScriptDir "\native\bin\" (A_PtrSize = 8 ? "x64" : "x86")
            "\PopDropTransfer.exe"
    ]
    for path in candidates {
        if FileExist(path)
            return path
    }
    return ""
}

EnsureTransferRuntimeDirectory() {
    root := A_Temp "\PopDrop-Transfers-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
    if !DirExist(root)
        DirCreate(root)
    return root
}

CreateTransferId(prefix) {
    guid := Buffer(16, 0)
    if DllCall("ole32\CoCreateGuid", "ptr", guid.Ptr, "int") = 0 {
        text := Buffer(80, 0)
        DllCall("ole32\StringFromGUID2", "ptr", guid.Ptr,
            "ptr", text.Ptr, "int", 40)
        value := StrReplace(StrReplace(StrGet(text), "{"), "}")
        return prefix "-" value
    }
    return prefix "-" DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
}

WaitForTransferHandshake(batch, timeoutMs) {
    started := A_TickCount
    while ElapsedTickMilliseconds(started, A_TickCount) < timeoutMs {
        if FileExist(batch.ReadyPath)
            return true
        if !ProcessExist(batch.Pid)
            throw Error("传输 helper 在接管数据前退出。")
        Sleep(15)
    }
    ; The marshaled packet still owns a COM reference. The helper may finish
    ; unmarshaling shortly after Drop returns; polling will report a failure
    ; if it cannot. Do not block the panel longer than this bounded handshake.
    return false
}

PollTransferJobs() {
    global TransferBatches, TransferHistory, TransferRefreshSources
    changed := false
    completedNow := []
    for id, batch in TransferBatches {
        previous := batch.Status "|" batch.LastUpdate "|"
            . (batch.Items.Length ? batch.Items.Length : 0)
        if FileExist(batch.StatePath)
            ReadTransferState(batch)
        else if !ProcessExist(batch.Pid) && !batch.Completed {
            batch.Status := "Failed"
            batch.Error := "传输 helper 意外退出。"
            batch.Completed := true
        }
        current := batch.Status "|" batch.LastUpdate "|"
            . (batch.Items.Length ? batch.Items.Length : 0)
        if previous != current
            changed := true
        if batch.Completed && !batch.RefreshQueued {
            batch.RefreshQueued := true
            completedNow.Push(batch)
            if TransferBatchSuccessCount(batch) > 0
                TransferRefreshSources[PathKey(batch.TargetPath)] := batch
        }
    }
    if TransferRefreshSources.Count {
        StartBackgroundScan()
        TransferRefreshSources := Map()
    }
    for batch in completedNow
        CompleteTransferBatchUi(batch)
    if completedNow.Length
        TrimTransferHistory(80)
    if changed
        UpdateTransferUi()
}

TrimTransferHistory(limit) {
    global TransferBatches
    completed := []
    for id, batch in TransferBatches {
        if batch.Completed
            completed.Push(id)
    }
    while completed.Length > limit {
        id := completed.RemoveAt(1)
        batch := TransferBatches[id]
        TransferBatches.Delete(id)
        try DirDelete(batch.Directory, true)
    }
}

ReadTransferState(batch) {
    try {
        status := IniRead(batch.StatePath, "Batch", "Status", batch.Status)
        batch.Status := status
        batch.Error := IniRead(batch.StatePath, "Batch", "Error", "")
        batch.Started := IniRead(batch.StatePath, "Batch", "Started", "")
        batch.Finished := IniRead(batch.StatePath, "Batch", "Finished", "")
        count := Integer(IniRead(batch.StatePath, "Batch", "ItemCount", "0"))
        items := []
        Loop count {
            section := "Item:" Format("{:03}", A_Index)
            items.Push({
                Id: IniRead(batch.StatePath, section, "Id", ""),
                Name: IniRead(batch.StatePath, section, "Name", "正在准备…"),
                Source: IniRead(batch.StatePath, section, "Source", batch.Adapter),
                Target: batch.TargetName,
                Status: IniRead(batch.StatePath, section, "Status", "Preparing"),
                Done: SafeIniInteger(batch.StatePath, section, "Done", 0),
                Total: SafeIniInteger(batch.StatePath, section, "Total", -1),
                Speed: SafeIniInteger(batch.StatePath, section, "Speed", 0),
                Error: IniRead(batch.StatePath, section, "Error", ""),
                ErrorCode: IniRead(batch.StatePath, section, "ErrorCode", ""),
                FinalPath: IniRead(batch.StatePath, section, "FinalPath", ""),
                Created: IniRead(batch.StatePath, section, "Created", ""),
                Started: IniRead(batch.StatePath, section, "Started", ""),
                Finished: IniRead(batch.StatePath, section, "Finished", ""),
                Retryable: IniRead(batch.StatePath, section, "Retryable", "0") = "1",
                Resumable: IniRead(batch.StatePath, section, "Resumable", "0") = "1"
            })
        }
        batch.Items := items
        batch.LastUpdate := A_TickCount
        batch.Completed := ValueInArray(status,
            ["Completed", "Failed", "Cancelled", "NeedsAttention"])
    } catch {
        ; Atomic writer may be between ReplaceFile and a network/AV observer.
        ; Keep the previous complete state and retry on the next 250 ms poll.
    }
}

SafeIniInteger(path, section, key, fallback) {
    try return Integer(IniRead(path, section, key, fallback ""))
    catch
        return fallback
}

TransferBatchSuccessCount(batch) {
    count := 0
    for item in batch.Items {
        if item.Status = "Completed"
            || (item.Status = "NeedsAttention" && item.FinalPath != "")
            count += 1
    }
    return count
}

TransferBatchActiveCount(batch) {
    count := 0
    for item in batch.Items {
        if ValueInArray(item.Status,
            ["Queued", "Preparing", "Connecting", "Receiving", "Finalizing",
             "WaitingForNetwork"])
            count += 1
    }
    return count
}

GetTransferAggregate() {
    global TransferBatches
    result := {Active: 0, Queued: 0, Failed: 0, Done: 0,
        Total: 0, KnownTotal: true, Speed: 0, Current: ""}
    for id, batch in TransferBatches {
        if !batch.Items.Length && !batch.Completed {
            result.Active += 1
            result.KnownTotal := false
            continue
        }
        for item in batch.Items {
            if ValueInArray(item.Status,
                ["Queued", "Preparing", "Connecting", "Receiving",
                 "Finalizing", "WaitingForNetwork"]) {
                if item.Status = "Queued"
                    result.Queued += 1
                else
                    result.Active += 1
                result.Done += item.Done
                result.Speed += item.Speed
                if item.Total >= 0
                    result.Total += item.Total
                else
                    result.KnownTotal := false
                if result.Current = ""
                    result.Current := item.Name
            } else if item.Status = "Failed" || item.Status = "NeedsAttention"
                result.Failed += 1
        }
    }
    return result
}

UpdateTransferUi() {
    global TransferStatusText, TransferCenter
    aggregate := GetTransferAggregate()
    if IsObject(TransferStatusText) {
        if aggregate.Active || aggregate.Queued {
            text := "↓ " aggregate.Active " 个进行中"
            if aggregate.Queued
                text .= " · " aggregate.Queued " 个等待"
            if aggregate.KnownTotal && aggregate.Total > 0
                text .= " · " Round(aggregate.Done * 100 / aggregate.Total) "%"
            if aggregate.Speed > 0
                text .= " · " FormatByteRate(aggregate.Speed)
            if aggregate.KnownTotal && aggregate.Total > aggregate.Done
                && aggregate.Speed > 0
                text .= " · 剩余约 "
                    . FormatDuration(Ceil(
                        (aggregate.Total - aggregate.Done) / aggregate.Speed))
            TransferStatusText.Text := text
        } else if aggregate.Failed
            TransferStatusText.Text := "↓ " aggregate.Failed " 个传输失败 · 点击查看"
        else
            TransferStatusText.Text := "↓ 无活动传输 · 点击查看"
    }
    UpdateTransferGroupHeaders()
    UpdateTransferTrayTip(aggregate)
    if IsObject(TransferCenter)
        RefreshTransferCenter()
}

FormatByteRate(value) {
    if value >= 1024 * 1024
        return Round(value / 1024 / 1024, 1) " MB/s"
    if value >= 1024
        return Round(value / 1024, 1) " KB/s"
    return value " B/s"
}

FormatDuration(seconds) {
    seconds := Max(0, Integer(seconds))
    if seconds < 60
        return seconds " 秒"
    minutes := Ceil(seconds / 60)
    if minutes < 60
        return minutes " 分钟"
    return Round(minutes / 60, 1) " 小时"
}

UpdateTransferGroupHeaders() {
    global GroupDropTargets, TransferBatches, FileView
    if !IsObject(FileView)
        return
    for groupId, descriptor in GroupDropTargets {
        if descriptor.Type != "Files"
            continue
        active := 0
        done := 0
        total := 0
        known := true
        for id, batch in TransferBatches {
            if !PathsEqual(batch.TargetPath, descriptor.Path) || batch.Completed
                continue
            active += Max(1, TransferBatchActiveCount(batch))
            for item in batch.Items {
                done += item.Done
                if item.Total >= 0
                    total += item.Total
                else
                    known := false
            }
        }
        header := HasProp(descriptor, "BaseHeader")
            ? descriptor.BaseHeader : descriptor.Name
        if active {
            header .= known && total > 0
                ? " · ↓ " Round(done * 100 / total) "%"
                : " · ↓ 正在接收 " active " 项"
        }
        SetListGroupHeader(FileView.Hwnd, groupId, header)
    }
}

SetListGroupHeader(hwnd, groupId, header) {
    groupSize := A_PtrSize = 8 ? 152 : 96
    group := Buffer(groupSize, 0)
    headerOffset := 8
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x1, group, 4)
    NumPut("ptr", StrPtr(header), group, headerOffset)
    DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x1093,
        "ptr", groupId, "ptr", group.Ptr, "ptr")
}

UpdateTransferTrayTip(aggregate) {
    global APP_VERSION
    if aggregate.Active || aggregate.Queued
        A_IconTip := "PopDrop v" APP_VERSION " · ↓ "
            . (aggregate.Active + aggregate.Queued) " 项"
    else if aggregate.Failed
        A_IconTip := "PopDrop v" APP_VERSION " · " aggregate.Failed " 个传输失败"
    else
        A_IconTip := "PopDrop v" APP_VERSION
}

CompleteTransferBatchUi(batch) {
    global TransferShowNotifications, PanelVisible
    success := TransferBatchSuccessCount(batch)
    failed := 0
    cancelled := 0
    for item in batch.Items {
        if item.Status = "Failed" || item.Status = "NeedsAttention"
            failed += 1
        else if item.Status = "Cancelled"
            cancelled += 1
    }
    if success
        SetActionStatus("后台接收完成：" success " 项已保存到「"
            . batch.TargetName "」"
            . (failed ? "，" failed " 项失败" : "")
            . "    打开目标文件夹",
            OpenFolderPath.Bind(batch.TargetPath))
    else if failed
        SetUserStatus("外部内容接收失败：" (batch.Error != ""
            ? batch.Error : "请打开传输中心查看详情。"))
    if !PanelVisible && TransferShowNotifications {
        title := failed ? "PopDrop 传输需要注意" : "PopDrop 传输完成"
        message := success " 项已保存到「" batch.TargetName "」"
        if failed
            message .= "，" failed " 项失败"
        try TrayTip(message, title, failed ? 3 : 1)
    }
}

OpenTransferCenter(*) {
    global Panel, TransferCenter
    if IsObject(TransferCenter) {
        TransferCenter.Show()
        WinActivate("ahk_id " TransferCenter.Hwnd)
        RefreshTransferCenter()
        return
    }
    center := Gui("+Owner" Panel.Hwnd " +Resize -MinimizeBox",
        "PopDrop 传输中心")
    center.SetFont("s9", "Microsoft YaHei UI")
    center.MarginX := 12
    center.MarginY := 10
    center.List := center.AddListView(
        "xm ym w820 h320 Report -Multi NoSortHdr",
        ["批次", "文件名", "来源", "目标", "进度", "速度", "状态"])
    center.List.ModifyCol(1, 78)
    center.List.ModifyCol(2, 190)
    center.List.ModifyCol(3, 95)
    center.List.ModifyCol(4, 90)
    center.List.ModifyCol(5, 120)
    center.List.ModifyCol(6, 80)
    center.List.ModifyCol(7, 135)
    center.CancelItem := center.AddButton("xm y+10 w92", "取消此项")
    center.CancelBatch := center.AddButton("x+8 yp w92", "取消整批")
    center.Retry := center.AddButton("x+8 yp w76", "重试")
    center.OpenFolder := center.AddButton("x+8 yp w110", "打开目标文件夹")
    center.Clear := center.AddButton("x+8 yp w116", "清除已完成记录")
    center.CancelItem.OnEvent("Click", CancelSelectedTransfer.Bind(false))
    center.CancelBatch.OnEvent("Click", CancelSelectedTransfer.Bind(true))
    center.Retry.OnEvent("Click", RetrySelectedTransfer)
    center.OpenFolder.OnEvent("Click", OpenSelectedTransferFolder)
    center.Clear.OnEvent("Click", ClearCompletedTransfers)
    center.OnEvent("Close", (*) => center.Hide())
    center.OnEvent("Escape", (*) => center.Hide())
    center.OnEvent("Size", ResizeTransferCenter)
    TransferCenter := center
    RefreshTransferCenter()
    center.Show("w844 h382")
}

RefreshTransferCenter() {
    global TransferCenter, TransferBatches, TransferCenterRows
    if !IsObject(TransferCenter)
        return
    list := TransferCenter.List
    list.Opt("-Redraw")
    list.Delete()
    TransferCenterRows := Map()
    for id, batch in TransferBatches {
        batchLabel := SubStr(StrReplace(id, "batch-", ""), 1, 8)
        if !batch.Items.Length {
            row := list.Add("", batchLabel, "正在准备…",
                batch.Adapter, batch.TargetName,
                "—", "—", TransferStatusLabel(batch.Status))
            TransferCenterRows[row] := {Batch: id, Item: ""}
            continue
        }
        for item in batch.Items {
            progress := item.Total >= 0
                ? FormatBytes(item.Done) " / " FormatBytes(item.Total)
                    . (item.Total ? " (" Round(item.Done * 100 / item.Total) "%)" : "")
                : FormatBytes(item.Done)
            if item.Total > item.Done && item.Speed > 0
                progress .= " · 剩余约 "
                    . FormatDuration(Ceil((item.Total - item.Done) / item.Speed))
            row := list.Add("", batchLabel, item.Name,
                item.Source, batch.TargetName,
                progress, item.Speed ? FormatByteRate(item.Speed) : "—",
                TransferStatusLabel(item.Status)
                    . (item.Error != "" ? " · " item.Error : ""))
            TransferCenterRows[row] := {Batch: id, Item: item.Id}
        }
    }
    list.Opt("+Redraw")
}

TransferStatusLabel(status) {
    labels := Map("Queued", "等待", "Preparing", "准备",
        "Connecting", "连接", "Receiving", "接收中",
        "Finalizing", "完成处理中", "Completed", "已完成",
        "WaitingForNetwork", "等待网络", "NeedsAttention", "需要处理",
        "Failed", "失败", "Cancelled", "已取消")
    return labels.Has(status) ? labels[status] : status
}

FormatBytes(value) {
    if value < 0
        return "未知"
    if value >= 1024 * 1024 * 1024
        return Round(value / 1024 / 1024 / 1024, 2) " GB"
    if value >= 1024 * 1024
        return Round(value / 1024 / 1024, 1) " MB"
    if value >= 1024
        return Round(value / 1024, 1) " KB"
    return value " B"
}

GetSelectedTransferReference() {
    global TransferCenter, TransferCenterRows
    if !IsObject(TransferCenter)
        return 0
    row := TransferCenter.List.GetNext(0, "F")
    return row && TransferCenterRows.Has(row) ? TransferCenterRows[row] : 0
}

CancelSelectedTransfer(wholeBatch, *) {
    global TransferBatches
    reference := GetSelectedTransferReference()
    if !IsObject(reference) || !TransferBatches.Has(reference.Batch)
        return
    batch := TransferBatches[reference.Batch]
    content := wholeBatch || reference.Item = ""
        ? "BATCH" : reference.Item
    try {
        try FileDelete(batch.CancelPath)
        FileAppend(content, batch.CancelPath, "UTF-8")
    }
    UpdateTransferUi()
}

RetrySelectedTransfer(*) {
    global TransferBatches
    reference := GetSelectedTransferReference()
    if !IsObject(reference) || !TransferBatches.Has(reference.Batch)
        return
    batch := TransferBatches[reference.Batch]
    retryable := false
    for item in batch.Items {
        if item.Id = reference.Item && item.Retryable
            && ValueInArray(item.Status, ["Failed", "NeedsAttention"]) {
            retryable := true
            break
        }
    }
    if !retryable || !FileExist(batch.RetryPath) {
        SetUserStatus("此任务无法安全重试；请从来源重新拖入。")
        return
    }
    try {
        RetryUrlTransfer(batch)
        SetUserStatus("已将公开 URL 任务重新加入传输队列。")
    } catch as err {
        SetUserStatus("无法重试：" err.Message)
    }
}

RetryUrlTransfer(previous) {
    global TransferBatches, TransferAllowHttp, TransferMaxConcurrent
    helper := ResolveTransferHelper()
    if helper = ""
        throw Error("缺少 PopDropTransfer.exe。")
    root := EnsureTransferRuntimeDirectory()
    batchId := CreateTransferId("batch")
    batchDir := root "\" batchId
    DirCreate(batchDir)
    statePath := batchDir "\state.ini"
    cancelPath := batchDir "\cancel"
    readyPath := batchDir "\ready"
    requestPath := batchDir "\request.ini"
    retryPath := batchDir "\url-retry.dpapi"
    FileCopy(previous.RetryPath, retryPath, false)
    request :=
    (
    "[Transfer]`r`n"
    "Protocol=2`r`n"
    "BatchId=" batchId "`r`n"
    "Adapter=UrlRetry`r`n"
    "TargetPath=" previous.TargetPath "`r`n"
    "TargetSourceId=" previous.TargetSourceId "`r`n"
    "TargetName=" previous.TargetName "`r`n"
    "StatePath=" statePath "`r`n"
    "CancelPath=" cancelPath "`r`n"
    "ReadyPath=" readyPath "`r`n"
    "RetryPath=" retryPath "`r`n"
    "AllowHttp=" (TransferAllowHttp ? "1" : "0") "`r`n"
    "MaxConcurrent=" TransferMaxConcurrent "`r`n"
    )
    FileAppend(request, requestPath, "UTF-16")
    Run(QuoteWindowsArgument(helper) " --request "
        . QuoteWindowsArgument(requestPath), A_ScriptDir, "Hide", &pid)
    batch := {
        Id: batchId, Adapter: "Url", TargetPath: previous.TargetPath,
        TargetSourceId: previous.TargetSourceId,
        TargetName: previous.TargetName, Directory: batchDir,
        RequestPath: requestPath, StatePath: statePath,
        CancelPath: cancelPath, ReadyPath: readyPath, MarshalPath: "",
        RetryPath: retryPath, Pid: pid, Status: "Preparing", Items: [],
        Created: A_Now, Completed: false, RefreshQueued: false,
        LastUpdate: A_TickCount
    }
    TransferBatches[batchId] := batch
    WaitForTransferHandshake(batch, 1200)
    UpdateTransferUi()
}

OpenSelectedTransferFolder(*) {
    global TransferBatches
    reference := GetSelectedTransferReference()
    if IsObject(reference) && TransferBatches.Has(reference.Batch)
        OpenFolderPath(TransferBatches[reference.Batch].TargetPath)
}

ClearCompletedTransfers(*) {
    global TransferBatches
    remove := []
    for id, batch in TransferBatches {
        if batch.Completed
            remove.Push(id)
    }
    for id in remove {
        batch := TransferBatches[id]
        TransferBatches.Delete(id)
        try DirDelete(batch.Directory, true)
    }
    UpdateTransferUi()
}

ResizeTransferCenter(guiObj, minMax, width, height) {
    if minMax = -1
        return
    guiObj.List.Move(, , Max(500, width - 24), Max(180, height - 62))
    guiObj.CancelItem.Move(, height - 38)
    guiObj.CancelBatch.Move(, height - 38)
    guiObj.Retry.Move(, height - 38)
    guiObj.OpenFolder.Move(, height - 38)
    guiObj.Clear.Move(, height - 38)
}

CleanupOldTransferArtifacts() {
    global TransferBatches, TransferLastOrphanCleanup
    now := A_Now
    remove := []
    for id, batch in TransferBatches {
        if batch.Completed && HasProp(batch, "Finished")
            && batch.Finished != "" {
            age := DateDiff(now, batch.Finished, "Hours")
            if age >= 24
                remove.Push(id)
        }
    }
    for id in remove {
        batch := TransferBatches[id]
        TransferBatches.Delete(id)
        try DirDelete(batch.Directory, true)
    }
    if !TransferLastOrphanCleanup
        || ElapsedTickMilliseconds(
            TransferLastOrphanCleanup, A_TickCount) >= 3600000 {
        TransferLastOrphanCleanup := A_TickCount
        CleanupOrphanedTransferArtifacts()
    }
}

CleanupOrphanedTransferArtifacts() {
    currentRoot := EnsureTransferRuntimeDirectory()
    Loop Files, A_Temp "\PopDrop-Transfers-*", "D" {
        runtimeRoot := A_LoopFileFullPath
        if PathsEqual(runtimeRoot, currentRoot)
            continue
        try {
            if DateDiff(A_Now, A_LoopFileTimeModified, "Hours") < 24
                continue
        } catch
            continue
        canRemoveRoot := true
        Loop Files, runtimeRoot "\batch-*", "D" {
            batchDir := A_LoopFileFullPath
            requestPath := batchDir "\request.ini"
            if !FileExist(requestPath) {
                try DirDelete(batchDir, true)
                continue
            }
            batchId := IniRead(requestPath, "Transfer", "BatchId", "")
            targetPath := IniRead(requestPath, "Transfer", "TargetPath", "")
            if !RegExMatch(batchId, "i)^batch-[0-9a-f-]+$")
                || !DirExist(targetPath) {
                canRemoveRoot := false
                continue
            }
            prefix := SubStr(batchId, 1, 12)
            Loop Files, targetPath "\*." prefix "*.popdrop-part", "F" {
                try {
                    if DateDiff(A_Now, A_LoopFileTimeModified, "Hours") >= 24
                        FileDelete(A_LoopFileFullPath)
                }
            }
            remaining := false
            Loop Files, targetPath "\*." prefix "*.popdrop-part", "F" {
                remaining := true
                break
            }
            if remaining
                canRemoveRoot := false
            else
                try DirDelete(batchDir, true)
        }
        if canRemoveRoot
            try DirDelete(runtimeRoot, true)
    }
}

PrepareExitWithTransfers() {
    global TransferBatches
    active := 0
    for id, batch in TransferBatches {
        if !batch.Completed
            active += 1
    }
    if !active
        return true
    answer := ShowPanelMsgBox("仍有 " active
        . " 个后台传输批次。`n`n选择“是”取消任务并退出；"
        . "选择“否”返回 PopDrop。", "退出 PopDrop", "YesNo Icon!")
    if answer != "Yes"
        return false
    for id, batch in TransferBatches {
        if !batch.Completed {
            try {
                try FileDelete(batch.CancelPath)
                FileAppend("BATCH", batch.CancelPath, "UTF-8")
            }
        }
    }
    return true
}

CleanupExternalTransfers() {
    global TransferBatches
    SetTimer(PollTransferJobs, 0)
    SetTimer(CleanupOldTransferArtifacts, 0)
    for id, batch in TransferBatches {
        if !batch.Completed {
            try {
                try FileDelete(batch.CancelPath)
                FileAppend("BATCH", batch.CancelPath, "UTF-8")
            }
        }
    }
}
