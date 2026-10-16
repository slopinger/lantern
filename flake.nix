{
  description = "Lantern: an experimental Haskell webserver with independent HTTP, TLS and ACME";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    http.url = "git+https://git.freifick.net/slop/lantern-http.git?ref=main";
    http.inputs.nixpkgs.follows = "nixpkgs";
    tls.url = "git+https://git.freifick.net/slop/lantern-tls.git?ref=main";
    tls.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, http, tls }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    each = nixpkgs.lib.genAttrs systems;
  in {
    packages = each (system: let
      pkgs=nixpkgs.legacyPackages.${system};
      raw=(tls.lib.cryptoPackages pkgs).callCabal2nix "lantern" self {
        lantern-http=http.packages.${system}.default;
        lantern-tls=tls.packages.${system}.default;
      };
    in {
      default=(pkgs.haskell.lib.justStaticExecutables raw).overrideAttrs (old: {
        meta=(old.meta or {}) // { mainProgram="lantern"; platforms=systems; };
      });
    });
    checks = each (system: let
      pkgs=nixpkgs.legacyPackages.${system};
      package=self.packages.${system}.default;
      python=pkgs.python3.withPackages (p: [ p.cryptography ]);
    in {
      inherit package;
      integration=pkgs.runCommand "lantern-integration" {
        nativeBuildInputs = [ python pkgs.openssl ];
        LANTERN_BIN="${package}/bin/lantern";
      } ''
        cp -r ${self}/test test
        chmod -R u+w test
        python test/cli_test.py
        python test/http_test.py
        python test/static_test.py
        python test/path_encoding_test.py
        python test/https_proxy_test.py
        python test/acme_test.py
        touch $out
      '';
      module=let
        host=nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ self.nixosModules.default ({ ... }: {
            system.stateVersion="26.05";
            boot.loader.grub.enable=false;
            fileSystems."/"={device="none";fsType="tmpfs";};
            services.lantern={
              enable=true;
              configuration="listen 127.0.0.1:8080\nsite localhost { respond \"hello\" }\n";
            };
          }) ];
        };
      in pkgs.runCommand "lantern-module-evaluation" {} ''
        test ${nixpkgs.lib.escapeShellArg host.config.systemd.services.lantern.serviceConfig.StateDirectory} = lantern
        test -r ${builtins.elemAt (nixpkgs.lib.splitString " " host.config.systemd.services.lantern.serviceConfig.ExecStart) 2}
        ${package}/bin/lantern check ${builtins.elemAt (nixpkgs.lib.splitString " " host.config.systemd.services.lantern.serviceConfig.ExecStart) 2}
        touch $out
      '';
    });
    devShells = each (system: let
      pkgs=nixpkgs.legacyPackages.${system};
    in {
      default=pkgs.mkShell {
        packages = [
          ((tls.lib.cryptoPackages pkgs).ghcWithPackages (_: [ http.packages.${system}.default tls.packages.${system}.default
            pkgs.haskellPackages.async pkgs.haskellPackages.parsec pkgs.haskellPackages.mime-types pkgs.haskellPackages.QuickCheck ]))
          pkgs.cabal-install pkgs.openssl pkgs.caddy pkgs.wrk pkgs.strace
          (pkgs.python3.withPackages (p: [ p.cryptography ]))
        ];
      };
    });
    nixosModules.default=import ./nix/module.nix self;
  };
}
