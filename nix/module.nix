self: { config, lib, pkgs, ... }: let
  cfg=config.services.lantern;
  file=pkgs.writeText "Lanternfile" cfg.configuration;
in {
  options.services.lantern = {
    enable=lib.mkEnableOption "the experimental Lantern HTTP/TLS webserver";
    package=lib.mkOption {
      type=lib.types.package;
      default=self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description="Lantern executable package.";
    };
    configuration=lib.mkOption {
      type=lib.types.lines;
      example=''
        listen 0.0.0.0:443
        auto_https you@example.com /var/lib/lantern
        site example.com { root /srv/www/example }
      '';
      description="Lanternfile contents. This is public Nix-store data: reference runtime private key paths, never put key material here.";
    };
    credentials=lib.mkOption {
      type=lib.types.attrsOf lib.types.str;
      default={};
      description="Runtime certificate/key files loaded with systemd LoadCredential. Paths only; never use builtins.readFile on secrets.";
    };
  };
  config=lib.mkIf cfg.enable {
    assertions=[ {
      assertion=lib.all (lib.hasPrefix "/") (builtins.attrValues cfg.credentials);
      message="services.lantern.credentials must contain absolute runtime path strings.";
    } ];
    systemd.services.lantern = {
      description="Lantern experimental Haskell webserver";
      wantedBy=[ "multi-user.target" ];
      wants=[ "network-online.target" ];
      after=[ "network-online.target" ];
      serviceConfig = {
        ExecStart="${lib.getExe cfg.package} run ${file}";
        ExecReload="${pkgs.util-linux}/bin/kill -HUP $MAINPID";
        Type="simple";
        DynamicUser=true;
        StateDirectory="lantern";
        StateDirectoryMode="0700";
        WorkingDirectory="/var/lib/lantern";
        LoadCredential=lib.mapAttrsToList (name: path: "${name}:${toString path}") cfg.credentials;
        Restart="on-failure";
        RestartSec="5min";
        TimeoutStopSec="15s";
        UMask="0077";
        NoNewPrivileges=true;
        PrivateTmp=true;
        PrivateDevices=true;
        ProtectSystem="strict";
        ProtectHome=true;
        ProtectKernelTunables=true;
        ProtectKernelModules=true;
        ProtectKernelLogs=true;
        ProtectControlGroups=true;
        RestrictSUIDSGID=true;
        LockPersonality=true;
        SystemCallArchitectures="native";
        RestrictAddressFamilies=[ "AF_INET" "AF_INET6" "AF_UNIX" ];
        CapabilityBoundingSet=[ "CAP_NET_BIND_SERVICE" ];
        AmbientCapabilities=[ "CAP_NET_BIND_SERVICE" ];
        LimitNOFILE=4096;
        TasksMax=512;
        MemoryMax="512M";
      };
      environment.SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
  };
}
