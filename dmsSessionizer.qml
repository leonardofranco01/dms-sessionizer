import QtQuick
import Quickshell
import Quickshell.Io
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
        interval: 100
        repeat: false
        running: true
        onTriggered: {
            root.refreshCache();
        }
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
                console.warn("DMS Sessionizer: Failed to list directory:", root.pendingDirs[root.currentDirIndex], "exit code:", exitCode);
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
            // exitCode != 0 when no tmux server running — treat as empty list
            var lines = root.sessionsRawData.split("\n");
            var out = [];
            for (var i = 0; i < lines.length; i++) {
                var s = lines[i].trim();
                if (s) out.push(s);
            }
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
                if (ToastService) ToastService.showInfo("Killed tmux session: " + targetName);
            } else {
                console.warn("DMS Sessionizer: Failed to kill session:", targetName, "exit:", exitCode);
            }
            root.refreshRunningSessions();
        }
    }

    property var tmuxCheckProcess: Process {
        property string sessionName: ""
        property string projectPath: ""
        
        command: ["tmux", "has-session", "-t", ""]
        running: false

        onExited: function(exitCode) {
            var sessionExists = exitCode === 0;

            if (root.terminalBehavior === "reuseSession") {
                root.handleReuseSession(sessionName, projectPath, sessionExists);
            } else {
                root.launchTerminalWithTmux(sessionName, projectPath, sessionExists);
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
                root.launchTerminalWithTmux(sessionName, projectPath, false);
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
                root.launchTerminalWithTmux(sessionName, projectPath, true);
            }
        }
    }

    property var killTerminalProcess: Process {
        command: ["pkill", "-x", ""]
        running: false
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
            var mruRaw = pluginService.loadPluginData("dmsSessionizer", "mruData", "{}");
            try {
                mruData = JSON.parse(mruRaw) || {};
            } catch (e) {
                mruData = {};
            }
        }
    }

    function getProjectsDirs() {
        var dirs = [];
        var input = projectsDir && projectsDir.length > 0 ? projectsDir : "~/projects";
        var parts = input.split(/[,\n]+/);
        
        for (var i = 0; i < parts.length; i++) {
            var dir = parts[i].trim();
            if (!dir) continue;
            
            if (dir.indexOf("/") === 0) {
                dirs.push(dir);
            } else if (dir.indexOf("~") === 0) {
                dirs.push(homeDir + dir.substring(1));
            } else {
                dirs.push(homeDir + "/" + dir);
            }
        }
        
        return dirs.length > 0 ? dirs : [homeDir + "/projects"];
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
        sessionsRawData = "";
        cachedRunningSessions = [];
        cachedRunningSessionsLower = [];
        listSessionsProcess.running = true;
    }

    function scanNextDirectory() {
        if (currentDirIndex >= pendingDirs.length) {
            parseProjectsData();
            return;
        }
        
        var dir = pendingDirs[currentDirIndex];
        var cmd = ["find"];
        if (includeSymlinks) cmd.push("-L");
        cmd.push(dir, "-maxdepth", "1", "-mindepth", "1", "-type", "d");
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

    function buildKillItems(query, limit) {
        var killFilters = query.split(/\s+/).filter(function(t) { return t.length > 0; });
        var out = [];
        for (var i = 0; i < cachedRunningSessions.length && out.length < limit; i++) {
            if (matchesFilters(cachedRunningSessionsLower[i], killFilters)) {
                var ks = cachedRunningSessions[i];
                out.push({
                    name: "Kill session: " + ks,
                    comment: "Stop tmux session",
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
                    comment: "Running tmux session",
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

        if (trimmed.indexOf("!") === 0) {
            var killItems = buildKillItems(trimmed.substring(1).trim().toLowerCase(), maxResults);
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
                comment: "Adhoc tmux session in " + homeDir,
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
            dispatchTmuxLaunch(getBasename(projectPath), projectPath);
        } else if (actionType === "newSession" || actionType === "attach") {
            dispatchTmuxLaunch(actionData, homeDir);
        } else if (actionType === "kill") {
            killSessionProcess.targetName = actionData;
            killSessionProcess.command = ["tmux", "kill-session", "-t", actionData];
            killSessionProcess.running = true;
        }
    }

    function dispatchTmuxLaunch(rawName, workdir) {
        var sessionName = rawName;
        if (sessionName.indexOf(".") === 0 && sessionName.length > 1) {
            sessionName = sessionName.substring(1);
        }

        if (terminalBehavior === "killExisting") {
            var termExe = getTerminalExecutable();
            killTerminalProcess.command = ["pkill", "-x", termExe];
            killTerminalProcess.running = true;

            Qt.callLater(function() {
                checkAndLaunchTmux(sessionName, workdir);
            });
        } else {
            checkAndLaunchTmux(sessionName, workdir);
        }
    }

    function checkAndLaunchTmux(sessionName, projectPath) {
        tmuxCheckProcess.sessionName = sessionName;
        tmuxCheckProcess.projectPath = projectPath;
        tmuxCheckProcess.command = ["tmux", "has-session", "-t", sessionName];
        tmuxCheckProcess.running = true;
    }

    function launchTerminalWithTmux(sessionName, projectPath, sessionExists) {
        var termExe = getTerminalExecutable();
        var execFlag = getTerminalExecFlag();

        var tmuxCmd;
        if (sessionExists) {
            tmuxCmd = "tmux attach-session -t " + escapeShellArg(sessionName);
        } else {
            tmuxCmd = "tmux new-session -As " + escapeShellArg(sessionName) + " -c " + escapeShellArg(projectPath);
        }

        var cmd = [];
        cmd.push(termExe);
        
        // Handle exec flag
        var flagParts = execFlag.split(" ");
        for (var i = 0; i < flagParts.length; i++) {
            if (flagParts[i]) {
                cmd.push(flagParts[i]);
            }
        }
        
        // Add sh -c to properly handle the tmux command
        cmd.push("sh");
        cmd.push("-c");
        cmd.push(tmuxCmd);

        Quickshell.execDetached(cmd);
        
        var actionMsg = sessionExists ? "Attaching to" : "Creating";
        if (ToastService) ToastService.showInfo(actionMsg + " tmux session: " + sessionName);
    }

    function escapeShellArg(arg) {
        return "'" + arg.replace(/'/g, "'\\''") + "'";
    }

    function handleReuseSession(sessionName, projectPath, sessionExists) {
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

    onProjectsDirChanged: {
        persist("projectsDir", projectsDir);
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
