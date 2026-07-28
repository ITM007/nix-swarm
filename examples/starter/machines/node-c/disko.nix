{ inputs, lib, ... }:

let
  device = "/dev/disk/by-id/REPLACE_WITH_TARGET_DISK";
  diskLayout = import ../../disko/uefi-single-disk-ext4.nix;
in
{
  imports = [ inputs.disko.nixosModules.disko ];

  # This placeholder must be replaced with the stable by-id path for the target
  # disk before running nixos-anywhere. The assertion intentionally fails until
  # the operator makes the destructive disk choice explicit.
  disko.devices.disk.main = diskLayout { inherit device; };

  assertions = [
    {
      assertion = !(lib.hasInfix "REPLACE_WITH_TARGET_DISK" device);
      message = "Set machines/node-c/disko.nix to the target's stable /dev/disk/by-id path before provisioning; the selected disk will be erased.";
    }
  ];
}
