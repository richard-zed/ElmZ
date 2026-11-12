field font:
    zig build field -Dfont={{font}}

bench:
    zig build bench

build wd cmd:
    #!/bin/sh
    # Detach a build. The 60s tool cap kills attached runs; setsid does not.
    wd="$1"; cmd="$2"
    rm -f /tmp/job.log /tmp/job.status /tmp/job.token
    token=$$-$(date +%s)
    echo "$token" > /tmp/job.token
    setsid sh -c "cd '$wd' && $cmd > /tmp/job.log 2>&1; echo EXIT=\$? > /tmp/job.status; echo $token > /tmp/job.done" </dev/null >/dev/null 2>&1 &
echo "STARTED $token"


# Stale status files read as success, so only trust a matching token.
status:
    #!/bin/sh
    if [ -f /tmp/job.done ] && [ -f /tmp/job.token ] && \
       [ "$(cat /tmp/job.done)" = "$(cat /tmp/job.token)" ]; then
        cat /tmp/job.status
    else
        echo RUNNING
    fi

log:
    tail -40 /tmp/job.log
