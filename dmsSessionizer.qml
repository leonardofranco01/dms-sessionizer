import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

QtObject {
    id: root

    property var pluginService: null
    property string trigger: "tm"

    signal itemsChanged

    // Settings
    property string projectsDir: ""
    property string terminal: "st"
    property string customTerminal: ""
    property string terminalBehavior: "newWindow"
    property bool includeHidden: false
    property bool includeSymlinks: false
    property int maxResults: 50
    property bool mruSort: false
    property string killPrefix: "!"

    // Multiplexer backend from DMS System > Multiplexers (SettingsData.muxType)
    readonly property string muxType: {
        if (typeof SettingsData !== "undefined" && SettingsData.muxType)
            return SettingsData.muxType;
        return "tmux";
    }
    readonly property bool isZellij: muxType === "zellij"
    readonly property string muxDisplayName: isZellij ? "Zellij" : "Tmux"

    // Cached data
    property var cachedProjects: []
    property var cachedProjectNames: ({})
    property var cachedRunningSessions: []
    property var cachedRunningSessionsLower: []
    property var mruData: ({})

    // Raw data from process
    property string projectsRawData: ""
    property string sessionsRawData: ""
    property var pendingDirs: []
    property int currentDirIndex: 0
    property bool settingsReady: false

    // Home directory
    property string homeDir: Quickshell.env("HOME") || "/home"

    // Number of projects directories (cached via binding)
    property int projectsDirsCount: getProjectsDirs().length

    // Terminal configurations
    readonly property var terminalConfigs: ({
        "st": { executable: "st", execFlag: "-e" },
        "alacritty": { executable: "alacritty", execFlag: "-e" },
        "kitty": { executable: "kitty", execFlag: "-e" },
        "wezterm": { executable: "wezterm", execFlag: "start --" },
        "foot": { executable: "foot", execFlag: "-e" },
        "konsole": { executable: "konsole", execFlag: "-e" },
        "gnome-terminal": { executable: "gnome-terminal", execFlag: "--" },
        "xterm": { executable: "xterm", execFlag: "-e" },
        "ghostty": { executable: "ghostty", execFlag: "-e" },
        "Custom": { executable: "", execFlag: "-e" }
    })

    property var initTimer: Timer {
        interval: 0
        repeat: false
        running: false
        onTriggered: {
            root.refreshCache();
        }
    }

    // Debounce session re-list while user is in kill mode
    property var killModeRefreshTimer: Timer {
        interval: 150
        repeat: false
        onTriggered: root.refreshRunningSessions()
    }

    property var listDirProcess: Process {
        command: ["ls", "-1d"]
        running: false

        stdout: SplitParser {
            splitMarker: ""
            onRead: function(data) {
                root.projectsRawData += data;
            }
        }

        onExited: function(exitCode) {
            if (exitCode !== 0) {
                console.warn("DMS Sessionizer: Failed to list directory:", root.pendingDirs[root.currentDirIndex].path, "exit code:", exitCode);
            }
            root.currentDirIndex++;
            root.scanNextDirectory();
        }
    }

    property var listSessionsProcess: Process {
        command: ["tmux", "list-sessions", "-F", "#S"]
        running: false

        stdout: SplitParser {
            splitMarker: ""
            onRead: function(data) {
                root.sessionsRawData += data;
            }
        }

        onExited: function(exitCode) {
            // Non-zero when no server / no sessions — treat as empty list
            var out = root.isZellij
                ? root.parseZellijSessionNames(root.sessionsRawData)
                : root.parseTmuxSessionNames(root.sessionsRawData);
            out.sort();
            root.cachedRunningSessions = out;
            var outLower = [];
            for (var j = 0; j < out.length; j++) outLower.push(out[j].toLowerCase());
            root.cachedRunningSessionsLower = outLower;
            root.itemsChanged();
        }
    }

    property var killSessionProcess: Process {
        property string targetName: ""

        command: ["tmux", "kill-session", "-t", ""]
        running: false

        onExited: function(exitCode) {
            if (exitCode === 0) {
                if (ToastService) ToastService.showInfo("Killed " + root.muxDisplayName.toLowerCase() + " session: " + targetName);
            } else {
                console.warn("DMS Sessionizer: Failed to kill session:", targetName, "exit:", exitCode);
            }
            root.refreshRunningSessions();
        }
    }

    property var muxCheckProcess: Process {
        property string sessionName: ""
        property string projectPath: ""

        command: ["tmux", "has-session", "-t", ""]
        running: false

        onExited: function(exitCode) {
            var sessionExists = exitCode === 0;

            if (root.terminalBehavior === "reuseSession" && !root.isZellij) {
                root.handleReuseSession(sessionName, projectPath, sessionExists);
            } else {
                root.launchTerminalWithMux(sessionName, projectPath, sessionExists);
            }
        }
    }

    property var createDetachedSessionProcess: Process {
        property string sessionName: ""
        property string projectPath: ""

        command: ["tmux", "new-session", "-d", "-s", "", "-c", ""]
        running: false

        onExited: function(exitCode) {
            if (exitCode === 0) {
                root.switchToSession(sessionName, projectPath);
            } else {
                console.warn("DMS Sessionizer: Failed to create detached session, falling back to new terminal");
                root.launchTerminalWithMux(sessionName, projectPath, false);
            }
        }
    }

    property var switchClientProcess: Process {
        property string sessionName: ""
        property string projectPath: ""

        command: ["tmux", "switch-client", "-t", ""]
        running: false

        onExited: function(exitCode) {
            if (exitCode === 0) {
                if (ToastService) ToastService.showInfo("Switched to session: " + sessionName);
            } else {
                console.log("DMS Sessionizer: No existing tmux client, opening new terminal");
                root.launchTerminalWithMux(sessionName, projectPath, true);
            }
        }
    }

    property var killTerminalProcess: Process {
        command: ["pkill", "-x", ""]
        running: false
    }

    // Must be a property — QtObject has no default child property
    property var muxTypeConnections: Connections {
        target: typeof SettingsData !== "undefined" ? SettingsData : null
        function onMuxTypeChanged() {
            root.refreshRunningSessions();
            root.itemsChanged();
        }
    }

    Component.onCompleted: {
        if (pluginService) {
            trigger = pluginService.loadPluginData("dmsSessionizer", "trigger", "tm");
            projectsDir = pluginService.loadPluginData("dmsSessionizer", "projectsDir", "");
            terminal = pluginService.loadPluginData("dmsSessionizer", "terminal", "st");
            customTerminal = pluginService.loadPluginData("dmsSessionizer", "customTerminal", "");
            terminalBehavior = pluginService.loadPluginData("dmsSessionizer", "terminalBehavior", "newWindow");
            includeHidden = pluginService.loadPluginData("dmsSessionizer", "includeHidden", false);
            includeSymlinks = pluginService.loadPluginData("dmsSessionizer", "includeSymlinks", false);
            var maxResultsStr = pluginService.loadPluginData("dmsSessionizer", "maxResults", "50");
            maxResults = parseInt(maxResultsStr, 10) || 50;
            mruSort = pluginService.loadPluginData("dmsSessionizer", "mruSort", false);
            killPrefix = normalizeKillPrefix(pluginService.loadPluginData("dmsSessionizer", "killPrefix", "!"));
            var mruRaw = pluginService.loadPluginData("dmsSessionizer", "mruData", "{}");
            try {
                mruData = JSON.parse(mruRaw) || {};
            } catch (e) {
                mruData = {};
            }
        }
        settingsReady = true;
        initTimer.start();
    }

    function normalizeKillPrefix(value) {
        var p = (value === undefined || value === null) ? "!" : String(value);
        // Allow a short prefix; empty falls back to "!"
        p = p.trim();
        if (p.length === 0) return "!";
        // Avoid whitespace-only / multi-line junk from the settings field
        p = p.split(/\s+/)[0];
        return p.length > 0 ? p : "!";
    }

    function parseTmuxSessionNames(data) {
        var lines = (data || "").split("\n");
        var out = [];
        for (var i = 0; i < lines.length; i++) {
            var s = lines[i].trim();
            if (s) out.push(s);
        }
        return out;
    }

    function parseZellijSessionNames(data) {
        var lines = (data || "").split("\n");
        var out = [];
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line) continue;
            // Skip exited sessions for attach/kill listing
            if (line.indexOf("(EXITED") !== -1) continue;
            var bracketIdx = line.indexOf(" [");
            var name = (bracketIdx > 0 ? line.substring(0, bracketIdx) : line).trim();
            if (name) out.push(name);
        }
        return out;
    }

    function listSessionsCommand() {
        if (isZellij)
            return ["zellij", "list-sessions", "--no-formatting"];
        return ["tmux", "list-sessions", "-F", "#S"];
    }

    function killSessionCommand(name) {
        if (isZellij)
            return ["zellij", "kill-session", name];
        return ["tmux", "kill-session", "-t", name];
    }

    function hasSessionCommand(name) {
        if (isZellij) {
            // Exit 0 if an active (non-EXITED) session with this exact name exists
            return [
                "sh", "-c",
                "zellij list-sessions --no-formatting 2>/dev/null | awk -v n=\"$1\" '" +
                "index($0, \"(EXITED\") { next } " +
                "{ name=$0; sub(/ \\[.*$/, \"\", name); gsub(/^ +| +$/, \"\", name); if (name == n) exit 0 } " +
                "END { exit 1 }'",
                "_",
                name
            ];
        }
        return ["tmux", "has-session", "-t", name];
    }

    function muxShellCommand(sessionName, projectPath, sessionExists) {
        if (isZellij) {
            if (sessionExists)
                return "zellij attach " + escapeShellArg(sessionName);
            // Create in the project directory (zellij has no reliable -c equivalent)
            return "cd " + escapeShellArg(projectPath) + " && zellij -s " + escapeShellArg(sessionName);
        }
        if (sessionExists)
            return "tmux attach-session -t " + escapeShellArg(sessionName);
        return "tmux new-session -As " + escapeShellArg(sessionName) + " -c " + escapeShellArg(projectPath);
    }

    function getProjectsDirs() {
        // Trailing "/" → scan children; no trailing "/" → treat path as a single project.
        var dirs = [];
        var input = projectsDir && projectsDir.length > 0 ? projectsDir : "~/projects/";
        var parts = input.split(/[,\n]+/);

        for (var i = 0; i < parts.length; i++) {
            var dir = parts[i].trim();
            if (!dir) continue;

            var scanChildren = dir.charAt(dir.length - 1) === "/";
            var expanded = "";

            if (dir.indexOf("/") === 0) {
                expanded = dir;
            } else if (dir.indexOf("~") === 0) {
                expanded = homeDir + dir.substring(1);
            } else {
                expanded = homeDir + "/" + dir;
            }

            while (expanded.length > 1 && expanded.charAt(expanded.length - 1) === "/")
                expanded = expanded.substring(0, expanded.length - 1);

            if (expanded)
                dirs.push({ path: expanded, scanChildren: scanChildren });
        }

        return dirs.length > 0
            ? dirs
            : [{ path: homeDir + "/projects", scanChildren: true }];
    }

    function persist(key, value) {
        if (pluginService) pluginService.savePluginData("dmsSessionizer", key, value);
    }

    function getTerminalExecutable() {
        if (terminal === "Custom" && customTerminal && customTerminal.length > 0) {
            return customTerminal;
        }
        var config = terminalConfigs[terminal] || terminalConfigs["st"];
        return config.executable;
    }

    function getTerminalExecFlag() {
        var config = terminalConfigs[terminal] || terminalConfigs["st"];
        return config.execFlag;
    }

    function refreshCache() {
        projectsRawData = "";
        cachedProjects = [];
        pendingDirs = getProjectsDirs();
        currentDirIndex = 0;

        refreshRunningSessions();

        if (pendingDirs.length > 0) {
            scanNextDirectory();
        } else {
            itemsChanged();
        }
    }

    function refreshRunningSessions() {
        // Keep cachedRunningSessions until list exits so kill mode
        // does not briefly see an empty list. Skip overlapping restarts.
        if (listSessionsProcess.running)
            return;
        sessionsRawData = "";
        listSessionsProcess.command = listSessionsCommand();
        listSessionsProcess.running = true;
    }

    function scanNextDirectory() {
        if (currentDirIndex >= pendingDirs.length) {
            parseProjectsData();
            return;
        }

        var entry = pendingDirs[currentDirIndex];
        if (!entry.scanChildren) {
            // Single project directory — include the path itself
            projectsRawData += entry.path + "\n";
            currentDirIndex++;
            scanNextDirectory();
            return;
        }

        var cmd = ["find"];
        if (includeSymlinks) cmd.push("-L");
        cmd.push(entry.path, "-maxdepth", "1", "-mindepth", "1", "-type", "d");
        if (!includeHidden) cmd.push("-not", "-name", ".*");
        listDirProcess.command = cmd;
        listDirProcess.running = true;
    }

    function parseProjectsData() {
        var data = projectsRawData;
        if (!data || data.length === 0) {
            cachedProjects = [];
            cachedProjectNames = ({});
            itemsChanged();
            return;
        }

        try {
            var lines = data.split("\n");
            var result = [];

            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim();
                if (!line) continue;

                var name = getBasename(line);
                if (!name) continue;

                result.push({
                    name: name,
                    path: line,
                    lname: name.toLowerCase(),
                    lpath: line.toLowerCase()
                });
            }

            result.sort(function(a, b) {
                if (mruSort) {
                    var ta = mruData[a.path] || 0;
                    var tb = mruData[b.path] || 0;
                    if (tb !== ta) return tb - ta;
                }
                return a.lname.localeCompare(b.lname);
            });

            cachedProjects = result;
            var nameSet = {};
            for (var n = 0; n < result.length; n++) nameSet[result[n].name] = true;
            cachedProjectNames = nameSet;
            itemsChanged();
        } catch (e) {
            console.warn("DMS Sessionizer: Error parsing projects data:", e);
            cachedProjects = [];
            cachedProjectNames = ({});
            itemsChanged();
        }
    }

    function recordMru(path) {
        if (!path || !pluginService) return;
        var copy = {};
        for (var k in mruData) copy[k] = mruData[k];
        copy[path] = Date.now();

        var keys = Object.keys(copy);
        if (keys.length > 100) {
            keys.sort(function(a, b) { return copy[b] - copy[a]; });
            var trimmed = {};
            for (var i = 0; i < 100; i++) trimmed[keys[i]] = copy[keys[i]];
            copy = trimmed;
        }

        mruData = copy;
        persist("mruData", JSON.stringify(copy));
    }

    function getBasename(path) {
        if (!path) return "";
        var end = path.length;
        if (path.charAt(end - 1) === "/") end--;
        var slash = path.lastIndexOf("/", end - 1);
        return path.substring(slash + 1, end);
    }

    function shortenPath(path, maxLength) {
        maxLength = maxLength || 50;
        if (!path || path.length <= maxLength) return path;

        var parts = path.split("/");
        if (parts.length <= 1) return path;

        var result = "";
        for (var i = parts.length - 1; i >= 0; i--) {
            var part = parts[i];
            if (!part) continue;

            var candidate = ".../" + part + result;
            if (candidate.length <= maxLength) {
                result = "/" + part + result;
            } else {
                break;
            }
        }

        return "..." + result;
    }

    function makeRefreshItem() {
        return {
            name: "↻ Refresh Projects",
            comment: "Reload projects from " + projectsDirsCount + " director" + (projectsDirsCount === 1 ? "y" : "ies"),
            action: "refresh",
            icon: "material:refresh",
            categories: ["DMS Sessionizer"]
        };
    }

    function matchesFilters(loweredItem, filters) {
        if (filters.length === 0) return true;
        for (var i = 0; i < filters.length; i++) {
            if (loweredItem.indexOf(filters[i]) === -1) return false;
        }
        return true;
    }

    function effectiveKillPrefix() {
        return normalizeKillPrefix(killPrefix);
    }

    function buildKillItems(query, limit) {
        var killFilters = query.split(/\s+/).filter(function(t) { return t.length > 0; });
        var out = [];
        for (var i = 0; i < cachedRunningSessions.length && out.length < limit; i++) {
            if (matchesFilters(cachedRunningSessionsLower[i], killFilters)) {
                var ks = cachedRunningSessions[i];
                out.push({
                    name: "Kill session: " + ks,
                    comment: "Stop " + muxDisplayName.toLowerCase() + " session",
                    action: "kill:" + ks,
                    icon: "material:close",
                    categories: ["DMS Sessionizer"]
                });
            }
        }
        return out;
    }

    function buildProjectItems(filters, limit) {
        var out = [];
        for (var i = 0; i < cachedProjects.length && out.length < limit; i++) {
            var p = cachedProjects[i];
            if (matchesFilters(p.lname, filters) || matchesFilters(p.lpath, filters)) {
                out.push({
                    name: p.name,
                    comment: shortenPath(p.path),
                    action: "session:" + p.path,
                    icon: "material:terminal",
                    categories: ["DMS Sessionizer"]
                });
            }
        }
        return out;
    }

    function buildRunningSessionItems(filters, limit) {
        var out = [];
        for (var i = 0; i < cachedRunningSessions.length && out.length < limit; i++) {
            var s = cachedRunningSessions[i];
            if (cachedProjectNames[s]) continue;
            if (matchesFilters(cachedRunningSessionsLower[i], filters)) {
                out.push({
                    name: s,
                    comment: "Running " + muxDisplayName.toLowerCase() + " session",
                    action: "attach:" + s,
                    icon: "material:play_arrow",
                    categories: ["DMS Sessionizer"]
                });
            }
        }
        return out;
    }

    function getItems(query) {
        var trimmed = query ? query.trim() : "";
        var prefix = effectiveKillPrefix();

        if (prefix.length > 0 && trimmed.indexOf(prefix) === 0) {
            var rawKillQuery = trimmed.substring(prefix.length).trim();
            var killItems = buildKillItems(rawKillQuery.toLowerCase(), maxResults);

            // If cache is stale/empty, still offer killing the typed name directly
            if (rawKillQuery.length > 0 && killItems.length === 0) {
                killItems.push({
                    name: "Kill session: " + rawKillQuery,
                    comment: "Stop " + muxDisplayName.toLowerCase() + " session",
                    action: "kill:" + rawKillQuery,
                    icon: "material:close",
                    categories: ["DMS Sessionizer"]
                });
            }

            // Refresh session list in background while showing current/fallback items
            killModeRefreshTimer.restart();

            killItems.push(makeRefreshItem());
            return killItems;
        }

        var filters = trimmed.toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0; });

        var projectItems = buildProjectItems(filters, maxResults);
        var sessionItems = buildRunningSessionItems(filters, maxResults - projectItems.length);

        var items = projectItems.concat(sessionItems);
        if (items.length === 0 && trimmed.length > 0) {
            items.push({
                name: "Create new session: " + trimmed,
                comment: "Adhoc " + muxDisplayName.toLowerCase() + " session in " + homeDir,
                action: "newSession:" + trimmed,
                icon: "material:add",
                categories: ["DMS Sessionizer"]
            });
        }
        items.push(makeRefreshItem());
        return items;
    }

    function executeItem(item) {
        if (!item || !item.action) return;

        if (item.action === "refresh") {
            refreshCache();
            if (ToastService) ToastService.showInfo("Refreshing projects list...");
            return;
        }

        var colonIndex = item.action.indexOf(":");
        var actionType = colonIndex > 0 ? item.action.substring(0, colonIndex) : item.action;
        var actionData = colonIndex > 0 ? item.action.substring(colonIndex + 1) : "";

        if (actionType === "session") {
            var projectPath = actionData;
            recordMru(projectPath);
            dispatchMuxLaunch(getBasename(projectPath), projectPath);
        } else if (actionType === "newSession" || actionType === "attach") {
            dispatchMuxLaunch(actionData, homeDir);
        } else if (actionType === "kill") {
            killSessionProcess.targetName = actionData;
            killSessionProcess.command = killSessionCommand(actionData);
            killSessionProcess.running = true;
        }
    }

    function dispatchMuxLaunch(rawName, workdir) {
        var sessionName = rawName;
        if (sessionName.indexOf(".") === 0 && sessionName.length > 1) {
            sessionName = sessionName.substring(1);
        }

        if (terminalBehavior === "killExisting") {
            var termExe = getTerminalExecutable();
            killTerminalProcess.command = ["pkill", "-x", termExe];
            killTerminalProcess.running = true;

            Qt.callLater(function() {
                checkAndLaunchMux(sessionName, workdir);
            });
        } else {
            checkAndLaunchMux(sessionName, workdir);
        }
    }

    function checkAndLaunchMux(sessionName, projectPath) {
        muxCheckProcess.sessionName = sessionName;
        muxCheckProcess.projectPath = projectPath;
        muxCheckProcess.command = hasSessionCommand(sessionName);
        if (muxCheckProcess.running)
            muxCheckProcess.running = false;
        Qt.callLater(function() {
            muxCheckProcess.running = true;
        });
    }

    function launchTerminalWithMux(sessionName, projectPath, sessionExists) {
        var termExe = getTerminalExecutable();
        var execFlag = getTerminalExecFlag();
        var muxCmd = muxShellCommand(sessionName, projectPath, sessionExists);

        var cmd = [];
        cmd.push(termExe);

        var flagParts = execFlag.split(" ");
        for (var i = 0; i < flagParts.length; i++) {
            if (flagParts[i]) {
                cmd.push(flagParts[i]);
            }
        }

        cmd.push("sh");
        cmd.push("-c");
        cmd.push(muxCmd);

        Quickshell.execDetached(cmd);

        // Session create/attach changes mux state — keep kill-mode cache fresh
        Qt.callLater(function() {
            root.refreshRunningSessions();
        });

        var actionMsg = sessionExists ? "Attaching to" : "Creating";
        if (ToastService) ToastService.showInfo(actionMsg + " " + muxDisplayName.toLowerCase() + " session: " + sessionName);
    }

    function escapeShellArg(arg) {
        return "'" + arg.replace(/'/g, "'\\''") + "'";
    }

    function handleReuseSession(sessionName, projectPath, sessionExists) {
        // reuseSession is tmux-only (switch-client); zellij falls back in muxCheckProcess
        if (sessionExists) {
            switchToSession(sessionName, projectPath);
        } else {
            createDetachedSessionProcess.sessionName = sessionName;
            createDetachedSessionProcess.projectPath = projectPath;
            createDetachedSessionProcess.command = ["tmux", "new-session", "-d", "-s", sessionName, "-c", projectPath];
            createDetachedSessionProcess.running = true;
        }
    }

    function switchToSession(sessionName, projectPath) {
        switchClientProcess.sessionName = sessionName;
        switchClientProcess.projectPath = projectPath;
        switchClientProcess.command = ["tmux", "switch-client", "-t", sessionName];
        switchClientProcess.running = true;
    }

    onTriggerChanged: {
        persist("trigger", trigger);
        itemsChanged();
    }

    onKillPrefixChanged: {
        persist("killPrefix", normalizeKillPrefix(killPrefix));
        itemsChanged();
    }

    onProjectsDirChanged: {
        persist("projectsDir", projectsDir);
        if (settingsReady)
            refreshCache();
    }

    onTerminalChanged: {
        persist("terminal", terminal);
    }

    onMruSortChanged: {
        persist("mruSort", mruSort);
        parseProjectsData();
    }
}
