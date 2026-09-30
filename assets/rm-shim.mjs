// iSH (iOS) note: Node's recursive rmSync fails with EPERM because the kernel
// returns EPERM (not EISDIR) for unlink() on a directory, so Node never falls
// back to rmdir. Shell `rm -rf` handles both, so route recursive removals there.
import { rmSync as _nodeRmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

export function rmSync(target, opts = {}) {
  try {
    return _nodeRmSync(target, opts)
  } catch (error) {
    if (error && error.code === 'EPERM') {
      try {
        execFileSync('/bin/rm', ['-rf', '--', String(target)])
        return
      } catch { /* fall through to the original error */ }
    }
    throw error
  }
}
