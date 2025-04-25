# ubuntu fde with hibernate
This is a demo of installing Ubuntu with full disk encryption (FDE) and **working hibernation** in a virtual machine.
While several online resources suggest that FDE with hibernation is possible, I was never able to get it working reliably. This project provides a CI-like set of scripts that fully automates the process of configuring a VM with FDE+hibernation.

Steps:
- Patch the iso to add autoinstall flags
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

# TODO
- [x] no wait for network on first boot
- [ ] Clean up boot and check script
  - [  ] split out