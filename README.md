# Keenetic XHTTP VPN

Installer for Keenetic Extra / Entware `mipselsf-k3.4` using Xray 26.2.6, VLESS + XHTTP + TLS and a TUN interface.

## Install

Run on the router over SSH as root:

```sh
wget -qO- https://raw.githubusercontent.com/RATOR2000/keenetic-xhttp-vpn/main/install.sh | sh
```

The installer asks for the VLESS UUID and does not store the UUID in this public repository.

## Configuration

- Server: `cdn.mytestlanding.shop:443`
- SNI: `cdn.mytestlanding.shop`
- Transport: XHTTP
- Mode: `packet-up`
- Path: `/videotest/download`
- TUN: `kvpn0`
- Web panel: `http://<router-ip>:18080/`

The installer uses manual split-default IPv4 routes because the selected Xray version predates newer automatic routing options.

## Router commands

```sh
/opt/kvpn/kvpn start
/opt/kvpn/kvpn stop
/opt/kvpn/kvpn restart
/opt/kvpn/kvpn status
/opt/kvpn/kvpn log
```

If routing causes a problem, stop the VPN with `/opt/kvpn/kvpn stop`.
