# Two measured facts: encrypted root is silently unbootable, and the "revoked" key is the working one

## 1. ⚠️ An encrypted root pool produces a SILENTLY unbootable disk

illumos ZFS on `ami-0cb14e40f9355bd0c` **does** support native encryption —
`zpool create -O encryption=aes-256-gcm -O keyformat=passphrase` succeeds, and `aes-999-bogus` is correctly
rejected as a negative control.

**The loader cannot decrypt it.** Verified in the source, not inferred:

* `usr/src/boot/libsa/zfs/zfsimpl.c:125` lists `"com.datto:encryption"` in **`features_for_read[]`** — the
  read-compatible allowlist. So the loader **accepts** an encrypted pool and proceeds.
* The same 3,805-line file contains **zero** decryption code. `grep -ciE 'aes|gcm|pbkdf|hkdf|zio_crypt|decrypt'`
  → **0**. The only `crypt`-ish token anywhere is the substring `cryption` inside that allowlist string.
* `loader64.efi`/`gptzfsboot` strings show SHA256/SHA512 checksums and **no** AES/GCM/PBKDF/HKDF.
* ⚠️ **There is no error path either** — grepping the loader's ZFS code for `ENCRYPT`/`encrypted`/`crypt_keydata`
  returns **nothing**. It does not detect-and-refuse; it reads ciphertext as though it were data.
* `zpool set bootfs=<encrypted dataset>` is **accepted** by ZFS (plaintext control also accepted), so nothing
  upstream of the loader objects either.

**Consequence:** every layer says yes and the machine does not boot. That is the worst possible shape — a
detect-and-refuse would at least be diagnosable.

**Therefore:** `solnix-install` offers encryption for **`/home`** (and optionally `/nix`) only, and **refuses to
encrypt the root dataset**, with this mechanism quoted in the refusal message.

Also measured: on a `-d` loader-compatible pool, encryption needs `-o feature@encryption=enabled` explicitly.
Negative control without it: *"Encryption feature not enabled"*.

## 2. ⚠️ The key named `.REVOKED` is the one that works

`~/.ssh/solnix-lava.pem.REVOKED-2026-09-12` authenticates to `ami-0cb14e40f9355bd0c`.
**`solnix-lava2.pem` is rejected** (`Permission denied (publickey)`), confirmed with
`-o ControlMaster=no -o ControlPath=none -o IdentitiesOnly=yes` to defeat the ssh-mux trap that previously made
every key look valid.

**Why, and it was my error:** after a private key was briefly copied to a build node I deleted the AWS keypair
`solnix-lava` and renamed the local file `.REVOKED`. But **the AMI was built while `solnix-lava` was current**,
so that *public* key is baked into the image's `authorized_keys`. Deleting an AWS keypair only stops new
instances from being tagged with it — **it cannot reach inside an AMI's filesystem.**

So there are two different things with one name:

| | |
|---|---|
| **account keypair** (what `run-instances --key-name` uses) | `solnix-lava2` |
| **key the AMI's `authorized_keys` trusts** | `solnix-lava` (the file I labelled `.REVOKED`) |

The file is renamed to **`solnix-lava.pem.AMI-BAKED-still-works`**, because a misleading filename cost an agent
real time. The honest fix is to rebuild the AMI with the new public key; until then, use this file and know why.
