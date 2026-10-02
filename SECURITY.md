# Security

Medaka is experimental (0.1.0 preview). Please report suspected vulnerabilities
privately rather than in a public issue.

**To report a finding, use GitHub's private vulnerability reporting on this
repository (Security tab, then Report a vulnerability).**

## Scope

- **The PDS (`pds/`), which serves `pds.medaka-lang.dev`.** This includes the
  hand-written cryptography (SHA-256, HMAC, PBKDF2, secp256k1 signing), the
  session and token handling, and the HTTP and XRPC request path. The
  [PDS write-up](docs/blog/pds.md) invites review of exactly this code, and notes
  that no cryptographer has reviewed it yet. A finding there is welcome, and the
  caveats in that post and in [pds/README.md](pds/README.md) tell you what is
  already known. The constant-time and crypto claims are listed in
  [docs/ops/PDS-CRYPTO-CLAIMS.md](docs/ops/PDS-CRYPTO-CLAIMS.md).
- **The compiler and runtime.** A miscompilation that silently produces a wrong
  answer, or a memory-safety fault in `runtime/medaka_rt.c`, is in scope.

There is no bounty, and response times are best effort.
