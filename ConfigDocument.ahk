; Lossless, layout-aware editor for PopDrop's human-maintained config.ini.
; It deliberately does not use the Windows profile API for writes.

class PopDropConfigDocument {
    __New(path) {
        this.Path := path
        this.Lines := []
        this.Dirty := false
        this.Load()
    }

    Load() {
        raw := FileRead(this.Path, "RAW")
        if raw.Size < 2 || NumGet(raw, 0, "UShort") != 0xFEFF
            throw Error("配置文件必须是带 BOM 的 UTF-16LE：" this.Path)

        text := FileRead(this.Path, "UTF-16")
        ; FileRead consumes one BOM. Remove legacy duplicate BOM characters.
        while SubStr(text, 1, 1) = Chr(0xFEFF) {
            text := SubStr(text, 2)
            this.Dirty := true
        }
        text := StrReplace(text, "`r`n", "`n")
        text := StrReplace(text, "`r", "`n")
        this.Lines := StrSplit(text, "`n")
        if !this.Lines.Length
            this.Lines.Push("")
    }

    EnsureLayout() {
        markers := this.GetAreaMarkers()
        if markers.Count = 0
            this.InstallAreaMarkers()
        else if markers.Count != 6
            throw Error("配置布局标记不完整；应有 6 个，实际有 " markers.Count " 个。")

        this.ValidateAreaMarkers()
        this.NormalizeManagedSections()
    }

    InstallAreaMarkers() {
        numerals := ["一", "二", "三", "四", "五", "六"]
        bannerPositions := Map()
        for area, numeral in numerals {
            found := 0
            for index, line in this.Lines {
                if RegExMatch(line, "^\s*;\s*" numeral "、") {
                    if found
                        throw Error("第 " area " 区标题重复，无法安全安装布局标记。")
                    found := index
                }
            }
            if found
                bannerPositions[area] := found
        }

        if bannerPositions.Count = 6 {
            ; Insert backwards so the recorded positions remain valid.
            Loop 6 {
                area := 7 - A_Index
                insertAt := bannerPositions[area]
                if insertAt > 1
                    && RegExMatch(this.Lines[insertAt - 1], "^\s*;\s*={3,}\s*$")
                    insertAt -= 1
                this.Lines.InsertAt(insertAt, "; <PopDrop:area " area ">")
            }
            this.Dirty := true
            return
        }

        ; Compact legacy configurations have no numbered banners. Keep their
        ; free-form comments intact, create a canonical six-area skeleton, and
        ; let NormalizeManagedSections move every known section into it.
        generalAt := 1
        for info in this.GetSectionInfos() {
            if StrLower(info.Name) = "general" {
                generalAt := info.Header
                break
            }
        }
        this.Lines.InsertAt(generalAt, "; <PopDrop:area 1>")
        if Trim(this.Lines[this.Lines.Length]) != ""
            this.Lines.Push("")
        Loop 5 {
            area := A_Index + 1
            this.Lines.Push("; <PopDrop:area " area ">")
        }
        this.Dirty := true
    }

    NormalizeManagedSections() {
        ; Re-evaluate after every move. This converges quickly and avoids stale
        ; line indexes while retaining the relative order of equal-rank blocks.
        Loop 4 {
            moved := false
            names := this.GetSectionNames()
            for name in names {
                area := this.AreaForSection(name)
                if area && this.SectionNeedsMove(name, area) {
                    this.MoveSection(name, area)
                    moved := true
                }
            }
            if !moved
                return
        }
        throw Error("配置节顺序无法收敛；配置可能含有冲突的节名。")
    }

    GetValue(section, key, default := "") {
        info := this.RequireUniqueSection(section, false)
        if !IsObject(info)
            return default
        match := 0
        value := default
        Loop info.End - info.Header {
            index := info.Header + A_Index
            parsed := this.ParseKeyLine(this.Lines[index])
            if IsObject(parsed) && StrLower(parsed.Key) = StrLower(key) {
                if match
                    throw Error("重复配置键：[" section "] " key)
                match := index
                value := parsed.Value
            }
        }
        return value
    }

    GetEntries(section) {
        result := []
        info := this.RequireUniqueSection(section, false)
        if !IsObject(info)
            return result
        seen := Map()
        Loop info.End - info.Header {
            index := info.Header + A_Index
            parsed := this.ParseKeyLine(this.Lines[index])
            if !IsObject(parsed)
                continue
            folded := StrLower(parsed.Key)
            if seen.Has(folded)
                throw Error("重复配置键：[" section "] " parsed.Key)
            seen[folded] := true
            result.Push(parsed)
        }
        return result
    }

    SetValue(section, key, value, area := 0) {
        this.AssertName(section, "节名")
        this.AssertName(key, "键名")
        this.AssertValue(value)
        if area
            this.EnsureSection(section, area)
        info := this.RequireUniqueSection(section)

        found := 0
        Loop info.End - info.Header {
            index := info.Header + A_Index
            parsed := this.ParseKeyLine(this.Lines[index])
            if IsObject(parsed) && StrLower(parsed.Key) = StrLower(key) {
                if found
                    throw Error("重复配置键：[" section "] " key)
                found := index
            }
        }
        newLine := key "=" value
        if found {
            if this.Lines[found] != newLine {
                this.Lines[found] := newLine
                this.Dirty := true
            }
            return
        }

        insertAt := this.FindKeyInsertIndex(info)
        this.Lines.InsertAt(insertAt, newLine)
        this.Dirty := true
    }

    SetValues(section, entries, area := 0) {
        for entry in entries
            this.SetValue(section, entry.Key, entry.Value, area)
    }

    ReplaceSection(section, entries, area) {
        this.AssertEntries(entries)
        this.EnsureSection(section, area)
        info := this.RequireUniqueSection(section)
        keyLines := []
        Loop info.End - info.Header {
            index := info.Header + A_Index
            if IsObject(this.ParseKeyLine(this.Lines[index]))
                keyLines.Push(index)
        }
        insertAt := keyLines.Length ? keyLines[1] : this.FindKeyInsertIndex(info)
        Loop keyLines.Length {
            index := keyLines[keyLines.Length - A_Index + 1]
            this.Lines.RemoveAt(index)
        }
        for offset, entry in entries
            this.Lines.InsertAt(insertAt + offset - 1, entry.Key "=" entry.Value)
        this.Dirty := true
    }

    ReplaceKnownKeys(section, entries, knownKeys, area) {
        this.AssertEntries(entries)
        known := Map()
        for key in knownKeys {
            this.AssertName(key, "键名")
            known[StrLower(key)] := true
        }
        for entry in entries {
            if !known.Has(StrLower(entry.Key))
                throw Error("待写入键不属于受管理键集合：" entry.Key)
        }

        this.EnsureSection(section, area)
        info := this.RequireUniqueSection(section)
        keyLines := []
        Loop info.End - info.Header {
            index := info.Header + A_Index
            parsed := this.ParseKeyLine(this.Lines[index])
            if IsObject(parsed) && known.Has(StrLower(parsed.Key))
                keyLines.Push(index)
        }
        insertAt := keyLines.Length ? keyLines[1] : this.FindKeyInsertIndex(info)
        Loop keyLines.Length {
            index := keyLines[keyLines.Length - A_Index + 1]
            this.Lines.RemoveAt(index)
        }
        for offset, entry in entries
            this.Lines.InsertAt(insertAt + offset - 1, entry.Key "=" entry.Value)
        this.Dirty := true
    }

    EnsureCommentBlock(section, marker, comments, area) {
        this.AssertName(section, "节名")
        if Trim(marker) = "" || SubStr(LTrim(marker), 1, 1) != ";"
            throw Error("配置注释标记必须是分号注释。")
        this.EnsureSection(section, area)
        info := this.RequireUniqueSection(section)
        Loop info.End - info.Header {
            if Trim(this.Lines[info.Header + A_Index], " `t") = Trim(marker, " `t")
                return
        }
        insertAt := info.Header + 1
        additions := [marker]
        for line in comments {
            if SubStr(LTrim(line), 1, 1) != ";"
                throw Error("配置说明必须是分号注释。")
            additions.Push(line)
        }
        for offset, line in additions
            this.Lines.InsertAt(insertAt + offset - 1, line)
        this.Dirty := true
    }

    DeleteSection(section) {
        info := this.RequireUniqueSection(section, false)
        if !IsObject(info)
            return
        lastOwned := info.Header
        Loop info.End - info.Header {
            index := info.Header + A_Index
            line := this.Lines[index]
            trimmed := LTrim(line, " `t")
            if trimmed != "" && SubStr(trimmed, 1, 1) != ";"
                && SubStr(trimmed, 1, 1) != "#"
                lastOwned := index
        }
        this.Lines.RemoveAt(info.Header, lastOwned - info.Header + 1)
        this.Dirty := true
    }

    EnsureSection(section, area) {
        this.AssertName(section, "节名")
        info := this.RequireUniqueSection(section, false)
        if !IsObject(info) {
            insertAt := this.FindSectionInsertIndex(area, this.RankForSection(section))
            additions := ["[" section "]"]
            if insertAt > 1 && Trim(this.Lines[insertAt - 1]) != ""
                additions.InsertAt(1, "")
            additions.Push("")
            for offset, line in additions
                this.Lines.InsertAt(insertAt + offset - 1, line)
            this.Dirty := true
            return
        }
        if this.SectionNeedsMove(section, area)
            this.MoveSection(section, area)
    }

    MoveSection(section, area) {
        info := this.RequireUniqueSection(section)
        lastOwned := info.Header
        Loop info.End - info.Header {
            index := info.Header + A_Index
            line := this.Lines[index]
            trimmed := LTrim(line, " `t")
            if trimmed != "" && SubStr(trimmed, 1, 1) != ";"
                && SubStr(trimmed, 1, 1) != "#"
                lastOwned := index
        }

        block := []
        Loop lastOwned - info.Header + 1
            block.Push(this.Lines[info.Header + A_Index - 1])
        this.Lines.RemoveAt(info.Header, block.Length)

        insertAt := this.FindSectionInsertIndex(area, this.RankForSection(section))
        if insertAt > 1 && Trim(this.Lines[insertAt - 1]) != ""
            block.InsertAt(1, "")
        block.Push("")
        for offset, line in block
            this.Lines.InsertAt(insertAt + offset - 1, line)
        this.Dirty := true
    }

    SectionNeedsMove(section, area) {
        info := this.RequireUniqueSection(section)
        currentArea := this.AreaAt(info.Header)
        if currentArea != area
            return true
        rank := this.RankForSection(section)
        for other in this.GetSectionInfos() {
            if other.Header >= info.Header
                break
            if this.AreaAt(other.Header) = area
                && this.RankForSection(other.Name) > rank
                return true
        }
        return false
    }

    FindKeyInsertIndex(info) {
        lastKey := 0
        Loop info.End - info.Header {
            index := info.Header + A_Index
            if IsObject(this.ParseKeyLine(this.Lines[index]))
                lastKey := index
        }
        if lastKey
            return lastKey + 1
        ; For a new/empty section, keep explanatory comments above values, but
        ; do not create a blank line between the header and its first key.
        index := info.Header + 1
        sawComment := false
        while index <= info.End {
            trimmed := Trim(this.Lines[index], " `t")
            if SubStr(trimmed, 1, 1) = ";"
                || SubStr(trimmed, 1, 1) = "#" {
                sawComment := true
                index += 1
                continue
            }
            if trimmed = "" && sawComment {
                index += 1
                continue
            }
            break
        }
        return index
    }

    FindSectionInsertIndex(area, rank) {
        nextMarker := this.FindAreaMarker(area + 1)
        areaEnd := nextMarker ? nextMarker : this.Lines.Length + 1
        for info in this.GetSectionInfos() {
            if info.Header >= areaEnd
                break
            if this.AreaAt(info.Header) = area
                && this.RankForSection(info.Name) > rank
                return info.Header
        }
        return areaEnd
    }

    FindFirstSectionInArea(area) {
        for info in this.GetSectionInfos() {
            if this.AreaForSection(info.Name) = area
                return info.Header
        }
        return 0
    }

    FindAreaMarker(area) {
        if area < 1 || area > 6
            return 0
        for index, line in this.Lines {
            if this.ParseAreaMarker(line) = area
                return index
        }
        return 0
    }

    GetAreaMarkers() {
        result := Map()
        for index, line in this.Lines {
            area := this.ParseAreaMarker(line)
            if !area
                continue
            if result.Has(area)
                throw Error("配置布局标记重复：area " area)
            result[area] := index
        }
        return result
    }

    ValidateAreaMarkers() {
        last := 0
        markers := this.GetAreaMarkers()
        Loop 6 {
            if !markers.Has(A_Index)
                throw Error("缺少配置布局标记：area " A_Index)
            if markers[A_Index] <= last
                throw Error("配置布局标记顺序错误：area " A_Index)
            last := markers[A_Index]
        }
    }

    AreaAt(lineIndex) {
        result := 0
        for index, line in this.Lines {
            if index > lineIndex
                break
            marker := this.ParseAreaMarker(line)
            if marker
                result := marker
        }
        return result
    }

    AreaForSection(section) {
        folded := StrLower(section)
        if folded = "general" || folded = "filemanager"
            || folded = "preview"
            || folded = "noisefilter"
            || folded = "externaltransfer"
            return 1
        if folded = "folders" || folded = "pinnedfiles"
            || SubStr(folded, 1, 7) = "folder:"
            return 2
        if folded = "sources" || folded = "workspaces"
            || SubStr(folded, 1, 10) = "workspace:"
            || SubStr(folded, 1, 16) = "workspacepinned:"
            || (SubStr(folded, 1, 7) = "source:"
                && SubStr(folded, 1, 14) != "sourceexclude:"
                && SubStr(folded, 1, 12) != "sourceallow:")
            return 3
        if folded = "openapps" || SubStr(folded, 1, 8) = "openapp:"
            || SubStr(folded, 1, 14) = "openappaction:"
            return 4
        if folded = "transferfavorites"
            || folded = "transferfavoritelabels"
            || folded = "recenttargets"
            return 5
        if folded = "excludedfoldernames"
            || SubStr(folded, 1, 14) = "sourceexclude:"
            || SubStr(folded, 1, 12) = "sourceallow:"
            || SubStr(folded, 1, 13) = "sourceignore:"
            return 6
        return 0
    }

    RankForSection(section) {
        folded := StrLower(section)
        area := this.AreaForSection(section)
        if area = 1 {
            if folded = "general"
                return 10
            if folded = "externaltransfer"
                return 20
            if folded = "filemanager"
                return 25
            if folded = "preview"
                return 27
            return 30
        }
        if area = 2 {
            if folded = "folders"
                return 10
            if SubStr(folded, 1, 7) = "folder:"
                return 20
            return 30
        }
        if area = 3 {
            if folded = "workspaces"
                return 10
            if SubStr(folded, 1, 10) = "workspace:"
                return 20
            if SubStr(folded, 1, 16) = "workspacepinned:"
                return 25
            if folded = "sources"
                return 30
            return 40
        }
        if area = 4 {
            if folded = "openapps"
                return 10
            if SubStr(folded, 1, 14) = "openappaction:"
                return 30
            return 20
        }
        if area = 5 {
            if folded = "transferfavorites"
                return 10
            if folded = "transferfavoritelabels"
                return 20
            return 30
        }
        if area = 6 {
            if SubStr(folded, 1, 14) = "sourceexclude:"
                return 10
            if SubStr(folded, 1, 12) = "sourceallow:"
                return 20
            if SubStr(folded, 1, 13) = "sourceignore:"
                return 30
            return 40
        }
        return 100
    }

    GetSectionNames() {
        result := []
        for info in this.GetSectionInfos()
            result.Push(info.Name)
        return result
    }

    GetSectionInfos() {
        result := []
        headers := []
        for index, line in this.Lines {
            name := this.ParseSectionLine(line)
            if name != ""
                headers.Push({Name: name, Header: index})
        }
        for index, header in headers {
            ending := index < headers.Length
                ? headers[index + 1].Header - 1 : this.Lines.Length
            ; Explicit area markers terminate the preceding section.
            Loop ending - header.Header {
                candidate := header.Header + A_Index
                if this.ParseAreaMarker(this.Lines[candidate]) {
                    ending := candidate - 1
                    break
                }
            }
            result.Push({Name: header.Name, Header: header.Header, End: ending})
        }
        return result
    }

    RequireUniqueSection(section, required := true) {
        found := 0
        for info in this.GetSectionInfos() {
            if StrLower(info.Name) != StrLower(section)
                continue
            if IsObject(found)
                throw Error("重复配置节：[" section "]")
            found := info
        }
        if required && !IsObject(found)
            throw Error("缺少配置节：[" section "]")
        return found
    }

    ParseSectionLine(line) {
        trimmed := Trim(line, " `t")
        if StrLen(trimmed) < 3 || SubStr(trimmed, 1, 1) != "["
            || SubStr(trimmed, StrLen(trimmed), 1) != "]"
            return ""
        name := Trim(SubStr(trimmed, 2, StrLen(trimmed) - 2), " `t")
        return name
    }

    ParseKeyLine(line) {
        trimmed := LTrim(line, " `t")
        if trimmed = "" || InStr(";#", SubStr(trimmed, 1, 1))
            || SubStr(trimmed, 1, 1) = "["
            return 0
        equals := InStr(line, "=")
        if !equals
            return 0
        key := Trim(SubStr(line, 1, equals - 1), " `t")
        if key = ""
            return 0
        return {Key: key, Value: SubStr(line, equals + 1)}
    }

    ParseAreaMarker(line) {
        if RegExMatch(line,
            "^\s*;\s*<PopDrop:area\s+([1-6])>\s*$", &match)
            return Integer(match[1])
        return 0
    }

    Validate(requireVersion := true) {
        this.ValidateAreaMarkers()
        seenSections := Map()
        for info in this.GetSectionInfos() {
            foldedSection := StrLower(info.Name)
            if seenSections.Has(foldedSection)
                throw Error("重复配置节：[" info.Name "]")
            seenSections[foldedSection] := true
            seenKeys := Map()
            Loop info.End - info.Header {
                parsed := this.ParseKeyLine(this.Lines[info.Header + A_Index])
                if !IsObject(parsed)
                    continue
                foldedKey := StrLower(parsed.Key)
                if seenKeys.Has(foldedKey)
                    throw Error("重复配置键：[" info.Name "] " parsed.Key)
                seenKeys[foldedKey] := true
            }
            expectedArea := this.AreaForSection(info.Name)
            if expectedArea && this.AreaAt(info.Header) != expectedArea
                throw Error("配置节位置错误：[" info.Name "] 应位于第 "
                    expectedArea " 区。")
        }
        if !seenSections.Has("general")
            throw Error("缺少 [General] 配置节。")
        if requireVersion
            && this.GetValue("General", "ConfigVersion", "") = ""
            throw Error("[General] 缺少 ConfigVersion。")
    }

    Save() {
        this.Validate()
        if !this.Dirty
            return
        text := ""
        for index, line in this.Lines {
            if index > 1
                text .= "`r`n"
            text .= line
        }
        output := FileOpen(this.Path, "w", "UTF-16")
        try output.Write(text)
        finally output.Close()

        raw := FileRead(this.Path, "RAW")
        if raw.Size < 4 || NumGet(raw, 0, "UShort") != 0xFEFF
            || NumGet(raw, 2, "UShort") = 0xFEFF
            throw Error("配置写回后的 UTF-16LE BOM 校验失败。")
        this.Dirty := false
    }

    AssertEntries(entries) {
        seen := Map()
        for entry in entries {
            this.AssertName(entry.Key, "键名")
            this.AssertValue(entry.Value)
            folded := StrLower(entry.Key)
            if seen.Has(folded)
                throw Error("待写入键重复：" entry.Key)
            seen[folded] := true
        }
    }

    AssertName(name, kind) {
        if name = "" || InStr(name, "`r") || InStr(name, "`n")
            || InStr(name, "=")
            throw Error("无效的" kind "：" name)
        if kind = "节名" && (InStr(name, "[") || InStr(name, "]"))
            throw Error("无效的" kind "：" name)
    }

    AssertValue(value) {
        if InStr(value, "`r") || InStr(value, "`n")
            throw Error("配置值不能包含换行。")
    }
}

ConfigEntriesFromValues(values, prefix, width := 3) {
    result := []
    for index, value in values
        result.Push({Key: prefix Format("{:0" width "}", index),
            Value: value})
    return result
}

OpenPopDropConfig(path) {
    doc := PopDropConfigDocument(path)
    doc.EnsureLayout()
    ; Reject ambiguity before any writer gets a chance to normalize it away.
    doc.Validate(false)
    return doc
}
