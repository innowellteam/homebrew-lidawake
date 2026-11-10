#!/usr/bin/env python3
import os
import signal
import pathlib
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory)
    env = dict(os.environ, TEST_RECOVERY_DIRECTORY=directory)
    def start():
        return subprocess.Popen([binary, "--sleep-recovery-worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, env=env)
    def send(process, command):
        process.stdin.write(command + '\n')
        process.stdin.flush()
        return process.stdout.readline().strip()
    def state():
        return (path / 'power').read_text()
    worker = start()
    assert worker.stdout.readline().strip() == 'ready'
    assert not (path / 'power').exists(), 'untouched external state'
    assert send(worker, 'awake') == 'ok' and state() == 'awake'
    contender = start()
    assert contender.wait() != 0, 'second worker excluded'
    worker.stdin.close()
    assert worker.wait() == 0 and state() == 'sleep', 'EOF restores sleep'
    worker = start()
    assert worker.stdout.readline().strip() == 'ready'
    assert send(worker, 'awake') == 'ok'
    (path / 'fail-restore').touch()
    assert send(worker, 'sleep') == 'error' and state() == 'awake'
    worker.kill()
    worker.wait()
    blocked = start()
    assert blocked.wait() != 0 and state() == 'awake', 'failed recovery stays pending'
    (path / 'fail-restore').unlink()
    worker = start()
    assert worker.stdout.readline().strip() == 'ready' and state() == 'sleep', 'next launch retries recovery'
    assert send(worker, 'awake') == 'ok'
    assert send(worker, 'sleep') == 'ok' and state() == 'sleep'
    worker.stdin.close()
    assert worker.wait() == 0
    controller = subprocess.Popen([binary, '--controller'], stdout=subprocess.PIPE, text=True, env=env)
    assert controller.stdout.readline().strip() == 'controller ready'
    assert state() == 'awake'
    controller.kill()
    controller.wait()
    for _ in range(100):
        if state() == 'sleep': break
        time.sleep(0.05)
    assert state() == 'sleep', 'worker restores after controller is killed'
    print('recovery worker behavior passed')
