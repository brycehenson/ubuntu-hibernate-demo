# Ubuntu full disk encryption with hibernate
This is a demo of installing Ubuntu with full disk encryption (FDE) and **working hibernation** in a virtual machine.
While several online resources suggest that FDE with hibernation is possible, I was never able to get it working reliably. This project provides a CI-like set of scripts that fully automates the process of configuring a VM with FDE+hibernation.

Steps:
- Patch the install iso to add autoinstall flags to grub
- Boot and run the install
- For the remaining boots we run VM in tmux, this allows us to inject the FDE paraphrase and login.
- First boot for cloud-init configuration
  - check that grub command line defaults are correct
  - reboot
- Second boot
  - check that swap file and hibernate is configured correctly
  - trigger a hibernate
- Third boot
  - check that came back from hibernate using a magic-suspend-token stored in /dev/shm/

# Requirements

```
sudo apt install cloud-image-utils tmux qemu-utils
```

# Run

```
 ./autoinstall_vm.sh && ./boot_and_check_hiber.sh
 ```

While QEMU is attached in the terminal:
- `Ctrl-a` then `x` quits QEMU.
- `Ctrl-b` then `d` detaches from the `tmux` session without stopping the VM.

# Validate custom LUKS prompt

The validation flow uses the same VM lifecycle already in this repo:

1. `./autoinstall_vm.sh` installs Ubuntu with encrypted root.
2. On the first real boot, cloud-init installs a custom `cryptsetup` keyscript that prints a message and then delegates to `/lib/cryptsetup/askpass`, then rebuilds initramfs.
3. `./boot_and_check_hiber.sh` verifies that the keyscript was packed into initramfs.
4. On the next encrypted boot, and again on resume-from-hibernate, the script waits for the custom marker text on the serial console before it sends the LUKS passphrase.

Test command:

```
./autoinstall_vm.sh && ./boot_and_check_hiber.sh
```

The run should print `OK: custom LUKS prompt keyscript found in initramfs` and then continue only after it has seen `Hi there friend, thanks for finding my laptop !` on the unlock screen.

# TODO
- [x] no wait for network on first boot
- [x] Clean up boot and check script
