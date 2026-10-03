# opencloud-script-test

CI test harness for the [community-scripts](https://github.com/community-scripts/ProxmoxVE) OpenCloud LXC script (`ct/opencloud.sh`, `install/opencloud-install.sh`).

GitHub-hosted runners act as an Incus host. The community-scripts engine has a native Incus backend, so the real `ct/` script creates the container. Fake `*.oc.test` domains only; no real infrastructure is involved.

Not affiliated with community-scripts or OpenCloud.
