# InnoViewDualMonitorDriver: build, install and run. `just` alone lists the recipes.
# The build itself is InnoViewDualMonitorDriver/build.sh, which also works without just.

built := "InnoViewDualMonitorDriver/build/InnoViewDualMonitorDriver.app/Contents/MacOS/InnoViewDualMonitorDriver"

# list the recipes
default:
    @just --list --unsorted

# build build/InnoViewDualMonitorDriver.app and install a copy to ~/Applications
build:
    InnoViewDualMonitorDriver/build.sh

# build, install and restart the running copy
run:
    InnoViewDualMonitorDriver/build.sh run

# remove build products (the installed copy stays)
clean:
    rm -rf InnoViewDualMonitorDriver/build

# quit the running copy: it switches the screen off and releases the device
stop:
    #!/bin/sh
    if pkill -TERM -x InnoViewDualMonitorDriver; then
        while pgrep -x InnoViewDualMonitorDriver >/dev/null; do sleep 0.2; done
    fi

# start the installed copy
start:
    open ~/Applications/InnoViewDualMonitorDriver.app

# chip id, status and EDID without changing anything (run `just stop` first)
probe:
    {{built}} --probe

# color bars and a moving square straight to the chip (run `just stop` first)
pattern seconds="10" *full:
    {{built}} --pattern {{seconds}} {{full}}

# follow the newest log
log:
    tail -f "$(ls -t ~/Library/Logs/InnoViewDualMonitorDriver/driver_*.log | head -1)"
