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
    property int maxResults: 50

    // Cached data
    property var cachedProjects: []

    // Raw data from process
    property string projectsRawData: ""
    property var pendingDirs: []
    property int currentDirIndex: 0

    // Home directory
    property string homeDir: Quickshell.env("HOME") || "/home"

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
            var maxResultsStr = pluginService.loadPluginData("dmsSessionizer", "maxResults", "50");
            maxResults = parseInt(maxResultsStr, 10) || 50;
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

    function getProjectsDir() {
        var dirs = getProjectsDirs();
        return dirs[0] || homeDir + "/projects";
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
        
        if (pendingDirs.length > 0) {
            scanNextDirectory();
        } else {
            itemsChanged();
        }
    }

    function scanNextDirectory() {
        if (currentDirIndex >= pendingDirs.length) {
            parseProjectsData();
            return;
        }
        
        var dir = pendingDirs[currentDirIndex];
        var cmd = ["find", dir, "-maxdepth", "1", "-mindepth", "1", "-type", "d"];
        if (!includeHidden) {
            cmd.push("-not");
            cmd.push("-name");
            cmd.push(".*");
        }
        listDirProcess.command = cmd;
        listDirProcess.running = true;
    }

    function parseProjectsData() {
        var data = projectsRawData;
        if (!data || data.length === 0) {
            cachedProjects = [];
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
                    path: line
                });
            }

            result.sort(function(a, b) {
                return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
            });

            cachedProjects = result;
            itemsChanged();
        } catch (e) {
            console.warn("DMS Sessionizer: Error parsing projects data:", e);
            cachedProjects = [];
            itemsChanged();
        }
    }

    function getBasename(path) {
        if (!path) return "";
        // Remove trailing slash if present
        if (path.charAt(path.length - 1) === "/") {
            path = path.substring(0, path.length - 1);
        }
        var parts = path.split("/");
        return parts[parts.length - 1] || path;
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

    function matchesFilters(item, filters) {
        if (filters.length === 0) return true;

        var lowerItem = item.toLowerCase();
        for (var i = 0; i < filters.length; i++) {
            if (lowerItem.indexOf(filters[i]) === -1) {
                return false;
            }
        }
        return true;
    }

    function getItems(query) {
        var items = [];
        var trimmed = query ? query.trim() : "";
        var lowerQuery = trimmed.toLowerCase();

        // Parse query for filters
        var filters = lowerQuery.split(/\s+/).filter(function(t) { return t.length > 0; });

        var count = 0;

        // Add projects
        for (var pi = 0; pi < cachedProjects.length && count < maxResults; pi++) {
            var project = cachedProjects[pi];
            var pname = project.name || "";
            var ppath = project.path || "";

            if (matchesFilters(pname, filters) || matchesFilters(ppath, filters)) {
                items.push({
                    name: pname,
                    comment: shortenPath(ppath),
                    action: "session:" + ppath,
                    icon: "material:terminal",
                    categories: ["DMS Sessionizer"]
                });
                count++;
            }
        }

        items.push({
            name: "↻ Refresh Projects",
            comment: "Reload projects from " + getProjectsDirs().length + " director" + (getProjectsDirs().length === 1 ? "y" : "ies"),
            action: "refresh",
            icon: "material:refresh",
            categories: ["DMS Sessionizer"]
        });

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
            var sessionName = getBasename(projectPath);

            if (terminalBehavior === "killExisting") {
                var termExe = getTerminalExecutable();
                killTerminalProcess.command = ["pkill", "-x", termExe];
                killTerminalProcess.running = true;
                
                Qt.callLater(function() {
                    checkAndLaunchTmux(sessionName, projectPath);
                });
            } else {
                checkAndLaunchTmux(sessionName, projectPath);
            }
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
        if (!pluginService) return;
        pluginService.savePluginData("dmsSessionizer", "trigger", trigger);
        itemsChanged();
    }

    onProjectsDirChanged: {
        if (!pluginService) return;
        pluginService.savePluginData("dmsSessionizer", "projectsDir", projectsDir);
        refreshCache();
    }

    onTerminalChanged: {
        if (!pluginService) return;
        pluginService.savePluginData("dmsSessionizer", "terminal", terminal);
    }
}
