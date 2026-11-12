#!/usr/bin/env python3
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time


def main() -> int:
    if len(sys.argv) < 5:
        print("usage: pty_drive.py <cwd> <script> <logfile> <scenario>", file=sys.stderr)
        return 2
    cwd, script, logfile, scenario = sys.argv[1:5]

    # (motif à attendre dans la sortie, octets à envoyer, délai max d'attente)
    if scenario == "single_enter":
        steps = [
            (b"Private data backup v", b"\r", 10.0),                 # menu: Sauvegarder
            (b"Entr\xc3\xa9e pour valider le profil", b"\r", 10.0), # liste: premier profil
            (b"Sauvegarder :", b"\r", 10.0),                         # confirmation
            (b"pour revenir au menu", b"\r", 10.0),                  # pause
        ]
    elif scenario == "multi_check":
        steps = [
            (b"Private data backup v", b"\r", 10.0),                              # menu: Sauvegarder
            (b"Cocher plusieurs profils", b"\x1b[B" * 3 + b"\r", 10.0),           # ouvrir multi
            (b"x pour cocher, Entr\xc3\xa9e pour valider", b"x\x1b[Bx\r", 10.0), # cocher 2
            (b"Sauvegarder :", b"\r", 10.0),                                      # confirmation
            (b"pour revenir au menu", b"\r", 10.0),                               # pause
        ]
    elif scenario == "escape":
        steps = [
            (b"Private data backup v", b"\r", 10.0),                 # menu: Sauvegarder
            (b"Entr\xc3\xa9e pour valider le profil", b"\x1b", 10.0), # Échap
            (b"pour revenir au menu", b"\r", 10.0),                  # notice
        ]
    else:
        print(f"unknown scenario: {scenario}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    env["COLUMNS"] = "120"
    env["LINES"] = "40"

    pid, fd = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        except OSError:
            pass
        os.chdir(cwd)
        os.execvpe("bash", ["bash", script], env)
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    except OSError:
        pass

    output = bytearray()
    deadline = time.time() + 35.0
    step_index = 0
    wait_until = time.time() + (steps[0][2] if steps else 0)
    sent_for_step = False
    quit_sent = False
    child_done = False

    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if fd in r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    child_done = True
                    break
                output.extend(data)

            if step_index >= len(steps):
                # scénario terminé : on quitte la session TUI puis on termine
                if not quit_sent:
                    time.sleep(0.3)
                    try:
                        os.write(fd, b"\x1b[B" * 7 + b"\r")
                    except OSError:
                        pass
                    quit_sent = True
                    quit_at = time.time()
                if child_done:
                    break
                if quit_sent and time.time() - quit_at > 2.0:
                    break
                time.sleep(0.1)
                continue

            needle, payload, timeout_s = steps[step_index]
            if needle in output and not sent_for_step:
                time.sleep(0.2)
                try:
                    os.write(fd, payload)
                except OSError:
                    break
                step_index += 1
                sent_for_step = False
                if step_index < len(steps):
                    wait_until = time.time() + steps[step_index][2]
                continue

            if time.time() > wait_until:
                # délai dépassé pour cette étape : on tente quand même une fois
                if not sent_for_step:
                    try:
                        os.write(fd, payload)
                    except OSError:
                        break
                    step_index += 1
                    sent_for_step = False
                    if step_index < len(steps):
                        wait_until = time.time() + steps[step_index][2]
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass

    with open(logfile, "wb") as fh:
        fh.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
