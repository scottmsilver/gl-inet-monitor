#!/bin/sh /etc/rc.common
# Dashboard data collector daemon

START=99
STOP=10
USE_PROCD=1

DAEMON=/root/dash_daemon.sh
PID_FILE=/tmp/dash_daemon.pid

start_service() {
    procd_open_instance
    procd_set_param command $DAEMON
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
    fi
}

restart() {
    stop
    start
}
