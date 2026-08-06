; Transactional per-workspace runtime index backed by Windows WinSQLite3.
; config.ini remains the editable source of truth. If WinSQLite3 is missing or
; a database operation fails, ScanCache transparently keeps the legacy INI
; snapshot path as a compatibility fallback.

EnsureRuntimeIndexLibrary() {
    global RuntimeIndexModule
    if RuntimeIndexModule
        return true
    ; Keep WinSQLite loaded for the lifetime of every sqlite3* handle.  Letting
    ; AutoHotkey load/unload the DLL around individual DllCall invocations can
    ; invalidate SQLite's process state while a database handle is still live.
    RuntimeIndexModule := DllCall("kernel32\LoadLibraryExW",
        "wstr", "winsqlite3.dll", "ptr", 0, "uint", 0x800,
        "ptr") ; LOAD_LIBRARY_SEARCH_SYSTEM32
    return RuntimeIndexModule != 0
}

InitializeRuntimeIndex(allowRecovery := true) {
    global RuntimeIndexDb, RuntimeIndexPath, RuntimeIndexAvailable, CacheDir
    targetPath := CacheDir "\index.db"
    if RuntimeIndexAvailable && RuntimeIndexDb && RuntimeIndexPath = targetPath
        return true
    CloseRuntimeIndex()
    if !EnsureRuntimeIndexLibrary()
        return false
    RuntimeIndexPath := targetPath
    opened := false
    try {
        db := 0
        rc := DllCall("winsqlite3\sqlite3_open16", "wstr", targetPath,
            "ptr*", &db, "cdecl int")
        if rc != 0 || !db {
            if db
                try DllCall("winsqlite3\sqlite3_close_v2", "ptr", db,
                    "cdecl int")
            return false
        }
        RuntimeIndexDb := db
        opened := true
        RuntimeIndexExec("PRAGMA journal_mode=WAL;")
        RuntimeIndexExec("PRAGMA synchronous=NORMAL;")
        RuntimeIndexExec("PRAGMA foreign_keys=ON;")
        RuntimeIndexExec("CREATE TABLE IF NOT EXISTS meta ("
            . "key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        RuntimeIndexExec("CREATE TABLE IF NOT EXISTS workspace_snapshot ("
            . "workspace_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, "
            . "updated_at TEXT NOT NULL);")
        RuntimeIndexExec("CREATE TABLE IF NOT EXISTS source_snapshot ("
            . "workspace_id TEXT NOT NULL, source_index INTEGER NOT NULL, "
            . "name TEXT NOT NULL, path TEXT NOT NULL, state TEXT NOT NULL, "
            . "PRIMARY KEY(workspace_id, source_index));")
        RuntimeIndexExec("CREATE TABLE IF NOT EXISTS item_snapshot ("
            . "workspace_id TEXT NOT NULL, source_index INTEGER NOT NULL, "
            . "item_index INTEGER NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL, "
            . "modified TEXT NOT NULL, is_directory INTEGER NOT NULL, "
            . "time_kind TEXT NOT NULL, "
            . "PRIMARY KEY(workspace_id, source_index, item_index));")
        RuntimeIndexExec("CREATE INDEX IF NOT EXISTS idx_item_source "
            . "ON item_snapshot(workspace_id, source_index);")
        RuntimeIndexExec("CREATE TABLE IF NOT EXISTS recent_snapshot ("
            . "workspace_id TEXT NOT NULL, item_index INTEGER NOT NULL, "
            . "path TEXT NOT NULL, name TEXT NOT NULL, modified TEXT NOT NULL, "
            . "PRIMARY KEY(workspace_id, item_index));")
        RuntimeIndexExec("CREATE TABLE IF NOT EXISTS watch_state ("
            . "workspace_id TEXT NOT NULL, source_index INTEGER NOT NULL, "
            . "healthy INTEGER NOT NULL DEFAULT 0, overflowed INTEGER NOT NULL DEFAULT 0, "
            . "last_event TEXT NOT NULL DEFAULT '', "
            . "PRIMARY KEY(workspace_id, source_index));")
        RuntimeIndexExec("INSERT OR REPLACE INTO meta(key,value) "
            . "VALUES('schema_version','1');")
        RuntimeIndexAvailable := true
        return true
    } catch {
        closed := CloseRuntimeIndex()
        if opened && closed && allowRecovery && FileExist(targetPath) {
            quarantine := targetPath ".corrupt-" A_Now
            try FileMove(targetPath, quarantine, 1)
            if FileExist(targetPath "-wal")
                try FileMove(targetPath "-wal", quarantine "-wal", 1)
            if FileExist(targetPath "-shm")
                try FileMove(targetPath "-shm", quarantine "-shm", 1)
            return InitializeRuntimeIndex(false)
        }
        return false
    }
}

RuntimeIndexExec(sql) {
    global RuntimeIndexDb
    errorMessage := 0
    rc := DllCall("winsqlite3\sqlite3_exec", "ptr", RuntimeIndexDb,
        "astr", sql, "ptr", 0, "ptr", 0, "ptr*", &errorMessage,
        "cdecl int")
    if errorMessage
        DllCall("winsqlite3\sqlite3_free", "ptr", errorMessage)
    if rc != 0
        throw Error("SQLite exec failed: " rc)
}

RuntimeIndexPrepare(sql) {
    global RuntimeIndexDb
    statement := 0
    rc := DllCall("winsqlite3\sqlite3_prepare_v2", "ptr", RuntimeIndexDb,
        "astr", sql, "int", -1, "ptr*", &statement, "ptr", 0,
        "cdecl int")
    if rc != 0 || !statement
        throw Error("SQLite prepare failed: " rc)
    return statement
}

RuntimeIndexBindText(statement, index, value) {
    rc := DllCall("winsqlite3\sqlite3_bind_text16", "ptr", statement,
        "int", index, "wstr", value, "int", -1, "ptr", -1,
        "cdecl int")
    if rc != 0
        throw Error("SQLite text bind failed: " rc)
}

RuntimeIndexBindInt(statement, index, value) {
    rc := DllCall("winsqlite3\sqlite3_bind_int64", "ptr", statement,
        "int", index, "int64", value, "cdecl int")
    if rc != 0
        throw Error("SQLite integer bind failed: " rc)
}

RuntimeIndexStepDone(statement) {
    rc := DllCall("winsqlite3\sqlite3_step", "ptr", statement, "cdecl int")
    if rc != 101 ; SQLITE_DONE
        throw Error("SQLite step failed: " rc)
}

RuntimeIndexReset(statement) {
    DllCall("winsqlite3\sqlite3_reset", "ptr", statement, "cdecl int")
    DllCall("winsqlite3\sqlite3_clear_bindings", "ptr", statement, "cdecl int")
}

RuntimeIndexColumnText(statement, index) {
    valuePtr := DllCall("winsqlite3\sqlite3_column_text16",
        "ptr", statement, "int", index, "cdecl ptr")
    return valuePtr ? StrGet(valuePtr) : ""
}

RuntimeIndexSaveSnapshot(result) {
    global RuntimeIndexAvailable, RuntimeIndexDb
    global ActiveWorkspaceId, CurrentConfigFingerprint
    if !RuntimeIndexAvailable && !InitializeRuntimeIndex()
        return false
    workspaceId := ActiveWorkspaceId
    if workspaceId = ""
        return false
    statements := []
    try {
        RuntimeIndexExec("BEGIN IMMEDIATE;")
        workspace := RuntimeIndexPrepare("INSERT OR REPLACE INTO workspace_snapshot "
            . "(workspace_id,fingerprint,updated_at) VALUES(?,?,?);")
        statements.Push(workspace)
        RuntimeIndexBindText(workspace, 1, workspaceId)
        RuntimeIndexBindText(workspace, 2, CurrentConfigFingerprint)
        RuntimeIndexBindText(workspace, 3, A_Now)
        RuntimeIndexStepDone(workspace)

        for tableName in ["item_snapshot", "source_snapshot", "recent_snapshot"] {
            statement := RuntimeIndexPrepare("DELETE FROM " tableName
                . " WHERE workspace_id=?;")
            statements.Push(statement)
            RuntimeIndexBindText(statement, 1, workspaceId)
            RuntimeIndexStepDone(statement)
        }

        sourceStatement := RuntimeIndexPrepare("INSERT INTO source_snapshot "
            . "(workspace_id,source_index,name,path,state) VALUES(?,?,?,?,?);")
        itemStatement := RuntimeIndexPrepare("INSERT INTO item_snapshot "
            . "(workspace_id,source_index,item_index,path,name,modified,is_directory,time_kind) "
            . "VALUES(?,?,?,?,?,?,?,?);")
        recentStatement := RuntimeIndexPrepare("INSERT INTO recent_snapshot "
            . "(workspace_id,item_index,path,name,modified) VALUES(?,?,?,?,?);")
        statements.Push(sourceStatement)
        statements.Push(itemStatement)
        statements.Push(recentStatement)
        for sourceIndex, folder in result.Folders {
            RuntimeIndexBindText(sourceStatement, 1, workspaceId)
            RuntimeIndexBindInt(sourceStatement, 2, sourceIndex)
            RuntimeIndexBindText(sourceStatement, 3, folder.Name)
            RuntimeIndexBindText(sourceStatement, 4, folder.Path)
            RuntimeIndexBindText(sourceStatement, 5, folder.State)
            RuntimeIndexStepDone(sourceStatement)
            RuntimeIndexReset(sourceStatement)
            for itemIndex, item in folder.Files {
                RuntimeIndexBindText(itemStatement, 1, workspaceId)
                RuntimeIndexBindInt(itemStatement, 2, sourceIndex)
                RuntimeIndexBindInt(itemStatement, 3, itemIndex)
                RuntimeIndexBindText(itemStatement, 4, item.Path)
                RuntimeIndexBindText(itemStatement, 5, item.Name)
                RuntimeIndexBindText(itemStatement, 6, item.Modified)
                RuntimeIndexBindInt(itemStatement, 7, item.IsDirectory ? 1 : 0)
                RuntimeIndexBindText(itemStatement, 8, item.TimeKind)
                RuntimeIndexStepDone(itemStatement)
                RuntimeIndexReset(itemStatement)
            }
        }
        for itemIndex, item in result.Recent {
            RuntimeIndexBindText(recentStatement, 1, workspaceId)
            RuntimeIndexBindInt(recentStatement, 2, itemIndex)
            RuntimeIndexBindText(recentStatement, 3, item.Path)
            RuntimeIndexBindText(recentStatement, 4, item.Name)
            RuntimeIndexBindText(recentStatement, 5, item.Modified)
            RuntimeIndexStepDone(recentStatement)
            RuntimeIndexReset(recentStatement)
        }
        RuntimeIndexExec("COMMIT;")
        return true
    } catch {
        try RuntimeIndexExec("ROLLBACK;")
        RuntimeIndexAvailable := false
        SetTimer(RecoverRuntimeIndex, -10)
        return false
    } finally {
        for statement in statements
            if statement
                DllCall("winsqlite3\sqlite3_finalize", "ptr", statement,
                    "cdecl int")
    }
}

RuntimeIndexLoadSnapshot(workspaceId, fingerprint) {
    global RuntimeIndexAvailable
    if !RuntimeIndexAvailable && !InitializeRuntimeIndex()
        return 0
    statements := []
    try {
        workspace := RuntimeIndexPrepare("SELECT fingerprint FROM workspace_snapshot "
            . "WHERE workspace_id=?;")
        statements.Push(workspace)
        RuntimeIndexBindText(workspace, 1, workspaceId)
        rc := DllCall("winsqlite3\sqlite3_step", "ptr", workspace, "cdecl int")
        if rc != 100 || RuntimeIndexColumnText(workspace, 0) != fingerprint
            return 0
        result := {Version: 5, Generation: "index", Fingerprint: fingerprint,
            WorkspaceId: workspaceId, Kind: "Snapshot", SourceIndex: 0,
            Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
        sources := RuntimeIndexPrepare("SELECT source_index,name,path,state "
            . "FROM source_snapshot WHERE workspace_id=? ORDER BY source_index;")
        statements.Push(sources)
        RuntimeIndexBindText(sources, 1, workspaceId)
        while DllCall("winsqlite3\sqlite3_step", "ptr", sources,
            "cdecl int") = 100 {
            sourceIndex := DllCall("winsqlite3\sqlite3_column_int64",
                "ptr", sources, "int", 0, "cdecl int64")
            folder := {Name: RuntimeIndexColumnText(sources, 1),
                Path: RuntimeIndexColumnText(sources, 2),
                State: RuntimeIndexColumnText(sources, 3), Files: []}
            items := RuntimeIndexPrepare("SELECT path,name,modified,is_directory,time_kind "
                . "FROM item_snapshot WHERE workspace_id=? AND source_index=? "
                . "ORDER BY item_index;")
            RuntimeIndexBindText(items, 1, workspaceId)
            RuntimeIndexBindInt(items, 2, sourceIndex)
            try {
                while DllCall("winsqlite3\sqlite3_step", "ptr", items,
                    "cdecl int") = 100 {
                    folder.Files.Push({Path: RuntimeIndexColumnText(items, 0),
                        Name: RuntimeIndexColumnText(items, 1),
                        Modified: RuntimeIndexColumnText(items, 2),
                        IsDirectory: DllCall("winsqlite3\sqlite3_column_int64",
                            "ptr", items, "int", 3, "cdecl int64") != 0,
                        TimeKind: RuntimeIndexColumnText(items, 4)})
                }
            } finally {
                DllCall("winsqlite3\sqlite3_finalize", "ptr", items,
                    "cdecl int")
            }
            while result.Folders.Length < sourceIndex - 1
                result.Folders.Push({Name: "", Path: "", State: "Pending", Files: []})
            result.Folders.Push(folder)
        }
        recent := RuntimeIndexPrepare("SELECT path,name,modified FROM recent_snapshot "
            . "WHERE workspace_id=? ORDER BY item_index;")
        statements.Push(recent)
        RuntimeIndexBindText(recent, 1, workspaceId)
        while DllCall("winsqlite3\sqlite3_step", "ptr", recent,
            "cdecl int") = 100 {
            result.Recent.Push({Path: RuntimeIndexColumnText(recent, 0),
                Name: RuntimeIndexColumnText(recent, 1),
                Modified: RuntimeIndexColumnText(recent, 2)})
        }
        return result
    } catch {
        RuntimeIndexAvailable := false
        SetTimer(RecoverRuntimeIndex, -10)
        return 0
    } finally {
        for statement in statements
            if statement
                DllCall("winsqlite3\sqlite3_finalize", "ptr", statement,
                    "cdecl int")
    }
}

RecoverRuntimeIndex() {
    global RuntimeIndexPath
    path := RuntimeIndexPath
    if !CloseRuntimeIndex()
        return false
    if path = "" || !FileExist(path)
        return InitializeRuntimeIndex(false)
    quarantine := path ".corrupt-" A_Now
    try FileMove(path, quarantine, 1)
    if FileExist(path "-wal")
        try FileMove(path "-wal", quarantine "-wal", 1)
    if FileExist(path "-shm")
        try FileMove(path "-shm", quarantine "-shm", 1)
    return InitializeRuntimeIndex(false)
}

CloseRuntimeIndex() {
    global RuntimeIndexDb, RuntimeIndexAvailable
    ; Take ownership before entering native code.  This prevents timer/on-exit
    ; re-entry from observing and closing the same handle twice.
    db := RuntimeIndexDb
    RuntimeIndexDb := 0
    RuntimeIndexAvailable := false
    if db {
        try DllCall("winsqlite3\sqlite3_exec", "ptr", db,
            "astr", "PRAGMA wal_checkpoint(PASSIVE);", "ptr", 0,
            "ptr", 0, "ptr", 0, "cdecl int")
        try {
            rc := DllCall("winsqlite3\sqlite3_close_v2", "ptr", db,
                "cdecl int")
            return rc = 0
        } catch {
            return false
        }
    }
    return true
}

ShutdownRuntimeIndex() {
    global RuntimeIndexModule
    CloseRuntimeIndex()
    module := RuntimeIndexModule
    RuntimeIndexModule := 0
    if module
        try DllCall("kernel32\FreeLibrary", "ptr", module)
}
