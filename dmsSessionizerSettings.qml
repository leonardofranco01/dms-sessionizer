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
        text: "Quickly open project directories in a terminal with dedicated tmux sessions. Select a project and it will launch your terminal with a tmux session named after the project. Inspired by ThePrimeagen's tmux-sessionizer and tonybanters's dmenu-scripts."
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

    StringSetting {
        id: projectsDirSetting
        settingKey: "projectsDir"
        label: "Directory Paths"
        description: "Paths to your project directories, separated by commas. Supports absolute paths, ~ for home, or relative to home. Default: ~/projects"
        placeholder: "~/projects, ~/work, ~/code"
        defaultValue: ""
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

    StringSetting {
        id: customTerminalSetting
        visible: terminalDropdown.currentValue === "Custom"
        settingKey: "customTerminal"
        label: "Custom Terminal"
        description: "Command or path to the terminal executable"
        placeholder: "my-terminal"
        defaultValue: ""
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
            if (behavior === "reuseSession") return "Reuse Session: Switches an existing tmux client to the new session. Falls back to new window if no client exists.";
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
        description: value ? "Items will always show in the launcher (no trigger needed)." : "Set the trigger text to activate this plugin."
        defaultValue: false
        onValueChanged: {
            if (value) {
                root.saveValue("trigger", "");
            } else {
                root.saveValue("trigger", triggerSetting.value || "tm");
            }
        }
    }

    StringSetting {
        id: triggerSetting
        visible: !noTriggerToggle.value
        settingKey: "trigger"
        label: "Trigger"
        description: "Examples: tm, tmux, sess, etc."
        placeholder: "tm"
        defaultValue: "tm"
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StringSetting {
        id: maxResultsSetting
        settingKey: "maxResults"
        label: "Max Results"
        description: "Maximum number of projects to display (10-200)."
        placeholder: "50"
        defaultValue: "50"
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
                noTriggerToggle.value ? "2. Projects are always visible" : "2. Type 'tm' to filter to tmux sessions",
                "3. Search by typing to filter projects",
                "4. Press Enter to open in terminal with tmux",
                "5. If a session exists, it will attach; otherwise creates new",
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
                "• Lists all subdirectories in your projects directories",
                "• Creates a tmux session named after the subdirectory selected",
                "• Sets the working directory to the project directory",
                "• Attaches to existing sessions automatically"
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
