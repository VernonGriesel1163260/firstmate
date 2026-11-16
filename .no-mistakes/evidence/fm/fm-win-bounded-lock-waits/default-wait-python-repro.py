import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

lib = sys.argv[1]
with tempfile.TemporaryDirectory() as root:
    state = Path(root) / 'real-dir-default-wait'
    state.mkdir()
    lock = state / '.contend.lock'
    lock.mkdir()
    dead = subprocess.run(['bash', '-c', 'echo $$'], capture_output=True, text=True).stdout.strip()
    (lock / 'pid').write_text(dead + '\n')
    record = lock / 'unrecognized-record'
    record.write_text('preserve me\n')
    os.utime(lock, (1, 1))
    child = subprocess.Popen(
        ['bash', '-c', '. "$1"; fm_lock_acquire_wait "$2" || exit 10; fm_lock_release "$2"',
         '_', lib, str(lock)], env=dict(os.environ, FM_STATE_OVERRIDE=str(state)),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        observed = []
        for i in range(100):
            gone = not (lock / 'pid').exists()
            observed.append((i * 50, gone, child.poll()))
            if gone:
                break
            time.sleep(0.05)
        print('poll samples (first/last 5):', observed[:5], observed[-5:])
        assert not (lock / 'pid').exists(), 'reclamation was never attempted'
        assert child.poll() is None, 'ordinary wait returned without ownership: rc=%s err=%s' % (child.poll(), child.stderr.read() if child.stderr else '')
        assert record.read_text() == 'preserve me\n'
        record.unlink()
        os.utime(lock, (1, 1))
        out, err = child.communicate(timeout=30)
        print('child rc=', child.returncode)
        print('child err=', err.strip()[:200])
        assert child.returncode == 0, (out, err)
        print('PASS')
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
