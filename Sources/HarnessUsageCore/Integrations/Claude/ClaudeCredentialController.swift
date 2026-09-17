import Foundation

/// Exchanges the OAuth credential blobs between two Claude config roots on ONE remote host. The
/// profiles' plugins, projects, settings, and transcripts are never moved. Originals are copied to
/// a private backup directory on that host before either credential path is replaced.
public actor ClaudeCredentialController: CredentialController {
    private let alias: String
    private let firstDir: String
    private let secondDir: String
    private let run: @Sendable (String) async -> RemoteShell.Outcome

    public init?(
        first: AccountConfig, second: AccountConfig,
        run: (@Sendable (String) async -> RemoteShell.Outcome)? = nil
    ) {
        guard first.harness == .claude, second.harness == .claude,
            first.integration != second.integration,
            let alias = first.host.sshAlias, alias == second.host.sshAlias
        else { return nil }
        let firstDir = first.resolvedConfigDir(home: nil)
        let secondDir = second.resolvedConfigDir(home: nil)
        guard firstDir != secondDir else { return nil }
        self.alias = alias
        self.firstDir = firstDir
        self.secondDir = secondDir
        let shell = RemoteShell(alias: alias, deadline: .seconds(45))
        self.run = run ?? { await shell.run($0) }
    }

    public func preflight() async -> ControllerOutcome { await call(.preflight, backupID: nil) }
    public func exchange(backupID: UUID) async -> ControllerOutcome {
        await call(.exchange, backupID: backupID)
    }
    public func copyFirstToSecond(backupID: UUID) async -> ControllerOutcome {
        await call(.copyFirst, backupID: backupID)
    }
    public func copySecondToFirst(backupID: UUID) async -> ControllerOutcome {
        await call(.copySecond, backupID: backupID)
    }
    public func preflightRestore(backupID: UUID) async -> ControllerOutcome {
        await call(.preflightRestore, backupID: backupID)
    }
    public func restore(backupID: UUID, newBackupID: UUID) async -> ControllerOutcome {
        await call(.restore, backupID: backupID, newBackupID: newBackupID)
    }

    private enum Mode: String { case preflight, exchange, copyFirst, copySecond, preflightRestore, restore }

    private func call(_ mode: Mode, backupID: UUID?, newBackupID: UUID? = nil) async -> ControllerOutcome {
        let outcome = await run(script(mode: mode, backupID: backupID, newBackupID: newBackupID))
        switch outcome {
        case .failed(let reason): return .failed(reason)
        case .ok(let output):
            let line = output.split(separator: "\n").last.map(String.init) ?? ""
            if line == "READY" { return .ready }
            if line.hasPrefix("EXCHANGED "), let id = UUID(uuidString: String(line.dropFirst(10))) {
                return .exchanged(backupID: id)
            }
            if line.hasPrefix("COPIED "), let id = UUID(uuidString: String(line.dropFirst(7))) {
                return .copied(backupID: id)
            }
            if line.hasPrefix("RESTORED "), let id = UUID(uuidString: String(line.dropFirst(9))) {
                return .restored(backupID: id)
            }
            if line.hasPrefix("PARTIAL "), let id = UUID(uuidString: String(line.dropFirst(8))) {
                return .partial(backupID: id)
            }
            if line.hasPrefix("ERR ") { return .refused(Self.reason(for: String(line.dropFirst(4)))) }
            return .failed("The remote controller returned an unexpected result.")
        }
    }

    private static func reason(for code: String) -> String {
        switch code {
        case "missing_login": "One remote Claude profile has no readable credential file."
        case "invalid_login": "One remote Claude credential file is not a valid OAuth login."
        case "unsafe_path": "The remote profile paths or file ownership are unsafe for exchange."
        case "same_profile": "Both profiles resolve to the same remote directory."
        case "missing_backup": "The requested remote backup is missing or unreadable."
        case "busy": "Another remote credential operation is running."
        case "python_missing": "Python 3 is required on the remote host for this action."
        case "write_failed": "The remote profile could not be written; both logins were left unchanged."
        default: "The remote credential action was refused (\(code))."
        }
    }

    private func script(mode: Mode, backupID: UUID?, newBackupID: UUID?) -> String {
        let first = RemoteScript.remotePath(firstDir)
        let second = RemoteScript.remotePath(secondDir)
        let backup = RemoteScript.quote(backupID?.uuidString ?? "")
        let newBackup = RemoteScript.quote(newBackupID?.uuidString ?? "")
        return """
            set -u
            umask 077
            export HU_FIRST=\(first) HU_SECOND=\(second)
            export HU_MODE=\(RemoteScript.quote(mode.rawValue)) HU_BACKUP=\(backup) HU_NEW_BACKUP=\(newBackup)
            export HU_BACKUP_ROOT="$HOME/.harness-controller/backups"
            command -v python3 >/dev/null || { echo 'ERR python_missing'; exit 0; }
            if [ "$HU_MODE" = exchange ] || [ "$HU_MODE" = copyFirst ] \
              || [ "$HU_MODE" = copySecond ] || [ "$HU_MODE" = restore ]; then
              [ ! -L "$HOME/.harness-controller" ] && [ ! -L "$HOME/.harness-controller/backups" ] \
                && [ ! -L "$HOME/.harness-controller/controller.lock" ] \
                || { echo 'ERR unsafe_path'; exit 0; }
              mkdir -p "$HOME/.harness-controller/backups" || { echo 'ERR unsafe_path'; exit 0; }
              chmod 700 "$HOME/.harness-controller" "$HOME/.harness-controller/backups" || { echo 'ERR unsafe_path'; exit 0; }
              exec 9> "$HOME/.harness-controller/controller.lock"
              flock -n 9 || { echo 'ERR busy'; exit 0; }
            fi
            python3 - <<'PY'
            \(Self.remoteProgram)
            PY
            """
    }

    // stdin is the only carrier for this program. It prints fixed status codes and UUIDs only;
    // neither credentials nor their hashes are transmitted or placed in an argument list.
    private static let remoteProgram = """
        import json, os, stat, tempfile
        from pathlib import Path

        class Refusal(Exception):
            pass

        def read_file(path, missing_code):
            if path.is_symlink() or not path.exists():
                raise Refusal(missing_code)
            fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                    raise Refusal('unsafe_path')
                with os.fdopen(fd, 'rb', closefd=False) as stream:
                    blob = stream.read()
            finally:
                os.close(fd)
            return blob

        def read_login(path, missing_code='missing_login'):
            blob = read_file(path, missing_code)
            try:
                token = json.loads(blob)['claudeAiOauth']['accessToken']
                if not isinstance(token, str) or not token:
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise Refusal('invalid_login')
            return blob

        def read_profile(path, missing_code='missing_login'):
            blob = read_file(path, missing_code)
            try:
                profile = json.loads(blob)
                if not isinstance(profile, dict) or not isinstance(profile.get('oauthAccount'), dict):
                    raise ValueError()
            except (ValueError, TypeError):
                raise Refusal('invalid_login')
            return blob, profile

        def account_profile(profile, account):
            updated = dict(profile)
            updated['oauthAccount'] = account
            return (json.dumps(updated, ensure_ascii=False, separators=(',', ':')) + chr(10)).encode()

        def write_private(path, blob):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(fd, 'wb', closefd=False) as stream:
                    stream.write(blob)
                    stream.flush()
                    os.fsync(fd)
            finally:
                os.close(fd)

        def stage(directory, blob):
            fd, name = tempfile.mkstemp(prefix='.harness-controller-', dir=directory)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(blob)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.chmod(name, 0o600)
                return name
            except Exception:
                os.unlink(name)
                raise

        def replace_many(paths, targets, originals):
            staged = []
            rollback = []
            replaced = []
            try:
                for path, target, original in zip(paths, targets, originals):
                    staged.append(stage(path.parent, target))
                    rollback.append(stage(path.parent, original))
                for index, path in enumerate(paths):
                    os.replace(staged[index], path)
                    replaced.append(index)
            except Exception:
                for index in reversed(replaced):
                    try:
                        os.replace(rollback[index], paths[index])
                    except Exception:
                        raise Refusal('partial')
                raise Refusal('write_failed')
            finally:
                for name in staged + rollback:
                    if os.path.exists(name):
                        os.unlink(name)

        try:
            a_dir = Path(os.environ['HU_FIRST']).resolve(strict=True)
            b_dir = Path(os.environ['HU_SECOND']).resolve(strict=True)
            if a_dir == b_dir:
                raise Refusal('same_profile')
            if not a_dir.is_dir() or not b_dir.is_dir():
                raise Refusal('unsafe_path')
            a = a_dir / '.credentials.json'
            b = b_dir / '.credentials.json'
            a_profile_path = a_dir / '.claude.json'
            b_profile_path = b_dir / '.claude.json'
            current_a = read_login(a)
            current_b = read_login(b)
            current_a_profile_blob, current_a_profile = read_profile(a_profile_path)
            current_b_profile_blob, current_b_profile = read_profile(b_profile_path)
            mode = os.environ['HU_MODE']
            if mode == 'preflight':
                print('READY')
            else:
                root = Path(os.environ['HU_BACKUP_ROOT'])
                if root.is_symlink():
                    raise Refusal('unsafe_path')
                if mode in ('preflightRestore', 'restore'):
                    prior = root / os.environ['HU_BACKUP']
                    original_a = read_login(prior / 'first.credentials.json', 'missing_backup')
                    original_b = read_login(prior / 'second.credentials.json', 'missing_backup')
                    _, original_a_profile = read_profile(prior / 'first.profile.json', 'missing_backup')
                    _, original_b_profile = read_profile(prior / 'second.profile.json', 'missing_backup')
                    if mode == 'preflightRestore':
                        print('READY')
                    else:
                        backup_id = os.environ['HU_NEW_BACKUP']
                        target_a, target_b = original_a, original_b
                        target_a_profile = account_profile(current_a_profile, original_a_profile['oauthAccount'])
                        target_b_profile = account_profile(current_b_profile, original_b_profile['oauthAccount'])
                else:
                    backup_id = os.environ['HU_BACKUP']
                    if mode == 'copyFirst':
                        target_a, target_b = current_a, current_a
                        target_a_profile = current_a_profile_blob
                        target_b_profile = account_profile(current_b_profile, current_a_profile['oauthAccount'])
                    elif mode == 'copySecond':
                        target_a, target_b = current_b, current_b
                        target_a_profile = account_profile(current_a_profile, current_b_profile['oauthAccount'])
                        target_b_profile = current_b_profile_blob
                    else:
                        target_a, target_b = current_b, current_a
                        target_a_profile = account_profile(current_a_profile, current_b_profile['oauthAccount'])
                        target_b_profile = account_profile(current_b_profile, current_a_profile['oauthAccount'])
                if mode in ('exchange', 'copyFirst', 'copySecond', 'restore'):
                    fresh = root / backup_id
                    fresh.mkdir(mode=0o700)
                    write_private(fresh / 'first.credentials.json', current_a)
                    write_private(fresh / 'second.credentials.json', current_b)
                    write_private(fresh / 'first.profile.json', current_a_profile_blob)
                    write_private(fresh / 'second.profile.json', current_b_profile_blob)
                    replace_many(
                        [a, b, a_profile_path, b_profile_path],
                        [target_a, target_b, target_a_profile, target_b_profile],
                        [current_a, current_b, current_a_profile_blob, current_b_profile_blob])
                    verb = 'RESTORED ' if mode == 'restore' else 'EXCHANGED ' if mode == 'exchange' else 'COPIED '
                    print(verb + backup_id)
        except Refusal as error:
            if str(error) == 'partial':
                operation_id = os.environ['HU_NEW_BACKUP'] if os.environ['HU_MODE'] == 'restore' else os.environ['HU_BACKUP']
                print('PARTIAL ' + operation_id)
            else:
                print('ERR ' + str(error))
        except FileNotFoundError:
            print('ERR missing_login')
        except Exception:
            print('ERR write_failed')
        """
}
