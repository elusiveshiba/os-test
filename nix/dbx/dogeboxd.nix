{
  config,
  lib,
  pkgs,
  dogeboxd,
  devMode,
  ...
}:

{
  environment.systemPackages = [
    pkgs.systemd
    pkgs.nixos-rebuild
    pkgs.parted
    pkgs.util-linux
    pkgs.e2fsprogs
    pkgs.dosfstools
    pkgs.nixos-install-tools
    pkgs.nix
    pkgs.git
    pkgs.libxkbcommon
    pkgs.wirelesstools
    pkgs.wpa_supplicant
  ];

  users.motd = ''
    +===================================================+
    |                                                   |
    |      ____   ___   ____ _____ ____   _____  __     |
    |     |  _ \ / _ \ / ___| ____| __ ) / _ \ \/ /     |
    |     | | | | | | | |  _|  _| |  _ \| | | \  /      |
    |     | |_| | |_| | |_| | |___| |_) | |_| /  \      |
    |     |____/ \___/ \____|_____|____/ \___/_/\_\     |
    |                                                   |
    +===================================================+
  '';

  users.users.dogeboxd = {
    isSystemUser = true;
    group = "dogebox";
    extraGroups = [ ];
  };

  systemd.tmpfiles.rules = [
    "d /opt/dogebox 0700 dogeboxd dogebox -"

    # Create a dev folder, and give both the shibe user and dogebox group write perms.
    "d /opt/dev 0770 shibe dogebox -"
  ];

  systemd.services.dogebox-finish-profile-switch = {
    description = "Finish interrupted Dogebox profile activation";
    enable = !devMode;
    before = [ "dogeboxd.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [
      pkgs.coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      profile_system=$(readlink -f /nix/var/nix/profiles/system)
      running_system=$(readlink -f /run/current-system)

      if [ "$profile_system" = "$running_system" ]; then
        echo "Dogebox recovery: current system already matches profile: $running_system"
        exit 0
      fi

      echo "Dogebox recovery: current system $running_system does not match profile $profile_system; finishing activation"
      /nix/var/nix/profiles/system/bin/switch-to-configuration switch
    '';
  };

  systemd.services.dogebox-restart-after-partial-upgrade = {
    description = "Restart dogeboxd after partial Dogebox upgrade activation";
    enable = !devMode;
    after = [ "dogeboxd.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      marker=/run/dogebox-restart-after-partial-upgrade.scheduled

      if [ -e "$marker" ]; then
        echo "Dogebox recovery: delayed dogeboxd restart already scheduled"
        exit 0
      fi

      current_dbx=$(cat /opt/versioning/dbx 2>/dev/null || true)
      if grep -q 'dbxRelease = "v0.9.0-rc.8"' /etc/nixos/flake.nix 2>/dev/null; then
        flake_is_current=true
      else
        flake_is_current=false
      fi

      echo "Dogebox recovery: restart check current_dbx=$current_dbx flake_is_current=$flake_is_current"

      if [ "$current_dbx" = "v0.9.0-rc.8" ] && [ "$flake_is_current" = true ]; then
        echo "Dogebox recovery: no delayed dogeboxd restart needed"
        exit 0
      fi

      touch "$marker"
      echo "Dogebox recovery: scheduling delayed dogeboxd restart to continue OS flake migration"
      systemd-run \
        --unit=dogebox-delayed-migration-restart \
        --description="Delayed dogeboxd restart for OS flake migration recovery" \
        --on-active=20s \
        --collect \
        /run/current-system/sw/bin/systemctl restart dogeboxd.service
    '';
  };

  systemd.services.dogeboxd = {
    enable = !devMode;
    after = [
      "systemd-networkd-wait-online.service"
      "dogebox-finish-profile-switch.service"
    ];
    wants = [
      "systemd-networkd-wait-online.service"
      "dogebox-finish-profile-switch.service"
      "dogebox-restart-after-partial-upgrade.service"
    ];
    wantedBy = [ "multi-user.target" ];
    environment.DOGEBOX_RELEASE_REPOSITORY = "https://github.com/elusiveshiba/os-test.git";

    serviceConfig = {
      ExecStart = "/run/wrappers/bin/dogeboxd --addr 0.0.0.0 --data /opt/dogebox --nix /opt/dogebox/nix --containerlogdir /opt/dogebox/logs --port 3000 --uiport 8080 --uidir ${dogeboxd}/dpanel";
      Restart = "always";
      User = "dogeboxd";
      Group = "dogebox";
      Environment = "PATH=/run/wrappers/bin:${pkgs.wpa_supplicant}/bin:${pkgs.wirelesstools}/bin:${pkgs.libxkbcommon}/bin:${pkgs.git}/bin:${pkgs.nix}/bin:${pkgs.nixos-install-tools}/bin:${pkgs.dosfstools}/bin:${pkgs.e2fsprogs}/bin:${pkgs.parted}/bin:${pkgs.util-linux}/bin:${pkgs.systemd}/bin:${pkgs.nixos-rebuild}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:$PATH";
    };
  };

  networking.firewall.allowedTCPPorts = [
    3000
    8080
  ];

  security.wrappers._dbxroot = {
    source = "${dogeboxd}/dogeboxd/bin/_dbxroot";
    owner = "root";
    group = "root";
    setuid = true;
  };

  # This wrapper is to ensure dogeboxd can listen on port :80
  # for it's internal router. This is never exposed outside the host.
  security.wrappers.dogeboxd = {
    source = "${dogeboxd}/dogeboxd/bin/dogeboxd";
    owner = "dogeboxd";
    group = "dogebox";
    capabilities = "cap_net_bind_service=+ep";
  };

  # This wrapper grants no special powers, but makes the binary
  # available system-wide, so that it can be used by systemd init
  # for checking if containers should start at boot (when not in recovery mode)
  security.wrappers.dbx = {
    source = "${dogeboxd}/dogeboxd/bin/dbx";
    owner = "dogeboxd";
    group = "dogebox";
  };

  # TEMPORARY. Remove this when we can figure out how to point it to _just_ the wrappers?
  security.sudo.extraRules = [
    {
      users = [ "dogeboxd" ];
      commands = [
        {
          command = "${dogeboxd}/bin/_dbxroot";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/wrappers/bin/_dbxroot";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
