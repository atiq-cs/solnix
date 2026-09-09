docs: CORRECT commit adabea51dc -- it recorded the JULY hashes as the proven artifact

Commit adabea51dc ("the solnix USB image BOOTS UNDER UEFI") is wrong about WHICH FILE it proved, and
since a commit message cannot be rewritten here, the correction lives in the tree.

What adabea51dc claims:
  solnix-x86_64.iso   108722176 B  sha256 5dcb722cd10eabd3...   <- 2026-07-29, PRE-FIX
  "ALSO RECORDED: the .iso and .img are BYTE-IDENTICAL ... there is no GPT"

What is actually true of the deliverable:
  solnix-x86_64-usb.img  104761344 B  sha256 19d838554b392bd15ddc8da80ccb6ee05770b6d88ea444b704f28c43cbe1ae6d
  in artifacts/install-media/usb-image-20260909/ -- and it HAS a real GPT:
  "EFI PART" at LBA 1, partition 2 = 4 MiB EFI System.

My OVMF boot pass was real, but it was a pass for a SIX-WEEK-OLD image of unrecorded provenance, so
it could not stand in for the rung-3 proof of the artifact being shipped. The "no GPT" line was true
of the July file and FALSE of the deliverable: the agent had replaced -isohybrid-gpt-basdat (which
emits no GPT, exactly matching what I probed) with -appended_part_as_gpt.

This is the THIRD time in this campaign I have made a correct measurement on the wrong object -- after
the VM-labelled PCIe "ground truth" and objcopy-on-dixi-vs-a-fresh-AMI. The failure is never the
measurement; it is not checking that the thing measured is the thing in question. In this case the
directory made it easy: the obvious filename was the stale one and the good build sat in a dated
subdirectory. Those six July images are now quarantined in STALE-2026-07-do-not-flash/.

docs/usb-install-media.md was already correct throughout -- it records the September hashes, explains
the -isohybrid-gpt-basdat -> -appended_part_as_gpt fix, and separately notes that the GRAPHICAL ISO
genuinely still has no GPT because it is a pre-fix build. Only my commit message was wrong. The
maintainer-facing instructions were never affected.

Worth keeping from the agent's rebuttal: it answered the GPT-necessity question by EXPERIMENT rather
than argument -- zeroing the primary GPT still boots (firmware falls back to the backup at end of
disk), and zeroing BOTH still boots via the El Torito entry. So GPT is sufficient-but-not-required on
OVMF and the two paths work independently. Evidence: boot-logs/expt-nogpt-uefi.clean.txt and
expt-nogpt-both-uefi.clean.txt.
