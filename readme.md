# Ubuntu full disk encryption with hibernate
This is a demo of installing Ubuntu with full disk encryption (FDE) and **working hibernation** in a virtual machine.
While several online resources suggest that FDE with hibernation is possible, I was never able to get it working reliably. This project provides a CI-like set of scripts that fully automates the process of configuring a VM with FDE+hibernation.
We also show a custom LUKS unlock prompt, before the normal passphrase prompt appears, for contact information.

Steps:
- Patch the install iso to add autoinstall flags to grub
- Boot and run the install
- For the remaining boots we run VM in tmux, this allows us to inject the FDE paraphrase and login.
- First boot for cloud-init configuration
  - verifies that `/etc/crypttab` references the custom keyscript for custom LUKS unlock prompt.
  - verifies that the rebuilt initramfs contains the custom keyscript for the unlock prompt.
  - check that grub command line defaults are correct
  - reboot
- Second boot
  - check that we get the custom LUKS unlock prompt
  - inspect active swap with `swapon --show`
  - inspect `resume` on `/proc/cmdline`
  - trigger a hibernate
- Third boot
  - check that we get the custom LUKS unlock prompt
  - check that came back from hibernate using a magic-suspend-token stored in /dev/shm/

# Requirements

```
sudo apt install cloud-image-utils tmux qemu-utils
```

# Run

```
 sudo ./autoinstall_vm.sh && sudo ./boot_and_check_hiber.sh
 ```

if you want to break out While QEMU is attached in the terminal:
- `Ctrl-a` then `x` quits QEMU.
- `Ctrl-b` then `d` detaches from the `tmux` session without stopping the VM.

# TODO
- [x] no wait for network on first boot
- [x] Clean up boot and check script
- [ ] disable the swap file, and check that it is disabled
