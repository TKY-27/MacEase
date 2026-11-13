# File protection

MacEase uses the [age v1 file format](https://age-encryption.org/v1) with its
standard scrypt passphrase recipient. The separate `macease-age` executable
links the official `filippo.io/age` Go library at v1.3.2. It does not use a
MacEase-specific encrypted format or key derivation scheme.

Build with `scripts/build-age.sh`. The build writes `Vendor/build/macease-age`.
Packaging places that executable at `MacEase.app/Contents/Resources/macease-age`.
The app passes a length-prefixed UTF-8 passphrase through the executable's
standard input. It never places a passphrase in an argument, environment
variable, file, log, or history record. Passphrases exist only for the current
operation; a forgotten passphrase cannot be recovered.
On failure, the bridge writes one fixed `MACEASE_AGE_ERROR:` category to
standard error. It never prints a passphrase or a raw library error. The app
maps authentication, disk-space, permission, integrity, and I/O categories to
its own error messages.

Encryption writes a private staged `.age` file, then decrypts it and compares
the complete SHA-256 digest and byte count with the source before publishing.
Decryption finishes authentication and writes its private staged output before
publishing. The job engine checks the original file stamp and commits a new,
collision-safe name; originals remain in place. Closing the panel clears the
passphrase. The bridge caps accepted scrypt work factor at 2^20 and rejects
oversized passphrase frames. The pinned age library rejects oversized headers.
Authenticated empty plaintext files can also be published; other output checks
retain their existing nonempty requirement.

The Go module and its transitive dependencies are recorded in
`Vendor/AgeBridge/go.mod` and `go.sum`. Their distribution license texts are
in `Vendor/AgeBridge/licenses/`. The age project is BSD-3-Clause; its linked
`filippo.io/hpke`, `golang.org/x/crypto`, and `golang.org/x/sys` dependencies
use permissive licenses. A separately installed `age` CLI can decrypt MacEase
files with its standard passphrase prompt; MacEase can decrypt standard scrypt
age files.
