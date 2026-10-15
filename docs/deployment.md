# Deployment

Build with `nix build`; the result is `result/bin/lantern`. The flake exports
`nixosModules.default` and a configurable `services.lantern` module:

```nix
{
  imports = [ inputs.lantern.nixosModules.default ];
  services.lantern = {
    enable = true;
    configuration = ''
      listen [::]:443
      auto_https you@example.com /var/lib/lantern
      site example.com { root /srv/www/example }
    '';
  };
}
```

The module runs as a DynamicUser with a private StateDirectory, strict filesystem
protection, a 512 MiB memory bound, descriptor/task limits and only the bind-low-port
capability. Put static data in a readable `/srv` tree; ProtectHome hides home paths.
Firewall policy is yours to configure; no ports are automatically opened. The
service restarts on failure after five minutes; persisted ACME backoff independently
suppresses CA requests until its deadline. Logs go to the journal, with no request
access log by default. Check `journalctl -u lantern` for renewal failures.

For manual keys use runtime credentials, not Nix-store contents:

```nix
services.lantern = {
  enable = true;
  credentials = {
    "chain.pem" = "/var/lib/private-pki/chain.pem";
    "key.pem" = "/var/lib/private-pki/key.pem";
  };
  configuration = ''
    listen [::]:443
    tls /run/credentials/lantern.service/chain.pem /run/credentials/lantern.service/key.pem
    site example.com { root /srv/www/example }
  '';
};
```

For credential-file rotation systemd needs a restart to reload LoadCredential
copies; a direct readable runtime path can instead be reloaded with SIGHUP.
`systemctl reload lantern` requests route/config reload. To request automatic
renewal immediately, use `systemctl kill --kill-whom=main --signal=USR1 lantern`.
Use USR1 only in automatic mode.

`/var/lib/lantern` contains account-key.pem, site-key.pem, chain.pem, identity,
lock and, after failures, retry-until. Preserve the directory privately when
moving/restarting. A different CA or hostname set is detected by identity; it
requires a new order. Do not run two processes with the same state directory.
Atomic key/certificate writes fsync both the file and containing directory.

On Arch or other Linux hosts, run the Nix executable under your service manager
with the same principles. No install script has changed this host's production
Caddy. Do not grant a development checkout write access to published site content
or key storage. Use immutable release directories and update config/root references
atomically. Linux 5.6+ openat2 is required.

## Staging test evidence, 2026-10-15

A temporary DNS-only A/AAAA hostname `lantern-test.freifick.net` pointed to the
server. A temporary HTTP-only Caddy block passed its port-80 traffic to Lantern's
loopback challenge listener on 8871. Lantern's own TLS listener ran on loopback
8870. Its own ACME HTTPS client obtained an RSA certificate from Let's Encrypt's
staging directory. Curl verified the DNS name and chain with a test-only published
Yonder Yam staging root; normal system trust was left unchanged.

A cached restart placed no initial order. SIGUSR1 obtained a different certificate
serial and activated it without restarting the process; curl verification passed
again. The temporary DNS records and Caddy block were removed and Caddy validated
and reloaded. No Lantern listener or service remains deployed. Private test account
and site keys remain under `~/.local/share/lantern-staging/` (0700/0600), outside git.
The screenshots and public serial summary are in docs/progress. These tests used
staging only, not publicly trusted production issuance.
