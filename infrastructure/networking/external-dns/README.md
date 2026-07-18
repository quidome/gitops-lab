# ExternalDNS

This component publishes DNS records for `quido.me` from Gateway API `HTTPRoute` resources.

## Destinations

- `external-dns-pihole-a` -> Pi-hole A
- `external-dns-pihole-b` -> Pi-hole B
- `external-dns-pihole-c` -> Pi-hole C
- `external-dns-technitium` -> Technitium via RFC2136

## Shared config

Defined in `values.yaml`:

- provider: `pihole` by default
- policy: `sync`
- source: `gateway-httproute`
- domain filter: `quido.me`

The Technitium release overrides the provider to `rfc2136` in `helmfile.yaml.gotmpl`.

## Vault secrets

Path:
- `kv/networking/external-dns`

Keys:
- `EXTERNAL_DNS_PIHOLE_PASSWORD`
- `EXTERNAL_DNS_RFC2136_TSIG_SECRET`

## Technitium notes

For the RFC2136 destination to work with ExternalDNS TXT ownership records, the Technitium zone policy for `quido.me` must allow:

- TSIG key: `external-dns`
- domain: `*.quido.me`
- record types: at least `A, TXT`

`policy: sync` also requires zone transfer support, so the RFC2136 config includes:

- `--rfc2136-tsig-axfr`
