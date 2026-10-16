{ self, pkgs }:
pkgs.testers.runNixOSTest {
  name = "lantern-service";
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.default ];
    virtualisation.memorySize = 1024;
    environment.systemPackages = [ pkgs.curl pkgs.openssl ];
    services.lantern = {
      enable = true;
      credentials = {
        "chain.pem" = "/var/lib/test-pki/chain.pem";
        "key.pem" = "/var/lib/test-pki/key.pem";
      };
      configuration = ''
        listen 127.0.0.1:443
        tls /run/credentials/lantern.service/chain.pem /run/credentials/lantern.service/key.pem
        site localhost { root /srv/fixture }
      '';
    };
    systemd.services.test-fixture = {
      requiredBy = [ "lantern.service" ];
      before = [ "lantern.service" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      path = [ pkgs.openssl pkgs.coreutils ];
      script = ''
        install -d -m 0700 /var/lib/test-pki
        umask 077
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
          -subj /CN=localhost -addext subjectAltName=DNS:localhost \
          -keyout /var/lib/test-pki/key.pem -out /var/lib/test-pki/chain.pem
        install -d -m 0755 /srv/fixture
        printf 'served by the sandboxed service\n' > /srv/fixture/index.html
        chmod 0644 /srv/fixture/index.html
      '';
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("lantern.service", timeout=90)
    machine.wait_for_open_port(443)
    request = "curl --silent --show-error --fail --tlsv1.3 --resolve localhost:443:127.0.0.1 "
    url = " https://localhost/"
    ca = "/var/lib/test-pki/chain.pem"
    expected = "served by the sandboxed service\n"
    assert machine.succeed(request + "--cacert " + ca + url) == expected
    pid = machine.succeed("systemctl show lantern -p MainPID --value").strip()
    uid = machine.succeed("ps -o uid= -p " + pid).strip()
    assert int(uid) > 0, "service unexpectedly ran as root"
    assert uid == machine.succeed("id -u lantern").strip()
    assert machine.succeed("systemctl show lantern -p NoNewPrivileges --value").strip() == "yes"
    machine.succeed("test $(stat -Lc %a /var/lib/lantern) = 700")
    machine.succeed("test $(stat -c %a /var/lib/test-pki/key.pem) = 600")
    machine.succeed("cp " + ca + " /tmp/old-ca.pem")
    machine.succeed("openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost "
                    "-addext subjectAltName=DNS:localhost -keyout /var/lib/test-pki/key.pem "
                    "-out /var/lib/test-pki/chain.pem")
    machine.succeed("systemctl reload lantern")
    machine.wait_until_succeeds("journalctl -u lantern --no-pager | grep -q 'configuration reloaded'")
    assert machine.succeed("systemctl show lantern -p MainPID --value").strip() == pid
    # LoadCredential snapshots persist until restart, including across SIGHUP.
    assert machine.succeed(request + "--cacert /tmp/old-ca.pem" + url) == expected
    machine.fail(request + "--cacert " + ca + url)
    machine.succeed("systemctl restart lantern")
    machine.wait_for_open_port(443)
    assert machine.succeed(request + "--cacert " + ca + url) == expected
    machine.fail(request + "--cacert /tmp/old-ca.pem" + url)
    machine.succeed("systemctl stop lantern")
    machine.wait_until_succeeds("test $(systemctl show lantern -p ActiveState --value) = inactive")
    assert machine.succeed("systemctl show lantern -p Result --value").strip() == "success"
    machine.fail(request + "--cacert " + ca + url)
    print("NixOS service passed: boot, dedicated user, low-port TLS, runtime credentials, reload, rotation, clean stop")
  '';
}
