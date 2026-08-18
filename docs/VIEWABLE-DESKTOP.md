# Viewing a solnix desktop in EC2 from your laptop

Two paths, both software-rendered (no GPU), VNC over an SSH tunnel (never world-open).

## Path A — the ready AMI (usable now, OI-pkg X11 desktop)
VERIFIED during the AMI build: /root/solnix-desktop-vnc.sh brings up Xvfb + twm + xterm +
gtk4-demo/gtk3-demo, with x11vnc LISTENING on 127.0.0.1:5900 (never 0.0.0.0).

    # 1. launch the AMI (scoped SG -- NEVER 0.0.0.0/0)
    AWS_PROFILE=fred aws ec2 run-instances --region us-east-2 \
      --image-id ami-000a59cf344644604 --instance-type m5.large \
      --key-name fred-key --security-group-ids sg-074eddb1fd24663e6 \
      --subnet-id subnet-0bf6b544c7ade866a
    # 2. on the instance: start the desktop
    ssh -i ~/.ssh/id_ed25519 root@<instance-ip>
    /root/solnix-desktop-vnc.sh
    # 3. from your LAPTOP: tunnel + connect
    ssh -i ~/.ssh/id_ed25519 -L 5900:localhost:5900 root@<instance-ip>
    # open any VNC viewer -> localhost:5900   (password: solnix)

You see a solnix desktop (X11 + twm + GTK apps), software-rendered (llvmpipe).
HONEST: this desktop's binaries are OI-pkg (X11/GTK), NOT nix-pure -- a usable demo.

## Path B — the nix-pure Wayland desktop (canonical; converging)
The nix-native stack (all /nix/store, RUNPATH-verified): GTK4 4.22.4 + libadwaita 1.9.2 +
wayland + mesa-softpipe/llvmpipe + the smithay `smallvil` SW Wayland compositor (built + RUNS
native, stage 6). Session = smallvil (winit + llvmpipe) + GTK4/libadwaita clients, viewed via
wayvnc/x11vnc. This is the EXACTLY-Nix desktop. Remaining: wrap the COSMIC rlibs as per-crate
drvs + wire smallvil+wayvnc as the boot session (the nix-pure ISO's graphical session).
cosmic-comp itself needs its render path retyped to SW (bounded refactor) OR a real GPU (g4ad).

## Security
VNC binds 127.0.0.1 ONLY + SSH tunnel. No SG rule is ever opened to 0.0.0.0/0 (sg-guard-enforced).
