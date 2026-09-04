import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "dmsSessionizer"

    StyledText {
        width: parent.width
        text: "DMS Sessionizer"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Quickly open project directories in a terminal with dedicated multiplexer sessions (tmux or Zellij, from DMS System → Multiplexers). Select a project and it will launch your terminal with a session named after the project. Inspired by ThePrimeagen's tmux-sessionizer and tonybanters's dmenu-scripts."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Projects Directories"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }


    Column {
        width: parent.width
        spacing: 5

        StyledText { 
            text: "Directory Paths" 
        }

        StyledText {
            width: parent.width
            text: "Comma-separated paths. Trailing slash scans children (e.g. ~/Projects/); no slash treats the path itself as a project (e.g. ~/dotfiles). Supports absolute paths, ~, or relative to home. Default: ~/projects/"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        DankTextField {
            width: parent.width
            text: root.loadValue("projectsDir", "") 
            placeholderText: "~/projects/, ~/dotfiles, ~/work/"
            onEditingFinished: {
                root.saveValue("projectsDir", text);
            }
        }

    }

    ToggleSetting {
        id: includeHiddenSetting
        settingKey: "includeHidden"
        label: "Include Hidden Directories"
        description: "Include directories that start with a dot (e.g., .config, .local)"
        defaultValue: false
    }

    ToggleSetting {
        id: includeSymlinksSetting
        settingKey: "includeSymlinks"
        label: "Include Symlinked Directories"
        description: "Follow symbolic links and include symlinked directories"
        defaultValue: false
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Terminal"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    DankDropdown {
        id: terminalDropdown
        text: "Terminal Emulator"
        description: "Select your preferred terminal emulator"
        currentValue: root.loadValue("terminal", "st")
        options: [
            "st",
            "alacritty",
            "kitty",
            "wezterm",
            "foot",
            "konsole",
            "gnome-terminal",
            "xterm",
            "ghostty",
            "Custom"
        ]
        dropdownWidth: 180
        onValueChanged: function(value) {
            root.saveValue("terminal", value);
        }
    }

    Column {
        width: parent.width
        visible: terminalDropdown.currentValue === "Custom"
        spacing: 5

        StyledText { 
            text: "Custom Terminal" 
        }

        StyledText {
            width: parent.width
            text: "Command or path to the terminal executable"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        DankTextField {
            width: parent.width
            text: root.loadValue("customTerminal", "") 
            placeholderText: "my-terminal"
            onEditingFinished: {
                root.saveValue("customTerminal", text);
            }
        }

    }

    DankDropdown {
        id: terminalBehaviorDropdown
        text: "Terminal Behavior"
        description: "How to handle terminal windows when opening sessions"
        currentValue: root.loadValue("terminalBehavior", "newWindow")
        options: [
            "newWindow",
            "killExisting",
            "reuseSession"
        ]
        dropdownWidth: 180
        onValueChanged: function(value) {
            root.saveValue("terminalBehavior", value);
        }
    }

    StyledText {
        width: parent.width
        leftPadding: Theme.spacingM
        text: {
            var behavior = terminalBehaviorDropdown.currentValue;
            if (behavior === "newWindow") return "New Window: Opens a new terminal window for each session.";
            if (behavior === "killExisting") return "Kill Existing: Kills any existing terminal before opening a new one.";
            if (behavior === "reuseSession") return "Reuse Session: Switches an existing tmux client to the new session. Falls back to new window if no client exists. (tmux only — Zellij always opens a new window.)";
            return "";
        }
        font.pixelSize: Theme.fontSizeSmall
        font.italic: true
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Trigger"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    ToggleSetting {
        id: noTriggerToggle
        settingKey: "noTrigger"
        label: "Always Active"
        description: noTriggerToggle.value ? "Items will always show in the launcher (no trigger needed)." : "Set the trigger text to activate this plugin."
        defaultValue: false
    }

    Connections {
        target: noTriggerToggle

        function onValueChanged() {
            if (!noTriggerToggle.isInitialized)
                return;

            if (noTriggerToggle.value) {
                const current = triggerField.text || root.loadValue("trigger", "tm") || "tm";
                if (current !== "") {
                    root.saveValue("savedTrigger", current);
                }
                root.saveValue("trigger", "");
                triggerField.text = "";
                return;
            }

            const restored = root.loadValue("savedTrigger", "tm") || "tm";
            root.saveValue("trigger", restored);
            triggerField.text = restored;
        }
    }

    Column {
        width: parent.width
        visible: !noTriggerToggle.value
        spacing: 5

        StyledText { 
            text: "Trigger" 
        }

        StyledText {
            width: parent.width
            text: "Examples: tm, tmux, sess, etc."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        DankTextField {
            id: triggerField
            width: parent.width
            text: root.loadValue("trigger", "tm")
            placeholderText: "tm"
            onEditingFinished: {
                root.saveValue("trigger", text);
                if (text !== "") {
                    root.saveValue("savedTrigger", text);
                }
            }
        }

    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Kill Prefix"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    Column {
        width: parent.width
        spacing: 5

        StyledText {
            text: "Deletion Prefix"
        }

        StyledText {
            width: parent.width
            text: "Prefix typed before a session name in the launcher to kill it (default: !). Example: !work"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        DankTextField {
            id: killPrefixField
            width: parent.width
            text: root.loadValue("killPrefix", "!")
            placeholderText: "!"
            onEditingFinished: {
                var value = text.trim();
                if (value.length === 0)
                    value = "!";
                value = value.split(/\s+/)[0];
                if (killPrefixField.text !== value)
                    killPrefixField.text = value;
                root.saveValue("killPrefix", value);
            }
        }

    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    ToggleSetting {
        id: mruSortSetting
        settingKey: "mruSort"
        label: "Sort by Recency"
        description: "Show most recently opened projects first"
        defaultValue: false
    }

    Column {
        width: parent.width
        spacing: 5

        StyledText {
            text: "Max Results"
        }

        StyledText {
            width: parent.width
            text: "Maximum number of projects to display (10-200)."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        DankTextField {
            id: maxResultsField
            width: parent.width
            text: root.loadValue("maxResults", "50")
            placeholderText: "50"
            validator: IntValidator {
                bottom: 0
            }
            onEditingFinished: {
                const parsed = parseInt(text, 10);
                const value = isNaN(parsed) ? 0 : Math.max(0, parsed);
                const sanitized = String(value);
                if (maxResultsField.text !== sanitized) {
                    maxResultsField.text = sanitized;
                }
                root.saveValue("maxResults", sanitized);
            }
        }

    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Usage"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    Column {
        width: parent.width
        spacing: Theme.spacingXS
        leftPadding: Theme.spacingM
        bottomPadding: Theme.spacingL

        Repeater {
            model: [
                "1. Open Launcher",
                noTriggerToggle.value ? "2. Projects are always visible" : "2. Type 'tm' to filter to sessions",
                "3. Search by typing to filter projects",
                "4. Press Enter to open in terminal with your DMS multiplexer (tmux/Zellij)",
                "5. If a session exists, it will attach; otherwise creates new",
                "6. Type '" + (killPrefixField.text || "!") + "' before a name to kill a running session (e.g., " + (killPrefixField.text || "!") + "work)",
                "7. Multiplexer backend is taken from DMS Settings → System → Multiplexers",
                "Note: after changing the plugin configuration, restart your DMS session",
            ]

            StyledText {
                required property string modelData
                text: modelData
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    StyledText {
        width: parent.width
        text: "How it works"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    Column {
        width: parent.width
        spacing: Theme.spacingXS
        leftPadding: Theme.spacingM
        bottomPadding: Theme.spacingL

        Repeater {
            model: [
                "• Paths ending with / list their subdirectories as projects",
                "• Paths without a trailing / are added as a single project",
                "• Creates a multiplexer session named after the selected directory",
                "• Sets the working directory to the project directory",
                "• Attaches to existing sessions automatically",
                "• Uses DMS muxType (tmux or Zellij) — no separate plugin toggle"
            ]

            StyledText {
                required property string modelData
                text: modelData
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }
}
