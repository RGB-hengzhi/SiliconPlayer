"""Not-run Darwin arm64 adapter; no subprocess wait/poll until owned group exits.

The siginfo layout/constants are copied from the manifest-pinned public SDK.
A future signed C ABI probe must confirm them before configuring Little CMS.
"""
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def save(path, value):
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())


class SigValue(ctypes.Union):
    _fields_ = [('integer', ctypes.c_int), ('pointer', ctypes.c_void_p)]


class SigInfo(ctypes.Structure):
    _fields_ = [('signo', ctypes.c_int), ('error', ctypes.c_int), ('code', ctypes.c_int),
                ('pid', ctypes.c_int), ('uid', ctypes.c_uint), ('status', ctypes.c_int),
                ('address', ctypes.c_void_p), ('value', SigValue), ('band', ctypes.c_long),
                ('reserved', ctypes.c_ulong * 7)]


class Owner:
    def __init__(self, work, environment):
        require(ctypes.sizeof(SigInfo) == 104 and SigInfo.pid.offset == 12
                and SigInfo.status.offset == 20, 'Pinned Darwin siginfo ABI layout differs')
        self.work, self.environment, self.rows, self.active = work, environment, [], {}
        self.libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.waitid = self.libc.waitid
        self.waitid.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.POINTER(SigInfo), ctypes.c_int]
        self.waitid.restype = ctypes.c_int

    def ticket(self, process):
        require(process.returncode is None, 'Owned leader already reaped; signalling prohibited')
        # P_PID=1, WEXITED=4, WNOHANG=1, WNOWAIT=32 in the pinned SDK.
        for attempt in range(8):
            information = SigInfo(); ctypes.set_errno(0)
            status = self.waitid(1, process.pid, ctypes.byref(information), 4 | 1 | 32)
            if status == 0 or ctypes.get_errno() != errno.EINTR:
                break
        require(status == 0 and information.pid in (0, process.pid), 'Unreaped direct-child identity unavailable')
        require(information.pid == 0 or information.signo == signal.SIGCHLD, 'Unexpected waitid signal')
        return {'exited': information.pid == process.pid, 'pid': information.pid,
                'code': information.code, 'status': information.status}

    def members(self, process):
        # ps has no subprocess pipeline/descendants and is never group-signalled.
        inspector = subprocess.Popen(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat='],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment)
        try:
            stdout, stderr = inspector.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            inspector.kill()  # unreaped owned direct inspector only
            inspector.communicate(timeout=2)
            raise RuntimeError('Owned group inspector timed out')
        require(inspector.returncode == 0, 'Owned group inspector failed')
        rows = []
        for line in stdout.decode('utf-8', errors='strict').splitlines():
            parts = line.split()
            require(len(parts) == 4, 'Malformed group inspection row')
            pid, parent, group = map(int, parts[:3])
            if group == process.pid:
                rows.append({'pid': pid, 'ppid': parent, 'pgid': group, 'state': parts[3]})
        require(len(rows) <= 4096 and len({x['pid'] for x in rows}) == len(rows), 'Group inspection bound/duplicates')
        return sorted(rows, key=lambda row: row['pid'])

    def observe(self, process):
        ticket = self.ticket(process)
        members = self.members(process)
        # An exited child can be omitted by the kernel's PGID listing. Its
        # WNOWAIT ticket still reserves the birth PID/PGID, without getpgid(zombie).
        require(ticket['exited'] or any(row['pid'] == process.pid for row in members),
                'Live owned birth-group anchor not observed')
        return ticket, members

    def drive(self, process, row, timeout, cancel=False):
        deadline, term_at, kill_at = time.monotonic() + timeout, None, None
        while True:
            ticket, members = self.observe(process)
            live = [x for x in members if not x['state'].startswith('Z')]
            row['lastUnreapedTicket'], row['lastMembers'] = ticket, members
            if ticket['exited'] and not live:
                # Only this site reaps. There will never be a later group signal.
                waited, status = os.waitpid(process.pid, os.WNOHANG)
                if waited == 0:
                    time.sleep(.02); continue
                require(waited == process.pid, 'Final direct-child reap identity differs')
                process.returncode = os.waitstatus_to_exitcode(status)
                row.update(exit=process.returncode, leaderReaped=True,
                           leaderHeldUnreapedUntilWholeGroupNoLive=True)
                self.active.pop(process.pid, None)
                end = time.monotonic() + 1
                remaining = self.members(process)
                while remaining and time.monotonic() < end:
                    time.sleep(.05); remaining = self.members(process)
                row['remainingGroupMembers'] = remaining
                row['ownedGroupAbsent'] = not remaining
                return
            now = time.monotonic()
            if cancel or now >= deadline:
                row['timedOut'] = row['timedOut'] or (not cancel and now >= deadline)
                row['forcedCleanup'] = True
                # The successful non-reaping waitid ticket above proves that
                # the birth PID remains our direct child even if it just exited.
                self.ticket(process)
                if term_at is None:
                    sig = signal.SIGTERM; term_at = now
                elif now - term_at >= 2 and kill_at is None:
                    sig = signal.SIGKILL; kill_at = now
                else:
                    sig = None
                if sig is not None:
                    try:
                        os.killpg(process.pid, sig)
                        row['signals'].append({'signal': int(sig), 'elapsed': now - row['began']})
                    except ProcessLookupError:
                        row['signals'].append({'signal': int(sig), 'result': 'ESRCH-unconfirmed'})
                require(kill_at is None or now - kill_at < 3, 'Owned group still live after bounded escalation')
            time.sleep(.04)

    def run(self, name, argv, timeout=180, cwd=None):
        folder = self.work / 'stages' / name
        folder.mkdir(parents=True, exist_ok=False)
        cwd = cwd or self.work
        row = {'stage': name, 'argv': argv, 'cwd': str(cwd), 'began': time.monotonic(),
               'spawned': False, 'timedOut': False, 'forcedCleanup': False, 'signals': [],
               'leaderReaped': False, 'ownedGroupAbsent': False, 'exit': None}
        save(folder / 'argv.json', argv)
        try:
            with (folder / 'stdout.txt').open('xb') as stdout, (folder / 'stderr.txt').open('xb') as stderr:
                process = subprocess.Popen(argv, cwd=cwd, env=self.environment, stdin=subprocess.DEVNULL,
                              stdout=stdout, stderr=stderr, start_new_session=True, close_fds=True)
                row.update(spawned=True, PID=process.pid, birthPGID=process.pid,
                    birthProof='Popen start_new_session: successful setsid plus exec error-pipe handshake')
                self.active[process.pid] = (process, row)
                self.drive(process, row, timeout)
                stdout.flush(); stderr.flush(); os.fsync(stdout.fileno()); os.fsync(stderr.fileno())
        except BaseException as error:
            row.update(errorType=type(error).__name__, error=str(error))
            raise
        finally:
            row['elapsedSeconds'] = time.monotonic() - row['began']
            self.rows.append(row); save(folder / 'result.json', row)
        require(row['exit'] == 0 and not row['timedOut'] and not row['forcedCleanup']
                and row['leaderReaped'] and row['ownedGroupAbsent'], name + ' failed; logs retained')
        return (folder / 'stdout.txt').read_text(errors='strict')

    def cleanup(self):
        rows = []
        for pid, (process, original) in list(self.active.items()):
            row = {'PID': pid, 'began': time.monotonic(), 'timedOut': False,
                   'forcedCleanup': False, 'signals': [], 'leaderReaped': False, 'ownedGroupAbsent': False}
            try:
                self.drive(process, row, 0, cancel=True)
            except BaseException as error:
                row.update(errorType=type(error).__name__, error=str(error), ownershipUnconfirmed=True)
            row['elapsedSeconds'] = time.monotonic() - row['began']; rows.append(row)
        return {'cleanupRows': rows, 'unreapedOwnedPIDs': sorted(self.active),
                'scope': 'Only the birth group reserved by a non-reaped direct child; escaped new-session descendants are not claimed.'}
