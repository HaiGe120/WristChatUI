# Cleanup verifier false positive — November 2, 2026

At 11:40:34 (Asia/Shanghai), the required final cleanup check returned a regression while an independent physical-iPhone version query was still running. Simulator work stopped; no subsequent simulator boot was attempted.

The saved report `build/derived/sim-logs/cleanup-regression-20261102-114034.txt` shows:

- No SimulatorTrampoline above 200 MiB.
- No remaining WristAssistant executable.
- The sole matched process was Apple's `devicectl device info apps` query, whose command included the WristAssistant bundle identifier.

The current `pgrep` expression also matches control commands containing a bundle identifier, so parallel version verification can produce this false positive. The detector has not been weakened or bypassed. Finish physical-device queries before running the final simulator cleanup check; refine the process matching with appropriate regression tests in a separate change if needed. The version query completed and cleanup was rerun serially.
