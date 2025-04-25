# ubuntu fde with hibernate

Demo showing ubuntu install with full disk encryption (fde)
and WORKING hibernation.

Steps:
- Patch the iso to add autoinstall flags
- Boot and run the install
- For installed first boot use tmux to monitor the console and then inject the FDE paraphrase.
    - cloud init runcmd runs
- Reboot
  - check that hibernate is configured correctly
  - trigger a hibernate
- Boot
  - check that came back from hibernate

# Requirements

```
sudo apt install cloud-image-utils tmux
```

# Run

```
 ./autoinstall_vm.sh && ./boot_and_check_hiber.sh
 ```

# TODO
- [x] no wait for network on first boot
- [ ] Clean up boot and check script
  - [  ] split out