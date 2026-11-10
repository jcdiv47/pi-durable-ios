import Foundation

/// The POSIX sh scripts behind `ssh_exec` and `ssh_job`.
///
/// Every command runs as a detached job in `~/.cache/pi-durable/ssh/<job>/` on the remote machine: `cmd` (the command),
/// `out`, `err`, `pid`, and `exit` once it finished. The job ID comes from the tool task, so a tool call that reruns
/// after Pi was killed finds the job it started (`mkdir` decides, atomically) and waits for it instead of running the
/// command again. The job also keeps running while iOS suspends Pi.
///
/// The scripts go to `sh -s` on stdin, never in the exec request, so the user's login shell (fish, say) never parses
/// them; the command itself reaches the remote side only inside a quoted heredoc.
enum SSHJobScript {
    static let base = #""${HOME:-/tmp}/.cache/pi-durable/ssh""#
    /// Days a finished job's files are kept.
    static let keepDays = 7

    /// Job IDs are file names: letters, digits, `-` and `_`.
    static func validJob(_ job: String) -> Bool {
        !job.isEmpty && job.count <= 96 && job.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Starts the job unless its directory exists; prints `pi-ssh:started` or `pi-ssh:exists`.
    static func start(job: String, command: String, shell: SSHHost.Shell, delimiter: String = "PI_SSH_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") -> String {
        precondition(validJob(job))
        // Commands and their output are private to the account: other users on the machine must not read them.
        return """
        umask 077
        b=\(base)
        d="$b/\(job)"
        mkdir -p "$b" 2>/dev/null || { echo "pi-ssh:error Can't create $b"; exit 0; }
        chmod 700 "$b" 2>/dev/null
        find "$b" -mindepth 1 -maxdepth 1 -type d -mtime +\(keepDays) -exec rm -rf {} + 2>/dev/null
        if mkdir "$d" 2>/dev/null; then
        cat > "$d/cmd" <<'\(delimiter)'
        \(command)
        \(delimiter)
        cat > "$d/run" <<'PI_SSH_RUN'
        cd "$HOME" 2>/dev/null
        \(shell.invocation) "$(cat "$1/cmd")" > "$1/out" 2> "$1/err" < /dev/null
        echo $? > "$1/exit.tmp"
        mv "$1/exit.tmp" "$1/exit"
        PI_SSH_RUN
        if command -v setsid >/dev/null 2>&1; then
        setsid nohup sh "$d/run" "$d" > /dev/null 2>&1 < /dev/null &
        else
        nohup sh "$d/run" "$d" > /dev/null 2>&1 < /dev/null &
        fi
        echo $! > "$d/pid"
        echo "pi-ssh:started"
        else
        echo "pi-ssh:exists"
        fi
        exit 0

        """
    }

    /// Waits up to `seconds` for the job, then prints its state lines, `pi-ssh:stdout`, and its stdout (cut to
    /// `outLimit` bytes: the start and the end); its stderr (cut to `errLimit`) goes to stderr.
    static func collect(job: String, seconds: Int, outLimit: Int = 24_000, errLimit: Int = 8_000) -> String {
        precondition(validJob(job))
        return """
        d=\(base)/\(job)
        [ -d "$d" ] || { echo "pi-ssh:missing"; exit 0; }
        end=$(( $(date +%s) + \(max(0, seconds)) ))
        while [ ! -f "$d/exit" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 0.2 2>/dev/null || sleep 1; done
        pid=$(cat "$d/pid" 2>/dev/null)
        if [ -f "$d/exit" ]; then echo "pi-ssh:done $(cat "$d/exit") $pid"
        elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "pi-ssh:running 0 $pid"
        elif [ -f "$d/exit" ]; then echo "pi-ssh:done $(cat "$d/exit") $pid"
        else echo "pi-ssh:lost 0 $pid"; fi
        size() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
        so=$(size "$d/out"); se=$(size "$d/err")
        echo "pi-ssh:size $so $se"
        clip() {
        if [ "$2" -le "$3" ]; then cat "$1" 2>/dev/null
        else head -c "$4" "$1"; printf '\\n[… %s bytes cut …]\\n' $(( $2 - $3 )); tail -c $(( $3 - $4 )) "$1"; fi
        }
        echo "pi-ssh:stdout"
        clip "$d/out" "$so" \(outLimit) \(outLimit / 3)
        clip "$d/err" "$se" \(errLimit) \(errLimit / 4) >&2
        exit 0

        """
    }

    /// A short look at the machine, for Settings' "Test connection".
    static let about = """
    echo "pi-ssh:shell ${SHELL:-}"
    echo "pi-ssh:system $(uname -sr 2>/dev/null)"
    echo "pi-ssh:host $(hostname 2>/dev/null)"
    exit 0

    """

    /// What `collect` printed.
    struct Collected: Equatable {
        var state: String
        var exitCode: Int?
        var pid: Int?
        var stdoutBytes = 0
        var stderrBytes = 0
        var stdout = ""
    }

    static func parse(_ stdout: String) -> Collected {
        var collected = Collected(state: "missing")
        let (head, body) = split(stdout)
        for line in head.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            switch fields.first {
            case "pi-ssh:done", "pi-ssh:running", "pi-ssh:lost":
                collected.state = String(fields[0].dropFirst("pi-ssh:".count))
                if collected.state == "done" { collected.exitCode = fields.count > 1 ? Int(fields[1]) : nil }
                collected.pid = fields.count > 2 ? Int(fields[2]) : nil
            case "pi-ssh:missing":
                collected.state = "missing"
            case "pi-ssh:size":
                collected.stdoutBytes = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
                collected.stderrBytes = fields.count > 2 ? Int(fields[2]) ?? 0 : 0
            default:
                break
            }
        }
        collected.stdout = body
        return collected
    }

    private static func split(_ text: String) -> (String, String) {
        let marker = "pi-ssh:stdout\n"
        if text.hasPrefix(marker) { return ("", String(text.dropFirst(marker.count))) }
        guard let range = text.range(of: "\n" + marker) else { return (text, "") }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
}
