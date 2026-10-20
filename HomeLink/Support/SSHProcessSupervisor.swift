import Foundation

/// All paths and SSH options are positional arguments, never interpolated into shell code.
/// The private stdin pipe is a lifeline: parent death closes it even after SIGKILL.
nonisolated enum SSHProcessSupervisor {
    static let script = #"""
    key_dir=$1
    shift
    exec 3<&0
    "$@" </dev/null &
    ssh_pid=$!
    supervisor_pid=$$
    watcher_pid=
    cleanup() {
      trap '' TERM INT HUP
      if /bin/kill -0 "$ssh_pid" 2>/dev/null; then
        /bin/kill -TERM "$ssh_pid" 2>/dev/null || :
        count=0
        while /bin/kill -0 "$ssh_pid" 2>/dev/null && [ "$count" -lt 20 ]; do
          /bin/sleep 0.05
          count=$((count + 1))
        done
        /bin/kill -KILL "$ssh_pid" 2>/dev/null || :
      fi
      [ -z "$watcher_pid" ] || /bin/kill -TERM "$watcher_pid" 2>/dev/null || :
      wait "$ssh_pid" 2>/dev/null || :
      /bin/rm -f "$key_dir/identity" "$key_dir/identity.pub"
      /bin/rmdir "$key_dir" 2>/dev/null || :
    }
    trap cleanup EXIT
    trap 'exit 143' TERM INT HUP
    (
      while IFS= read -r line <&3; do :; done
      /bin/kill -TERM "$supervisor_pid" 2>/dev/null || :
    ) &
    watcher_pid=$!
    wait "$ssh_pid"
    status=$?
    exit "$status"
    """#
}
