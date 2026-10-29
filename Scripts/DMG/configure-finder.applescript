on run arguments
    set volumeName to item 1 of arguments
    set appName to item 2 of arguments

    tell application "Finder"
        repeat 50 times
            if exists disk volumeName then exit repeat
            delay 0.2
        end repeat
        tell disk volumeName
            open
            set installerWindow to container window
            set current view of installerWindow to icon view
            set toolbar visible of installerWindow to false
            set statusbar visible of installerWindow to false
            set pathbar visible of installerWindow to false
            set bounds of installerWindow to {120, 120, 780, 540}

            set viewOptions to icon view options of installerWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 14
            set background picture of viewOptions to file ".background:background.png"

            set position of item appName of installerWindow to {180, 220}
            set position of item "Applications" of installerWindow to {480, 220}
            close installerWindow
            open
            update without registering applications
            delay 2
        end tell
    end tell
end run
